//! Deterministic wind-field. Returns a horizontal wind vector at any
//! `(x, z, t)` given a `WindParams` config. Server source of truth — same
//! answer client and server given matching params + time.
//!
//! Two layers, matching the gameplay roles:
//!
//!   1. Tactical global wind. A single base direction that wobbles ± an
//!      amplitude on a shift period. Coherent across the world, so two
//!      ships in the same combat feel the same wind — the "weather gauge"
//!      tactic survives. Atlas-flavored.
//!
//!   2. Storm-cell terrain. A slice of `WindStorm` cells; each is an
//!      addressable entity (id = index) with its own radius, strength,
//!      drift speed, and vortex mix. Each cell has a hash-derived gust
//!      direction and drift heading from `(seed, index)`; spawn position
//!      is also hash-derived. Their contribution is a coherent gust
//!      pointing in the cell's gust direction, blendable with a tangent
//!      cyclone term via per-cell `vortex_mix`. Sailors route around (or
//!      through) storm cells the way they'd treat a headwind region.
//!
//! `vortex_mix ∈ [0, 1]` blends each cell's contribution between pure
//! gust (0, Atlas-style) and pure cyclone (1, tangent flow with a calm
//! eye). The vortex term is rescaled by √e so peak magnitude is
//! `strength` at either endpoint — turning the knob never weakens storms.
//!
//! The slice is laid out so every cell shares the same `seed` and the
//! same toroidal `storm_world_m`; per-cell fields drive *what* the storm
//! does, hash-derived per-cell properties drive *where it is*. This keeps
//! YAML compact while making each storm individually addressable for the
//! visibility / stealth / audio queries that will follow (see
//! `design_storms_as_cover.md`).
//!
//! Output is `[2]f32 = {wind_x, wind_z}` — horizontal components in world
//! axes. Vertical wind is implicitly zero in this model.

const std = @import("std");

/// Per-cell storm configuration. The slice is owned by whoever built the
/// `WindParams`; presets reference a const-data-segment array, YAML-loaded
/// params own a heap allocation freed by `WindParams.deinit`.
pub const WindStorm = struct {
    radius_m: f32,
    strength_mps: f32,
    speed_mps: f32,
    vortex_mix: f32,
};

pub const WindParams = struct {
    seed: u64,

    // ---- Tactical layer (global) ----

    /// Magnitude of the global wind. Storms add on top.
    base_speed_mps: f32,
    /// Mean direction in radians, measured from +x toward +z.
    base_direction_rad: f32,
    /// Period of the direction oscillation. 0 disables shifts entirely.
    shift_period_s: f32,
    /// Peak deviation from `base_direction_rad`, radians. 0 = no wobble.
    shift_amplitude_rad: f32,

    // ---- Terrain layer (storms) ----

    /// Storm centers wrap toroidally inside a square of this size; spawn
    /// positions are uniformly distributed within the square.
    storm_world_m: f32,
    /// One entry per storm cell. Empty = no storms.
    storms: []WindStorm,

    /// Free the storms slice. Only call on YAML-loaded params; preset
    /// values point at module-const data and must not be passed here.
    pub fn deinit(self: WindParams, gpa: std.mem.Allocator) void {
        gpa.free(self.storms);
    }
};

/// SplitMix64-style hash to f32 in [0, 1). Pure function of (seed, idx, salt);
/// `salt` lets one (seed, idx) yield independent values for x, z, and angles.
fn hash01(seed: u64, idx: u32, salt: u32) f32 {
    var s: u64 = seed;
    s ^= @as(u64, idx) *% 0x9E3779B97F4A7C15;
    s ^= @as(u64, salt) *% 0xC2B2AE3D27D4EB4F;
    s = (s ^ (s >> 30)) *% 0xBF58476D1CE4E5B9;
    s = (s ^ (s >> 27)) *% 0x94D049BB133111EB;
    s = s ^ (s >> 31);
    const u: u32 = @truncate(s);
    return @as(f32, @floatFromInt(u)) / 4294967296.0;
}

/// Wrap `v` into `[-world/2, +world/2)`. Used to put coordinates on a torus
/// of size `world` so positions outside the box re-enter from the opposite
/// edge, and so query→center deltas pick the shortest wrapped path.
fn wrapTorus(v: f32, world: f32) f32 {
    const half = world * 0.5;
    var w = @mod(v + half, world);
    if (w < 0) w += world;
    return w - half;
}

/// √e — rescales the cyclone-vortex term so its peak magnitude (which
/// otherwise lives at the σ ring with value `strength·exp(-1/2)`) matches
/// the gust term's peak magnitude (`strength` at the eye). Without this,
/// dialing `vortex_mix` toward 1 would silently weaken storms by ~40%.
const sqrt_e: f32 = 1.6487213;

/// Position of storm cell `i` at time `t`, on the toroidal world. Returns
/// `{cx, cz}` in world axes, in the canonical `[-world/2, +world/2)` range.
/// Used by the kernel and exposed publicly for fog / visibility / stealth
/// queries that need to know "where is storm i right now?".
pub fn stormCenter(p: WindParams, i: usize, t: f32) [2]f32 {
    if (i >= p.storms.len) return .{ 0, 0 };
    const idx32: u32 = @intCast(i);
    const cell = p.storms[i];
    const sx0 = (hash01(p.seed, idx32, 0xA1) - 0.5) * p.storm_world_m;
    const sz0 = (hash01(p.seed, idx32, 0xB2) - 0.5) * p.storm_world_m;
    const drift_angle = hash01(p.seed, idx32, 0xC3) * std.math.tau;
    const cx = wrapTorus(sx0 + @cos(drift_angle) * cell.speed_mps * t, p.storm_world_m);
    const cz = wrapTorus(sz0 + @sin(drift_angle) * cell.speed_mps * t, p.storm_world_m);
    return .{ cx, cz };
}

/// Horizontal wind at (x, z) at time t. Returns {wind_x, wind_z}.
pub fn windAt(p: WindParams, x: f32, z: f32, t: f32) [2]f32 {
    var dir = p.base_direction_rad;
    if (p.shift_period_s > 0) {
        dir += p.shift_amplitude_rad * @sin(std.math.tau * t / p.shift_period_s);
    }
    var wx: f32 = @cos(dir) * p.base_speed_mps;
    var wz: f32 = @sin(dir) * p.base_speed_mps;

    if (p.storms.len == 0) return .{ wx, wz };

    const world = p.storm_world_m;

    for (p.storms, 0..) |cell, i| {
        if (cell.radius_m <= 0) continue;
        const idx32: u32 = @intCast(i);

        const sigma = cell.radius_m;
        const inv_two_sigma_sq = 1.0 / (2.0 * sigma * sigma);
        const inv_sigma = 1.0 / sigma;
        const mix = std.math.clamp(cell.vortex_mix, 0.0, 1.0);
        const gust_w = 1.0 - mix;
        const vortex_w = mix * sqrt_e;

        const sx0 = (hash01(p.seed, idx32, 0xA1) - 0.5) * world;
        const sz0 = (hash01(p.seed, idx32, 0xB2) - 0.5) * world;
        const drift_angle = hash01(p.seed, idx32, 0xC3) * std.math.tau;
        const gust_angle = hash01(p.seed, idx32, 0xC4) * std.math.tau;

        const cx = wrapTorus(sx0 + @cos(drift_angle) * cell.speed_mps * t, world);
        const cz = wrapTorus(sz0 + @sin(drift_angle) * cell.speed_mps * t, world);

        const dx = wrapTorus(x - cx, world);
        const dz = wrapTorus(z - cz, world);

        const r2 = dx * dx + dz * dz;
        const falloff = @exp(-r2 * inv_two_sigma_sq);

        // Gust: a coherent vector in the cell's hash-derived direction.
        // Vortex: tangent (-dz, dx)/σ; the (r/σ) factor that would make
        // the center smooth cancels out of the unit-tangent normalization,
        // leaving a contribution that is exactly zero at the eye and peaks
        // on the σ ring. The √e rescale keeps mix=1 peak == mix=0 peak.
        const k = cell.strength_mps * falloff;
        wx += k * (gust_w * @cos(gust_angle) + vortex_w * (-dz) * inv_sigma);
        wz += k * (gust_w * @sin(gust_angle) + vortex_w * (dx) * inv_sigma);
    }

    return .{ wx, wz };
}

// ------------------------------------------------------------
// Hand-coded preset fixtures. Mirror `data/wind.yaml`. The storm
// arrays are module-level vars so a const `WindParams` can hold a
// non-const slice into them; nothing actually mutates the arrays.
// ------------------------------------------------------------

var calm_storms = [_]WindStorm{};

var breezy_storms = [_]WindStorm{
    .{ .radius_m = 250.0, .strength_mps = 4.0, .speed_mps = 3.0, .vortex_mix = 0.0 },
    .{ .radius_m = 250.0, .strength_mps = 4.0, .speed_mps = 3.0, .vortex_mix = 0.0 },
};

var storm_storms = [_]WindStorm{
    .{ .radius_m = 300.0, .strength_mps = 10.0, .speed_mps = 6.0, .vortex_mix = 0.2 },
    .{ .radius_m = 300.0, .strength_mps = 10.0, .speed_mps = 6.0, .vortex_mix = 0.2 },
    .{ .radius_m = 300.0, .strength_mps = 10.0, .speed_mps = 6.0, .vortex_mix = 0.2 },
    .{ .radius_m = 300.0, .strength_mps = 10.0, .speed_mps = 6.0, .vortex_mix = 0.2 },
};

pub const calm: WindParams = .{
    .seed = 2001,
    .base_speed_mps = 1.5,
    .base_direction_rad = 0.0,
    .shift_period_s = 600.0,
    .shift_amplitude_rad = 0.2,
    .storm_world_m = 4096.0,
    .storms = &calm_storms,
};

pub const breezy: WindParams = .{
    .seed = 2002,
    .base_speed_mps = 6.0,
    .base_direction_rad = 0.3,
    .shift_period_s = 300.0,
    .shift_amplitude_rad = 0.4,
    .storm_world_m = 4096.0,
    .storms = &breezy_storms,
};

pub const storm: WindParams = .{
    .seed = 2003,
    .base_speed_mps = 12.0,
    .base_direction_rad = 0.7,
    .shift_period_s = 180.0,
    .shift_amplitude_rad = 0.6,
    .storm_world_m = 4096.0,
    .storms = &storm_storms,
};

// ------------------------------------------------------------
// Tests — M4.1 milestone gate.
// ------------------------------------------------------------

const testing = std.testing;

fn determinismSweep(p: WindParams, prng_seed: u64) !void {
    var rng = std.Random.DefaultPrng.init(prng_seed);
    const r = rng.random();
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const x = (r.float(f32) - 0.5) * 8000.0;
        const z = (r.float(f32) - 0.5) * 8000.0;
        const t = r.float(f32) * 600.0;
        const w1 = windAt(p, x, z, t);
        const w2 = windAt(p, x, z, t);
        try testing.expectEqual(w1[0], w2[0]);
        try testing.expectEqual(w1[1], w2[1]);
    }
}

test "determinism: calm" {
    try determinismSweep(calm, 0x1111);
}

test "determinism: breezy" {
    try determinismSweep(breezy, 0x2222);
}

test "determinism: storm" {
    try determinismSweep(storm, 0x3333);
}

test "no storms: magnitude equals base_speed_mps everywhere" {
    var p = calm;
    p.shift_period_s = 0;
    p.base_direction_rad = 0;
    p.base_speed_mps = 7.5;

    var rng = std.Random.DefaultPrng.init(0xCAFE);
    const r = rng.random();
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const x = (r.float(f32) - 0.5) * 4000.0;
        const z = (r.float(f32) - 0.5) * 4000.0;
        const t = r.float(f32) * 600.0;
        const w = windAt(p, x, z, t);
        const mag = @sqrt(w[0] * w[0] + w[1] * w[1]);
        try testing.expectApproxEqAbs(@as(f32, 7.5), mag, 1e-4);
    }
}

test "wind shift: direction wobbles ±amplitude over shift period" {
    var p = calm;
    p.shift_period_s = 100;
    p.shift_amplitude_rad = 0.3;
    p.base_direction_rad = 0;
    p.base_speed_mps = 1.0;

    const w0 = windAt(p, 0, 0, 0);
    try testing.expectApproxEqAbs(@as(f32, 1), w0[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), w0[1], 1e-5);

    const wq = windAt(p, 0, 0, 25);
    try testing.expectApproxEqAbs(@cos(@as(f32, 0.3)), wq[0], 1e-5);
    try testing.expectApproxEqAbs(@sin(@as(f32, 0.3)), wq[1], 1e-5);

    const wh = windAt(p, 0, 0, 50);
    try testing.expectApproxEqAbs(@as(f32, 1), wh[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), wh[1], 1e-5);

    const wt = windAt(p, 0, 0, 75);
    try testing.expectApproxEqAbs(@cos(@as(f32, -0.3)), wt[0], 1e-5);
    try testing.expectApproxEqAbs(@sin(@as(f32, -0.3)), wt[1], 1e-5);
}

test "shift_period_s=0 freezes direction" {
    var p = calm;
    p.shift_period_s = 0;
    p.base_direction_rad = 0;
    p.base_speed_mps = 1.0;
    const a = windAt(p, 0, 0, 0);
    const b = windAt(p, 0, 0, 1e6);
    try testing.expectEqual(a[0], b[0]);
    try testing.expectEqual(a[1], b[1]);
}

test "different seeds produce different storm fields" {
    var a = storm;
    a.seed = 0xAAAA;
    var b = storm;
    b.seed = 0xBBBB;
    const wa = windAt(a, 100, 200, 5);
    const wb = windAt(b, 100, 200, 5);
    try testing.expect(wa[0] != wb[0] or wa[1] != wb[1]);
}

// Single-storm helpers — mutate a stack-local array so we can swap
// vortex_mix without needing the YAML loader.
fn singleStormParams(seed: u64, world: f32, cell: WindStorm, storms_buf: *[1]WindStorm) WindParams {
    storms_buf.* = .{cell};
    return .{
        .seed = seed,
        .base_speed_mps = 0,
        .base_direction_rad = 0,
        .shift_period_s = 0,
        .shift_amplitude_rad = 0,
        .storm_world_m = world,
        .storms = storms_buf,
    };
}

test "gust storm peak ≈ strength at the eye (vortex_mix=0)" {
    var buf: [1]WindStorm = undefined;
    const p = singleStormParams(0xDEADBEEF, 4000, .{
        .radius_m = 200,
        .strength_mps = 10,
        .speed_mps = 0,
        .vortex_mix = 0.0,
    }, &buf);

    var max_mag: f32 = 0;
    var x: f32 = -2000;
    while (x <= 2000) : (x += 25) {
        var z: f32 = -2000;
        while (z <= 2000) : (z += 25) {
            const w = windAt(p, x, z, 0);
            const m = @sqrt(w[0] * w[0] + w[1] * w[1]);
            if (m > max_mag) max_mag = m;
        }
    }
    try testing.expect(max_mag > 9.5);
    try testing.expect(max_mag <= 10.0);
}

test "vortex storm peak ≈ strength on σ ring (vortex_mix=1)" {
    var buf: [1]WindStorm = undefined;
    const p = singleStormParams(0xDEADBEEF, 4000, .{
        .radius_m = 200,
        .strength_mps = 10,
        .speed_mps = 0,
        .vortex_mix = 1.0,
    }, &buf);

    var max_mag: f32 = 0;
    var x: f32 = -2000;
    while (x <= 2000) : (x += 25) {
        var z: f32 = -2000;
        while (z <= 2000) : (z += 25) {
            const w = windAt(p, x, z, 0);
            const m = @sqrt(w[0] * w[0] + w[1] * w[1]);
            if (m > max_mag) max_mag = m;
        }
    }
    try testing.expect(max_mag > 9.5);
    try testing.expect(max_mag <= 10.0);
}

test "storm influence ~zero at the torus antipode" {
    var buf: [1]WindStorm = undefined;
    const p = singleStormParams(0xDEADBEEF, 8000, .{
        .radius_m = 200,
        .strength_mps = 10,
        .speed_mps = 0,
        .vortex_mix = 0.5,
    }, &buf);

    var min_mag: f32 = std.math.floatMax(f32);
    var x: f32 = -4000;
    while (x <= 4000) : (x += 200) {
        var z: f32 = -4000;
        while (z <= 4000) : (z += 200) {
            const w = windAt(p, x, z, 0);
            const m = @sqrt(w[0] * w[0] + w[1] * w[1]);
            if (m < min_mag) min_mag = m;
        }
    }
    try testing.expect(min_mag < 1e-3);
}

test "no NaN over wide grid and time range" {
    const p = storm;
    var x: f32 = -4000;
    while (x <= 4000) : (x += 200) {
        var z: f32 = -4000;
        while (z <= 4000) : (z += 200) {
            var t: f32 = 0;
            while (t <= 1200) : (t += 60) {
                const w = windAt(p, x, z, t);
                try testing.expect(!std.math.isNan(w[0]));
                try testing.expect(!std.math.isNan(w[1]));
            }
        }
    }
}

test "bounded magnitude: ≤ base_speed + Σ strength" {
    const p = storm;
    var sum_strength: f32 = 0;
    for (p.storms) |c| sum_strength += c.strength_mps;
    const cap = p.base_speed_mps + sum_strength;

    var rng = std.Random.DefaultPrng.init(0xFEED);
    const r = rng.random();
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const x = (r.float(f32) - 0.5) * 8000.0;
        const z = (r.float(f32) - 0.5) * 8000.0;
        const t = r.float(f32) * 600.0;
        const w = windAt(p, x, z, t);
        const m = @sqrt(w[0] * w[0] + w[1] * w[1]);
        try testing.expect(m <= cap * 1.01);
    }
}

test "stormCenter matches kernel-internal storm position over time" {
    var buf: [1]WindStorm = undefined;
    const p = singleStormParams(0x12345, 4000, .{
        .radius_m = 200,
        .strength_mps = 10,
        .speed_mps = 5,
        .vortex_mix = 0.0,
    }, &buf);

    // Probe a fine grid; the gust-mix=0 peak sits exactly at the storm
    // center, so the location of max magnitude must be within √2·step/2
    // of stormCenter().
    const step: f32 = 25;
    const times: [3]f32 = .{ 0, 30, 90 };
    for (times) |t| {
        const center = stormCenter(p, 0, t);
        var max_mag2: f32 = -1;
        var px: f32 = 0;
        var pz: f32 = 0;
        var x: f32 = -2000;
        while (x <= 2000) : (x += step) {
            var z: f32 = -2000;
            while (z <= 2000) : (z += step) {
                const w = windAt(p, x, z, t);
                const m2 = w[0] * w[0] + w[1] * w[1];
                if (m2 > max_mag2) {
                    max_mag2 = m2;
                    px = x;
                    pz = z;
                }
            }
        }
        const ddx = px - center[0];
        const ddz = pz - center[1];
        const dist = @sqrt(ddx * ddx + ddz * ddz);
        try testing.expect(dist < step * std.math.sqrt2);
    }
}

test "stormCenter translates over time at speed_mps" {
    var buf: [1]WindStorm = undefined;
    const p = singleStormParams(0x12345, 4000, .{
        .radius_m = 200,
        .strength_mps = 10,
        .speed_mps = 5,
        .vortex_mix = 0.0,
    }, &buf);

    const c0 = stormCenter(p, 0, 0);
    const c1 = stormCenter(p, 0, 60);
    var dx = c1[0] - c0[0];
    var dz = c1[1] - c0[1];
    // Account for one possible wrap.
    if (dx > p.storm_world_m * 0.5) dx -= p.storm_world_m;
    if (dx < -p.storm_world_m * 0.5) dx += p.storm_world_m;
    if (dz > p.storm_world_m * 0.5) dz -= p.storm_world_m;
    if (dz < -p.storm_world_m * 0.5) dz += p.storm_world_m;
    const moved = @sqrt(dx * dx + dz * dz);
    // 5 m/s × 60 s = 300 m. Allow a small fp tolerance.
    try testing.expectApproxEqAbs(@as(f32, 300), moved, 0.5);
}
