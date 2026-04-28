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
//!   2. Storm-cell terrain. N translating Gaussian blobs that perturb the
//!      base wind locally. Each cell has a hash-derived gust direction;
//!      its contribution is a coherent gust pointing that way. Sailors
//!      route around (or through) storm cells the way they'd treat a
//!      headwind region.
//!
//! `storm_vortex_mix ∈ [0, 1]` blends each cell's contribution between
//! pure gust (0, Atlas-style) and pure cyclone (1, tangent flow with
//! a calm eye). The vortex term is rescaled by √e so peak magnitude is
//! `strength` at either endpoint — turning the knob never weakens storms.
//! Mid values give "gust with a hint of swirl"; the storm preset uses 0.5.
//!
//! Storm centers translate at constant velocity on a torus of size
//! `storm_world_m`; spawn positions and drift directions come from a
//! splitmix64-style hash of `(seed, cell_index)` so `windAt` is a pure
//! function of its inputs — no per-storm state.
//!
//! Output is `[2]f32 = {wind_x, wind_z}` — horizontal components in world
//! axes. Vertical wind is implicitly zero in this model.

const std = @import("std");

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

    /// Number of active storm cells. All evaluated every `windAt` call;
    /// keep small (≤ 8) — cost is O(N) per query.
    storm_count: u32,
    /// Gaussian sigma in meters. Influence is essentially zero past ~3σ.
    /// Pick `storm_world_m` ≥ ~6σ so toroidal wraps don't bleed into view.
    storm_radius_m: f32,
    /// Peak magnitude a storm adds, in m/s. Holds at either mix endpoint.
    storm_strength_mps: f32,
    /// Speed (m/s) at which storm centers translate. Direction per cell
    /// is hash-derived from (seed, cell_index).
    storm_speed_mps: f32,
    /// Storm centers wrap toroidally inside a square of this size; spawn
    /// positions are uniformly distributed within the square.
    storm_world_m: f32,
    /// Blend between coherent gust (0.0) and cyclone vortex (1.0). 0 is
    /// the Atlas-flavored default; 0.3-0.6 keeps a tactical gust direction
    /// with visible swirl; 1.0 is the meteorological cyclone.
    storm_vortex_mix: f32,
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

/// Horizontal wind at (x, z) at time t. Returns {wind_x, wind_z}.
pub fn windAt(p: WindParams, x: f32, z: f32, t: f32) [2]f32 {
    var dir = p.base_direction_rad;
    if (p.shift_period_s > 0) {
        dir += p.shift_amplitude_rad * @sin(std.math.tau * t / p.shift_period_s);
    }
    var wx: f32 = @cos(dir) * p.base_speed_mps;
    var wz: f32 = @sin(dir) * p.base_speed_mps;

    if (p.storm_count == 0 or p.storm_radius_m <= 0) return .{ wx, wz };

    const sigma = p.storm_radius_m;
    const inv_two_sigma_sq = 1.0 / (2.0 * sigma * sigma);
    const inv_sigma = 1.0 / sigma;
    const world = p.storm_world_m;
    const mix = std.math.clamp(p.storm_vortex_mix, 0.0, 1.0);
    const gust_w = 1.0 - mix;
    const vortex_w = mix * sqrt_e;

    var i: u32 = 0;
    while (i < p.storm_count) : (i += 1) {
        const sx0 = (hash01(p.seed, i, 0xA1) - 0.5) * world;
        const sz0 = (hash01(p.seed, i, 0xB2) - 0.5) * world;
        const drift_angle = hash01(p.seed, i, 0xC3) * std.math.tau;
        const gust_angle = hash01(p.seed, i, 0xC4) * std.math.tau;

        const cx = wrapTorus(sx0 + @cos(drift_angle) * p.storm_speed_mps * t, world);
        const cz = wrapTorus(sz0 + @sin(drift_angle) * p.storm_speed_mps * t, world);

        const dx = wrapTorus(x - cx, world);
        const dz = wrapTorus(z - cz, world);

        const r2 = dx * dx + dz * dz;
        const falloff = @exp(-r2 * inv_two_sigma_sq);

        // Gust: a coherent vector in the cell's hash-derived direction.
        // Vortex: tangent (-dz, dx)/σ; the (r/σ) factor that would make
        // the center smooth cancels out of the unit-tangent normalization,
        // leaving a contribution that is exactly zero at the eye and peaks
        // on the σ ring. The √e rescale keeps mix=1 peak == mix=0 peak.
        const k = p.storm_strength_mps * falloff;
        wx += k * (gust_w * @cos(gust_angle) + vortex_w * (-dz) * inv_sigma);
        wz += k * (gust_w * @sin(gust_angle) + vortex_w * (dx) * inv_sigma);
    }

    return .{ wx, wz };
}

// ------------------------------------------------------------
// Hand-coded preset fixtures. Will mirror `data/wind.yaml` once M4.2
// adds the loader; for M4.1 they're the only source.
// ------------------------------------------------------------

pub const calm: WindParams = .{
    .seed = 2001,
    .base_speed_mps = 1.5,
    .base_direction_rad = 0.0,
    .shift_period_s = 600.0,
    .shift_amplitude_rad = 0.2,
    .storm_count = 0,
    .storm_radius_m = 200.0,
    .storm_strength_mps = 0.0,
    .storm_speed_mps = 0.0,
    .storm_world_m = 4096.0,
    .storm_vortex_mix = 0.0,
};

pub const breezy: WindParams = .{
    .seed = 2002,
    .base_speed_mps = 6.0,
    .base_direction_rad = 0.3,
    .shift_period_s = 300.0,
    .shift_amplitude_rad = 0.4,
    .storm_count = 2,
    .storm_radius_m = 250.0,
    .storm_strength_mps = 4.0,
    .storm_speed_mps = 3.0,
    .storm_world_m = 4096.0,
    .storm_vortex_mix = 0.0,
};

pub const storm: WindParams = .{
    .seed = 2003,
    .base_speed_mps = 12.0,
    .base_direction_rad = 0.7,
    .shift_period_s = 180.0,
    .shift_amplitude_rad = 0.6,
    .storm_count = 4,
    .storm_radius_m = 300.0,
    .storm_strength_mps = 10.0,
    .storm_speed_mps = 6.0,
    .storm_world_m = 4096.0,
    .storm_vortex_mix = 0.2,
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
    p.storm_count = 0;
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
    p.storm_count = 0;
    p.shift_period_s = 100;
    p.shift_amplitude_rad = 0.3;
    p.base_direction_rad = 0;
    p.base_speed_mps = 1.0;

    // t=0: dir = base = 0 → +x
    const w0 = windAt(p, 0, 0, 0);
    try testing.expectApproxEqAbs(@as(f32, 1), w0[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), w0[1], 1e-5);

    // t=period/4: dir = +amplitude
    const wq = windAt(p, 0, 0, 25);
    try testing.expectApproxEqAbs(@cos(@as(f32, 0.3)), wq[0], 1e-5);
    try testing.expectApproxEqAbs(@sin(@as(f32, 0.3)), wq[1], 1e-5);

    // t=period/2: back to base
    const wh = windAt(p, 0, 0, 50);
    try testing.expectApproxEqAbs(@as(f32, 1), wh[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), wh[1], 1e-5);

    // t=3·period/4: dir = -amplitude
    const wt = windAt(p, 0, 0, 75);
    try testing.expectApproxEqAbs(@cos(@as(f32, -0.3)), wt[0], 1e-5);
    try testing.expectApproxEqAbs(@sin(@as(f32, -0.3)), wt[1], 1e-5);
}

test "shift_period_s=0 freezes direction" {
    var p = calm;
    p.storm_count = 0;
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

test "gust storm peak ≈ strength at the eye (vortex_mix=0)" {
    const p: WindParams = .{
        .seed = 0xDEADBEEF,
        .base_speed_mps = 0,
        .base_direction_rad = 0,
        .shift_period_s = 0,
        .shift_amplitude_rad = 0,
        .storm_count = 1,
        .storm_radius_m = 200,
        .storm_strength_mps = 10,
        .storm_speed_mps = 0,
        .storm_world_m = 4000,
        .storm_vortex_mix = 0.0,
    };
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
    // Gust peaks at r=0 with magnitude == strength. 25 m grid → at worst
    // √2·12.5 ≈ 18 m from true center → falloff ≥ exp(-324/80000) ≈ 0.996.
    try testing.expect(max_mag > 9.5);
    try testing.expect(max_mag <= 10.0);
}

test "vortex storm peak ≈ strength on σ ring (vortex_mix=1)" {
    const p: WindParams = .{
        .seed = 0xDEADBEEF,
        .base_speed_mps = 0,
        .base_direction_rad = 0,
        .shift_period_s = 0,
        .shift_amplitude_rad = 0,
        .storm_count = 1,
        .storm_radius_m = 200,
        .storm_strength_mps = 10,
        .storm_speed_mps = 0,
        .storm_world_m = 4000,
        .storm_vortex_mix = 1.0,
    };
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
    // With the √e rescale, vortex peak magnitude is also strength at r=σ.
    try testing.expect(max_mag > 9.5);
    try testing.expect(max_mag <= 10.0);
}

test "storm influence ~zero at the torus antipode" {
    // On a toroidal world there's no "infinity" — instead the farthest
    // a query point can be from a storm center is the antipode, at
    // distance √2 · world/2. With world=8000, σ=200 that's ≈ 5.66 km
    // ≈ 28 σ; the *minimum* magnitude sampled across the torus must be
    // near zero for any vortex_mix.
    const p: WindParams = .{
        .seed = 0xDEADBEEF,
        .base_speed_mps = 0,
        .base_direction_rad = 0,
        .shift_period_s = 0,
        .shift_amplitude_rad = 0,
        .storm_count = 1,
        .storm_radius_m = 200,
        .storm_strength_mps = 10,
        .storm_speed_mps = 0,
        .storm_world_m = 8000,
        .storm_vortex_mix = 0.5,
    };
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

test "bounded magnitude: ≤ base_speed + N·strength" {
    const p = storm;
    const cap = p.base_speed_mps +
        @as(f32, @floatFromInt(p.storm_count)) * p.storm_strength_mps;

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

test "storm centers translate over time" {
    // Single gust storm; the peak sits exactly at the storm center, so
    // findPeak tracks the cell. With drift_speed=5 the storm moves 300 m
    // in 60 s, which must register as > 100 m of peak motion (loose,
    // covers grid quantization and possible toroidal wrap).
    const p: WindParams = .{
        .seed = 0x12345,
        .base_speed_mps = 0,
        .base_direction_rad = 0,
        .shift_period_s = 0,
        .shift_amplitude_rad = 0,
        .storm_count = 1,
        .storm_radius_m = 200,
        .storm_strength_mps = 10,
        .storm_speed_mps = 5,
        .storm_world_m = 4000,
        .storm_vortex_mix = 0.0,
    };

    const peak0 = findPeak(p, 0);
    const peak1 = findPeak(p, 60);
    const dx = peak1.x - peak0.x;
    const dz = peak1.z - peak0.z;
    const moved = @sqrt(dx * dx + dz * dz);
    try testing.expect(moved > 100.0);
}

const Peak = struct { x: f32, z: f32 };

fn findPeak(p: WindParams, t: f32) Peak {
    var max_mag: f32 = -1;
    var px: f32 = 0;
    var pz: f32 = 0;
    const half = p.storm_world_m * 0.5;
    var x: f32 = -half;
    while (x <= half) : (x += 50) {
        var z: f32 = -half;
        while (z <= half) : (z += 50) {
            const w = windAt(p, x, z, t);
            const m = w[0] * w[0] + w[1] * w[1];
            if (m > max_mag) {
                max_mag = m;
                px = x;
                pz = z;
            }
        }
    }
    return .{ .x = px, .z = pz };
}
