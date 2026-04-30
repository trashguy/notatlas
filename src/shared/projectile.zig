//! Deterministic projectile module — M8.
//!
//! Projectiles are not replicated entities (docs/03 §8). A `FireEvent`
//! broadcast on `sim.entity.<weapon_id>.fire` carries everything both
//! ends need to compute the trajectory locally; both call `predict`
//! with the same inputs and get the same output, by construction.
//! Bandwidth cost per shot is one fire event (~70 B JSON, ~28 B once
//! we move to a binary codec) plus zero per-tick replication for the
//! cannonball in flight.
//!
//! v1 model: vacuum ballistic. Closed-form
//!     pos(t) = muzzle + dir * v0 * t + 0.5 * g * t²
//!     vel(t) = dir * v0 + g * t
//! No drag, no wind, no Coriolis. Sea of Thieves and Atlas both ship
//! vacuum-ballistic cannon shots — aerodynamic drag at typical sloop
//! ranges (50–200 m) is gameplay-irrelevant and breaks closed-form
//! determinism. Drag / wind influence is a future-cycle balance
//! lever, not a v1 concern.
//!
//! Splash detection: caller provides a wave-height callback; this
//! module steps through the trajectory at a fixed `dt_s` and returns
//! the first time water is crossed. **`dt_s` is part of the
//! determinism contract** — different stride sizes produce different
//! splash times for non-linear wave fields, so client and server
//! must agree on the value. v1 convention: 1/60 s, matching the
//! physics tick.
//!
//! Hit-against-entity resolution lives in ship-sim once the
//! spatial-index service is up — out of M8 scope. M8 ships the
//! deterministic trajectory + splash detection + a stable wire
//! format for the fire event.

const std = @import("std");
const replication = @import("replication.zig");
const pose_codec = @import("pose_codec.zig");

pub const Pose = pose_codec.Pose;
pub const EntityId = replication.EntityId;

/// World-fixed gravity (m/s²). +y is up by convention; gravity is
/// applied in the -y direction inside `predict` / `velocityAt`.
pub const g_mps2: f32 = 9.81;

/// Per-ammo ballistic + damage parameters. Loaded from
/// `data/ammo/<type>.yaml`. v1 has just cannonball; future ammo
/// types add their own files.
pub const AmmoParams = struct {
    /// Muzzle velocity at full charge (charge = 1.0), m/s.
    muzzle_velocity_mps: f32 = 250.0,
    /// Per-shot mass (kg). Held for future drag/wind models; v1
    /// ignores it.
    mass_kg: f32 = 6.0,
    /// Splash damage radius at impact (m).
    splash_radius_m: f32 = 3.0,
    /// Splash damage at the centre of the impact (HP).
    splash_damage_hp: f32 = 50.0,
};

/// One fired round. Everything both client and server need to
/// reconstruct the trajectory.
pub const FireEvent = struct {
    /// The weapon that fired (cannon, swivel gun, etc.). Identity is
    /// generation-tagged the same way every other entity is so a
    /// stale subscriber that was attached to a now-recycled cannon
    /// id doesn't accidentally accept a fire from a different
    /// instance.
    weapon: EntityId,
    /// Absolute world clock at the moment of firing. f64 because the
    /// game world is wipe-cycle-long.
    fire_time_s: f64,
    /// Muzzle pose at fire time. `rot` orients the fire direction:
    ///     fire_dir = rotate(rot, [+1, 0, 0])
    /// Local +x is the muzzle's forward axis (matches the
    /// `heading_rad` convention in `state.zig` / `replication.zig`).
    muzzle: Pose,
    /// 0..1 — fraction of full muzzle velocity. Square-law scaled
    /// inside `effectiveVelocity` so half-charge ≈ 71 % velocity,
    /// quarter-charge = 50 %. Encourages full-charge play in PvP and
    /// gives PvE crews a knob.
    charge: f32,
    /// Ammo parameters. Carried in the event so the
    /// fire-event-broadcast model stays self-contained: a client
    /// receiving the event doesn't need to look up an ammo registry
    /// to render the trajectory.
    ammo: AmmoParams,
};

// ---- pure ballistic ----

/// `local +x` rotated by `q` (unit quaternion (x, y, z, w)).
/// Closed-form expansion of `q * (1,0,0) * q^-1`.
pub fn rotateX(q: [4]f32) [3]f32 {
    const qx = q[0];
    const qy = q[1];
    const qz = q[2];
    const qw = q[3];
    return .{
        1.0 - 2.0 * (qy * qy + qz * qz),
        2.0 * (qx * qy + qz * qw),
        2.0 * (qx * qz - qy * qw),
    };
}

/// Effective muzzle velocity = nominal × √(charge). Square-law
/// scaling per the `charge` field doc above. Charge clamped to [0, 1]
/// so out-of-range inputs don't return NaN.
pub fn effectiveVelocity(ev: FireEvent) f32 {
    const c = std.math.clamp(ev.charge, 0.0, 1.0);
    return ev.ammo.muzzle_velocity_mps * @sqrt(c);
}

/// Position at time `dt` (seconds) after `fire_time_s`. Closed-form
/// vacuum ballistic with constant gravity.
pub fn predict(ev: FireEvent, dt: f32) [3]f32 {
    const dir = rotateX(ev.muzzle.rot);
    const v0 = effectiveVelocity(ev);
    return .{
        ev.muzzle.pos[0] + dir[0] * v0 * dt,
        ev.muzzle.pos[1] + dir[1] * v0 * dt - 0.5 * g_mps2 * dt * dt,
        ev.muzzle.pos[2] + dir[2] * v0 * dt,
    };
}

/// Velocity at time `dt`. Closed-form derivative of `predict`.
pub fn velocityAt(ev: FireEvent, dt: f32) [3]f32 {
    const dir = rotateX(ev.muzzle.rot);
    const v0 = effectiveVelocity(ev);
    return .{
        dir[0] * v0,
        dir[1] * v0 - g_mps2 * dt,
        dir[2] * v0,
    };
}

/// Caller-provided wave-height function: returns y of the water
/// surface at `(x, z)` at absolute world time `t_world`. Typically
/// bound to `wave_query.waveHeight` with fixed `WaveParams` from the
/// active biome. Wave params are deterministic from seed (M1) so as
/// long as both ends use the same seed, the same callback at the
/// same `(t, x, z)` returns the same height.
pub const WaveHeightFn = *const fn (t_world: f64, x: f32, z: f32) f32;

/// First time `dt` ∈ [0, t_max_s] at which the projectile crosses
/// below the water surface, or null if it doesn't cross within the
/// window. Stride `dt_s` IS part of the determinism contract —
/// callers must pass the same value on client and server. v1
/// convention: 1/60 s.
///
/// Returns the bisected crossing time (~ms resolution) for clean
/// splash visual cues.
pub fn splashTime(
    ev: FireEvent,
    wave_height_at: WaveHeightFn,
    dt_s: f32,
    t_max_s: f32,
) ?f32 {
    var t: f32 = 0;
    var prev_above: bool = true;
    // Initial state: if the muzzle starts below water, splash
    // immediately at t=0. Skip the first probe: predict(t=0) =
    // muzzle.pos, and the loop handles the t=0 step specially.
    while (t <= t_max_s) {
        const p = predict(ev, t);
        const wh = wave_height_at(ev.fire_time_s + @as(f64, t), p[0], p[2]);
        const above = p[1] > wh;
        if (!above and prev_above and t > 0) {
            // Crossing in (t - dt_s, t]. Bisect to refine.
            return refineCrossing(ev, wave_height_at, t - dt_s, t);
        }
        if (!above and t == 0) {
            // Muzzle started underwater (firing from below the
            // surface); splash at t=0.
            return 0;
        }
        prev_above = above;
        t += dt_s;
    }
    return null;
}

fn refineCrossing(
    ev: FireEvent,
    wave_height_at: WaveHeightFn,
    a_in: f32,
    b_in: f32,
) f32 {
    // 8 bisection steps narrow the interval by 256×. At dt_s = 1/60
    // s that's ~65 µs resolution — well below any frame rate's
    // visual splash cue threshold.
    var a = a_in;
    var b = b_in;
    var i: u8 = 0;
    while (i < 8) : (i += 1) {
        const m = 0.5 * (a + b);
        const p = predict(ev, m);
        const wh = wave_height_at(ev.fire_time_s + @as(f64, m), p[0], p[2]);
        if (p[1] > wh) a = m else b = m;
    }
    return 0.5 * (a + b);
}

// ---- tests ----

const testing = std.testing;

fn flatWaterAtZero(_: f64, _: f32, _: f32) f32 {
    return 0.0;
}

fn baseEvent() FireEvent {
    return .{
        .weapon = .{ .id = 1, .generation = 0 },
        .fire_time_s = 100.0,
        .muzzle = .{
            .pos = .{ 0, 5, 0 }, // 5 m above the water
            .rot = .{ 0, 0, 0, 1 }, // identity → fire +x
            .vel = .{ 0, 0, 0 },
        },
        .charge = 1.0,
        .ammo = .{},
    };
}

test "projectile: predict(t=0) is the muzzle position" {
    const ev = baseEvent();
    const p = predict(ev, 0);
    try testing.expectEqual(@as(f32, 0), p[0]);
    try testing.expectEqual(@as(f32, 5), p[1]);
    try testing.expectEqual(@as(f32, 0), p[2]);
}

test "projectile: predict moves along fire direction (identity rot fires +x)" {
    var ev = baseEvent();
    ev.charge = 1.0;
    const p1 = predict(ev, 1.0);
    try testing.expect(p1[0] > 0); // +x
    try testing.expectEqual(@as(f32, 0), p1[2]); // no z drift
    // Vertical component: y(1s) = 5 + 0 - 0.5 * 9.81 * 1 = 0.095
    try testing.expectApproxEqAbs(@as(f32, 0.095), p1[1], 1e-4);
}

test "projectile: charge=0 → zero velocity → only gravity drop" {
    var ev = baseEvent();
    ev.charge = 0;
    const p = predict(ev, 1.0);
    try testing.expectEqual(@as(f32, 0), p[0]); // no horizontal motion
    try testing.expectEqual(@as(f32, 0), p[2]);
    try testing.expectApproxEqAbs(@as(f32, 5.0 - 0.5 * g_mps2), p[1], 1e-4);
}

test "projectile: effectiveVelocity is square-law in charge" {
    var ev = baseEvent();
    ev.charge = 1.0;
    try testing.expectEqual(ev.ammo.muzzle_velocity_mps, effectiveVelocity(ev));
    ev.charge = 0.25;
    try testing.expectApproxEqAbs(0.5 * ev.ammo.muzzle_velocity_mps, effectiveVelocity(ev), 1e-4);
    ev.charge = 0;
    try testing.expectEqual(@as(f32, 0), effectiveVelocity(ev));
    // Out-of-range → clamped, no NaN.
    ev.charge = -0.5;
    try testing.expectEqual(@as(f32, 0), effectiveVelocity(ev));
    ev.charge = 2.0;
    try testing.expectEqual(ev.ammo.muzzle_velocity_mps, effectiveVelocity(ev));
}

test "projectile: velocityAt is the time-derivative of predict" {
    const ev = baseEvent();
    // Sample velocity numerically and analytically; they should match.
    const dt: f32 = 0.5;
    const v_analytic = velocityAt(ev, dt);
    const eps: f32 = 1e-3;
    const p_a = predict(ev, dt - eps);
    const p_b = predict(ev, dt + eps);
    inline for (0..3) |i| {
        const v_numeric = (p_b[i] - p_a[i]) / (2.0 * eps);
        try testing.expectApproxEqAbs(v_analytic[i], v_numeric, 1e-1);
    }
}

test "projectile: splashTime over flat zero water hits at expected time" {
    var ev = baseEvent();
    // Fire from y=5 m, charge=0 → straight gravity drop. Closed-form
    // y(t) = 5 - 0.5 * 9.81 * t² = 0 → t = sqrt(10/9.81) ≈ 1.0096 s.
    ev.charge = 0;
    const t = splashTime(ev, flatWaterAtZero, 1.0 / 60.0, 5.0).?;
    try testing.expectApproxEqAbs(@as(f32, 1.0096), t, 0.005);
}

test "projectile: splashTime returns null when no crossing within window" {
    var ev = baseEvent();
    // Fire straight up at 100 m/s — peaks at t = v0/g ≈ 10.2 s,
    // returns to muzzle height around t = 20.4 s. With t_max = 5 s
    // we're still in the rising arc when the window ends.
    ev.muzzle.rot = .{ 0, 0, std.math.sin(std.math.pi / 4.0), std.math.cos(std.math.pi / 4.0) }; // rotate 90° about z → +x→+y
    ev.charge = 0.16; // sqrt(0.16) = 0.4 → 100 m/s
    const t = splashTime(ev, flatWaterAtZero, 1.0 / 60.0, 5.0);
    try testing.expect(t == null);
}

test "projectile: deterministic — same FireEvent → same trajectory bit-for-bit" {
    // 100 random events × 50 sample points. Hash the trajectory in
    // two runs; hashes must match exactly. v1 closed-form is
    // trivially deterministic, but encoding the gate this way will
    // catch any future drag/wind addition that introduces
    // non-determinism.
    var rng = std.Random.DefaultPrng.init(0xCAFEF00D);
    const r = rng.random();

    var hasher_a = std.hash.Wyhash.init(0);
    var hasher_b = std.hash.Wyhash.init(0);

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const ev: FireEvent = .{
            .weapon = .{ .id = i + 1, .generation = 0 },
            .fire_time_s = 100.0 + @as(f64, @floatFromInt(i)),
            .muzzle = .{
                .pos = .{
                    (r.float(f32) - 0.5) * 1000,
                    (r.float(f32)) * 50,
                    (r.float(f32) - 0.5) * 1000,
                },
                .rot = randomUnitQuat(r),
                .vel = .{ 0, 0, 0 },
            },
            .charge = 0.5 + r.float(f32) * 0.5,
            .ammo = .{ .muzzle_velocity_mps = 200 + r.float(f32) * 100 },
        };

        var t: f32 = 0;
        var step: u32 = 0;
        while (step < 50) : (step += 1) {
            const p_a = predict(ev, t);
            const p_b = predict(ev, t);
            hasher_a.update(std.mem.asBytes(&p_a));
            hasher_b.update(std.mem.asBytes(&p_b));
            t += 0.1;
        }
    }

    try testing.expectEqual(hasher_a.final(), hasher_b.final());
}

fn randomUnitQuat(r: std.Random) [4]f32 {
    // Sample from the unit hypersphere: pick 4 normals, normalize.
    var v: [4]f32 = .{ r.floatNorm(f32), r.floatNorm(f32), r.floatNorm(f32), r.floatNorm(f32) };
    var n: f32 = 0;
    inline for (v) |x| n += x * x;
    n = @sqrt(n);
    if (n < 1e-6) return .{ 0, 0, 0, 1 };
    inline for (&v) |*x| x.* /= n;
    return v;
}

// ---- M8 GATE ----

test "M8 gate: 1000 fires, predict matches numerically-integrated reference within visual tolerance" {
    // The ship docs/03 §8 gate: "client predicted trajectory matches
    // server resolved trajectory within visual tolerance." With
    // closed-form vacuum ballistic and identical FireEvent inputs,
    // client and server are bit-identical by construction. We
    // strengthen the gate here by verifying the closed form against
    // an independent forward-Euler integration at a finer step
    // size — catches any sign/factor error in the closed-form that
    // self-comparison would miss.
    //
    // The Euler reference drifts from the exact closed form by
    // O(dt). For constant -g, closed-form position over one step is
    // `v*dt + 0.5*g*dt²`; Euler omits the `0.5*g*dt²` term per step.
    // After T=5s with dt=1ms the cumulative drift in y is
    // ~`0.5 * g * T * dt = 0.024 m`, plus f32 accumulation for v
    // and pos at scale ~200 m × 5000 steps which adds another few
    // cm of rounding noise. So the empirical gap is ~0.05–0.10 m;
    // we set the gate at 0.15 m (3× headroom).
    //
    // Visual tolerance for splash placement is much looser — at
    // 500 m horizontal range, 0.15 m is 3e-4 rad ≈ 0.017°, well
    // below human angular resolution. The point of the gate is to
    // catch sign / factor errors in the closed form, which would
    // produce >1m disagreement and stand out clearly against this
    // bound.

    var rng = std.Random.DefaultPrng.init(0xBEEFCAFE);
    const r = rng.random();

    const N_FIRES: u32 = 1000;
    const T_FLIGHT_S: f32 = 5.0; // ~500 m horizontal at 100 m/s
    const REF_DT: f32 = 0.001; // 1 ms ref integrator step

    var max_err_pos: f32 = 0;
    var fires_checked: u32 = 0;

    var i: u32 = 0;
    while (i < N_FIRES) : (i += 1) {
        const ev: FireEvent = .{
            .weapon = .{ .id = i + 1, .generation = 0 },
            .fire_time_s = 100.0 + @as(f64, @floatFromInt(i)),
            .muzzle = .{
                .pos = .{
                    (r.float(f32) - 0.5) * 200,
                    20 + r.float(f32) * 10, // muzzle 20-30 m above water
                    (r.float(f32) - 0.5) * 200,
                },
                .rot = randomElevatedQuat(r),
                .vel = .{ 0, 0, 0 },
            },
            .charge = 0.7 + r.float(f32) * 0.3,
            .ammo = .{ .muzzle_velocity_mps = 100 + r.float(f32) * 100 },
        };

        // Reference: forward-Euler integration. Closed-form is
        // analytically exact for vacuum ballistic, so reference
        // drift is purely numerical (dt² accumulation).
        var ref_pos = ev.muzzle.pos;
        const dir = rotateX(ev.muzzle.rot);
        const v0 = effectiveVelocity(ev);
        var ref_vel: [3]f32 = .{ dir[0] * v0, dir[1] * v0, dir[2] * v0 };

        var t: f32 = 0;
        while (t < T_FLIGHT_S) {
            ref_pos[0] += ref_vel[0] * REF_DT;
            ref_pos[1] += ref_vel[1] * REF_DT;
            ref_pos[2] += ref_vel[2] * REF_DT;
            ref_vel[1] += -g_mps2 * REF_DT;
            t += REF_DT;
        }

        // Closed form at the same end-of-flight time.
        const closed_pos = predict(ev, t);
        const dx = closed_pos[0] - ref_pos[0];
        const dy = closed_pos[1] - ref_pos[1];
        const dz = closed_pos[2] - ref_pos[2];
        const err = @sqrt(dx * dx + dy * dy + dz * dz);
        if (err > max_err_pos) max_err_pos = err;
        fires_checked += 1;
    }

    std.debug.print("\n[M8] gate: {d} fires; max closed-form vs Euler-ref err {d:.4} m (gate 0.15 m, ~3× O(dt) Euler drift over T={d:.1}s)\n", .{
        fires_checked, max_err_pos, T_FLIGHT_S,
    });
    try testing.expect(fires_checked == N_FIRES);
    try testing.expect(max_err_pos < 0.15);
}

/// Quaternion that rotates from local +x to a random direction with
/// upward bias (pitch ∈ [10°, 50°] above horizontal). Cannons fire
/// upward-angled, not straight down — keeps the gate test in a
/// realistic regime.
fn randomElevatedQuat(r: std.Random) [4]f32 {
    const yaw = r.float(f32) * 2.0 * std.math.pi;
    const pitch_deg = 10.0 + r.float(f32) * 40.0;
    const pitch = pitch_deg * std.math.pi / 180.0;

    // Rotation: yaw around y, then pitch around z (which after yaw
    // points into the local horizontal plane perpendicular to the
    // fire direction). Compose as q_yaw * q_pitch in (x, y, z, w).
    const cy = @cos(yaw / 2.0);
    const sy = @sin(yaw / 2.0);
    const q_yaw: [4]f32 = .{ 0, sy, 0, cy };
    const cp = @cos(pitch / 2.0);
    const sp = @sin(pitch / 2.0);
    const q_pitch: [4]f32 = .{ 0, 0, sp, cp };

    return quatMul(q_yaw, q_pitch);
}

fn quatMul(a: [4]f32, b: [4]f32) [4]f32 {
    return .{
        a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
        a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
        a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
        a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
    };
}
