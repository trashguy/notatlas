//! Deterministic ocean wave height function. Server source of truth — the
//! GPU water shader (`assets/shaders/water.frag`) evaluates the exact same
//! algorithm at every fragment so client visuals stay aligned with
//! server-side buoyancy queries.
//!
//! Algorithm: octave-summed "sharpened sine" waves with non-linear position
//! drag between octaves. Adapted from afl_ext's "Ocean" shadertoy
//! (https://www.shadertoy.com/view/MdXyzX, MIT). The shadertoy uses an
//! anonymous heightfield with hard-coded constants; we expose the constants
//! as `WaveParams` so calm/choppy/storm presets (and per-cell variation in
//! the real game) can drive the same kernel.
//!
//! Differences from the original:
//!   - Constants live in `WaveParams` instead of #define
//!   - Iteration count is data-driven, not compile-time
//!   - Heights are returned in *meters around y=0* (signed) rather than
//!     normalized depth-relative units; the world has no "water depth"
//!     concept — meshes float on the actual signed height
//!   - A `seed` rotates the iter direction-generator so calm/choppy/storm
//!     don't all have identical chop patterns

const std = @import("std");
const math_mod = @import("math.zig");

pub const Vec3 = math_mod.Vec3;

/// Tunables for the wave kernel. Stored alongside YAML; UBO-shipped to the
/// fragment shader. Field order is the source-file order ymlz expects.
pub const WaveParams = extern struct {
    /// Permutes the iter-direction sequence so different presets produce
    /// visibly different surfaces with the same kernel constants.
    seed: u64,
    /// Number of octaves summed. afl_ext used 12 for raymarch, 36 for
    /// normals — we keep one count for simplicity; raymarch GPU code uses
    /// `iterations_raymarch` from the wave UBO instead.
    iterations: u32,
    _pad0: u32 = 0, // align next f32 onto an 8B boundary so extern matches std140

    /// How much each octave's derivative pulls subsequent octaves'
    /// sample positions. afl_ext default 0.38; lower = smoother, higher =
    /// chopier.
    drag_multiplier: f32,
    /// Vertical scale (meters). With our centering the surface ranges
    /// roughly [-0.73·amp, +1.0·amp]; peaks read more prominent than
    /// troughs, which matches afl_ext's spike profile.
    amplitude_m: f32,
    /// World meters per "afl_ext position unit". Effectively the
    /// dominant wavelength; storm uses smaller scales for tighter chop.
    wave_scale_m: f32,
    /// Per-octave frequency multiplier (afl_ext default 1.18).
    frequency_mult: f32,
    /// Time multiplier on the first octave (afl_ext default 2.0).
    base_time_mult: f32,
    /// Per-octave time-multiplier multiplier (afl_ext default 1.07).
    time_mult: f32,
    /// Per-octave weight decay (afl_ext used `mix(weight, 0, 0.2)` = 0.8).
    weight_decay: f32,
};

/// Maps `seed` to an initial `iter` value in [0, 2π). Tiny effect on
/// later octaves (1232.4 rad/iter dominates) but enough to differentiate
/// preset surfaces visibly. SplitMix64 → u32 → fraction × tau.
fn seedToInitialIter(seed: u64) f32 {
    var s: u64 = seed;
    s = (s ^ (s >> 30)) *% 0xBF58476D1CE4E5B9;
    s = (s ^ (s >> 27)) *% 0x94D049BB133111EB;
    s = s ^ (s >> 31);
    const u: u32 = @truncate(s);
    const fraction: f32 = @as(f32, @floatFromInt(u)) / 4294967296.0;
    return fraction * std.math.tau;
}

/// Single sharpened-sine wave. Returns (value, -derivative). The derivative
/// is the *negative* of dH/dx so it can be added to position directly to
/// drag the next octave's sample point.
fn wavedx(pos: [2]f32, dir: [2]f32, frequency: f32, timeshift: f32) [2]f32 {
    const x = (dir[0] * pos[0] + dir[1] * pos[1]) * frequency + timeshift;
    const wave = @exp(@sin(x) - 1.0);
    const dx = wave * @cos(x);
    return .{ wave, -dx };
}

/// Raw octave-summed wave value in roughly [0.135, 1.0]. Internal — callers
/// want `waveHeight` (centered, in meters).
fn getWaves(p: WaveParams, x: f32, z: f32, t: f32, iterations: u32) f32 {
    if (iterations == 0) return 0.5; // mid-range; centered-shift produces y=0

    var pos: [2]f32 = .{ x, z };
    var iter: f32 = seedToInitialIter(p.seed);
    var freq: f32 = 1.0;
    var time_mult: f32 = p.base_time_mult;
    var weight: f32 = 1.0;
    var sum_values: f32 = 0;
    var sum_weights: f32 = 0;
    const phase_shift = std.math.hypot(pos[0], pos[1]) * 0.1;

    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        const dir: [2]f32 = .{ @sin(iter), @cos(iter) };
        const res = wavedx(pos, dir, freq, t * time_mult + phase_shift);
        // Position drag — non-linear coupling between octaves; the entire
        // reason this kernel looks ocean-like rather than synthetic.
        pos[0] += dir[0] * res[1] * weight * p.drag_multiplier;
        pos[1] += dir[1] * res[1] * weight * p.drag_multiplier;
        sum_values += res[0] * weight;
        sum_weights += weight;
        weight *= p.weight_decay;
        freq *= p.frequency_mult;
        time_mult *= p.time_mult;
        iter += 1232.399963;
    }
    return sum_values / sum_weights;
}

/// World-space surface height at (x, z) at time t, in meters around y=0.
/// Output range ≈ [-0.73·amplitude_m, +1.0·amplitude_m] — biased high so
/// peaks spike and troughs flatten, matching the visual look of the source.
pub fn waveHeight(p: WaveParams, x: f32, z: f32, t: f32) f32 {
    const x_norm = x / p.wave_scale_m;
    const z_norm = z / p.wave_scale_m;
    const h_norm = getWaves(p, x_norm, z_norm, t, p.iterations);
    return (h_norm * 2.0 - 1.0) * p.amplitude_m;
}

/// Surface normal via central finite difference of `waveHeight`. `eps_m`
/// is the world-space sample offset; smaller = more accurate, more noise
/// at high octave counts. ~0.05–0.2 m is typical.
pub fn waveNormal(p: WaveParams, x: f32, z: f32, t: f32, eps_m: f32) Vec3 {
    const h_c = waveHeight(p, x, z, t);
    const h_l = waveHeight(p, x - eps_m, z, t);
    const h_f = waveHeight(p, x, z + eps_m, t);

    // Tangents from center toward the two sample points.
    // a→l = (-eps, h_l - h_c, 0); a→f = (0, h_f - h_c, +eps)
    // Normal = normalize(cross(a→l - 0, a→f - 0))? No — we want
    // cross(center→x, center→z) flipped so y is positive (up).
    // Use afl_ext's formulation: cross(a-l, a-f) with a=center.
    const ax = x - (x - eps_m); // = eps_m
    const ay = h_c - h_l;
    const bz = (z + eps_m) - z; // = eps_m
    const by = h_c - h_f;

    // cross((ax, ay, 0), (0, by, -bz)) — same as afl_ext's cross expression.
    const nx = ay * (-bz) - 0 * by;
    const ny = 0 * 0 - ax * (-bz);
    const nz = ax * by - ay * 0;
    const len = @sqrt(nx * nx + ny * ny + nz * nz);
    return .{ .x = nx / len, .y = ny / len, .z = nz / len };
}

// ------------------------------------------------------------
// Hand-coded preset fixtures — match `data/waves/*.yaml` exactly.
// Used by tests; also a sanity backstop for sandboxes that can't read YAML.
// ------------------------------------------------------------

pub const calm: WaveParams = .{
    .seed = 1001,
    .iterations = 24,
    .drag_multiplier = 0.20,
    .amplitude_m = 0.5,
    .wave_scale_m = 30.0,
    .frequency_mult = 1.18,
    .base_time_mult = 1.5,
    .time_mult = 1.07,
    .weight_decay = 0.8,
};

pub const choppy: WaveParams = .{
    .seed = 1002,
    .iterations = 32,
    .drag_multiplier = 0.30,
    .amplitude_m = 1.5,
    .wave_scale_m = 22.0,
    .frequency_mult = 1.18,
    .base_time_mult = 1.8,
    .time_mult = 1.07,
    .weight_decay = 0.8,
};

pub const storm: WaveParams = .{
    .seed = 1003,
    .iterations = 20,
    .drag_multiplier = 0.50,
    .amplitude_m = 8.0,
    .wave_scale_m = 14.0,
    .frequency_mult = 1.18,
    .base_time_mult = 2.0,
    .time_mult = 1.07,
    .weight_decay = 0.8,
};

// ------------------------------------------------------------
// Tests
// ------------------------------------------------------------

const testing = std.testing;

fn assertVec3Equal(a: Vec3, b: Vec3) !void {
    try testing.expectEqual(a.x, b.x);
    try testing.expectEqual(a.y, b.y);
    try testing.expectEqual(a.z, b.z);
}

fn determinismSweep(params: WaveParams, prng_seed: u64) !void {
    var rng = std.Random.DefaultPrng.init(prng_seed);
    const r = rng.random();
    var i: usize = 0;
    while (i < 1_000) : (i += 1) {
        // Smaller sample count than M1's 10k because each evaluation is
        // ~36× more expensive than the old per-component Gerstner sum.
        const x = (r.float(f32) - 0.5) * 2000.0;
        const z = (r.float(f32) - 0.5) * 2000.0;
        const t = r.float(f32) * 600.0;
        const h1 = waveHeight(params, x, z, t);
        const h2 = waveHeight(params, x, z, t);
        try testing.expectEqual(h1, h2);
        const n1 = waveNormal(params, x, z, t, 0.1);
        const n2 = waveNormal(params, x, z, t, 0.1);
        try assertVec3Equal(n1, n2);
    }
}

test "determinism: calm" {
    try determinismSweep(calm, 0x1111);
}

test "determinism: choppy" {
    try determinismSweep(choppy, 0x2222);
}

test "determinism: storm" {
    try determinismSweep(storm, 0x3333);
}

test "iterations=0 returns flat ocean" {
    var p = calm;
    p.iterations = 0;
    try testing.expectEqual(@as(f32, 0), waveHeight(p, 12.5, -3.0, 4.2));
}

test "different seeds produce different waves at same (x,z,t)" {
    var a = calm;
    a.seed = 0xAAAA;
    var b = calm;
    b.seed = 0xBBBB;
    const ha = waveHeight(a, 17.3, 9.1, 2.5);
    const hb = waveHeight(b, 17.3, 9.1, 2.5);
    try testing.expect(ha != hb);
}

test "amplitude scaling: storm range > calm range over many samples" {
    var rng = std.Random.DefaultPrng.init(0xABCD);
    const r = rng.random();
    var calm_max: f32 = 0;
    var storm_max: f32 = 0;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const x = (r.float(f32) - 0.5) * 1000.0;
        const z = (r.float(f32) - 0.5) * 1000.0;
        const t = r.float(f32) * 60.0;
        calm_max = @max(calm_max, @abs(waveHeight(calm, x, z, t)));
        storm_max = @max(storm_max, @abs(waveHeight(storm, x, z, t)));
    }
    // storm.amplitude_m / calm.amplitude_m = 4.0 / 0.5 = 8x; expect at
    // least 3x in observed peaks (some extreme samples needed to hit
    // the actual range maxima).
    try testing.expect(storm_max > calm_max * 3.0);
}

test "normal is unit length" {
    var rng = std.Random.DefaultPrng.init(0x9999);
    const r = rng.random();
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const x = (r.float(f32) - 0.5) * 500.0;
        const z = (r.float(f32) - 0.5) * 500.0;
        const t = r.float(f32) * 60.0;
        const n = waveNormal(choppy, x, z, t, 0.1);
        const len = @sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
        try testing.expectApproxEqAbs(@as(f32, 1.0), len, 1e-4);
    }
}

test "normal points up on average" {
    var rng = std.Random.DefaultPrng.init(0x7777);
    const r = rng.random();
    var sum_ny: f32 = 0;
    const n: usize = 500;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const x = (r.float(f32) - 0.5) * 500.0;
        const z = (r.float(f32) - 0.5) * 500.0;
        const t = r.float(f32) * 60.0;
        sum_ny += waveNormal(choppy, x, z, t, 0.1).y;
    }
    try testing.expect(sum_ny / @as(f32, @floatFromInt(n)) > 0.7);
}
