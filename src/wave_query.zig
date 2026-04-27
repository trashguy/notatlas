const std = @import("std");
const math_mod = @import("math.zig");

pub const Vec3 = math_mod.Vec3;

pub const GerstnerComponent = struct {
    amplitude: f32,
    wavelength: f32,
    direction: [2]f32,
    speed: f32,
    steepness: f32,
};

pub const WaveParams = struct {
    seed: u64,
    components: []const GerstnerComponent,
};

pub fn componentPhase(seed: u64, component_idx: usize) f32 {
    var s: u64 = seed +% (@as(u64, component_idx) *% 0x9E3779B97F4A7C15);
    s = (s ^ (s >> 30)) *% 0xBF58476D1CE4E5B9;
    s = (s ^ (s >> 27)) *% 0x94D049BB133111EB;
    s = s ^ (s >> 31);
    const u: u32 = @truncate(s);
    const fraction: f32 = @as(f32, @floatFromInt(u)) / 4294967296.0;
    return fraction * std.math.tau;
}

pub fn waveHeight(params: WaveParams, x: f32, z: f32, t: f32) f32 {
    var y: f32 = 0;
    for (params.components, 0..) |c, i| {
        const phi = componentPhase(params.seed, i);
        const k = std.math.tau / c.wavelength;
        const omega = c.speed * k;
        const theta = k * (c.direction[0] * x + c.direction[1] * z) - omega * t + phi;
        y += c.amplitude * @sin(theta);
    }
    return y;
}

pub fn waveDisplacement(params: WaveParams, x: f32, z: f32, t: f32) Vec3 {
    var dx: f32 = 0;
    var dy: f32 = 0;
    var dz: f32 = 0;
    for (params.components, 0..) |c, i| {
        const phi = componentPhase(params.seed, i);
        const k = std.math.tau / c.wavelength;
        const omega = c.speed * k;
        const theta = k * (c.direction[0] * x + c.direction[1] * z) - omega * t + phi;
        const cos_t = @cos(theta);
        const sin_t = @sin(theta);
        const qa = c.steepness * c.amplitude;
        dx += c.direction[0] * qa * cos_t;
        dz += c.direction[1] * qa * cos_t;
        dy += c.amplitude * sin_t;
    }
    return .{ .x = dx, .y = dy, .z = dz };
}

pub fn waveNormal(params: WaveParams, x: f32, z: f32, t: f32) Vec3 {
    // Jacobian of displaced surface position P(x,z) = (x+dx, dy, z+dz).
    // tx = ∂P/∂x, tz = ∂P/∂z; surface normal N = normalize(T_z × T_x).
    var tx_x: f32 = 1;
    var tx_y: f32 = 0;
    var tx_z: f32 = 0;
    var tz_x: f32 = 0;
    var tz_y: f32 = 0;
    var tz_z: f32 = 1;
    for (params.components, 0..) |c, i| {
        const phi = componentPhase(params.seed, i);
        const k = std.math.tau / c.wavelength;
        const omega = c.speed * k;
        const theta = k * (c.direction[0] * x + c.direction[1] * z) - omega * t + phi;
        const cos_t = @cos(theta);
        const sin_t = @sin(theta);
        const wa = k * c.amplitude;
        const dx = c.direction[0];
        const dz = c.direction[1];
        const q = c.steepness;

        tx_x -= q * wa * dx * dx * sin_t;
        tx_y += wa * dx * cos_t;
        tx_z -= q * wa * dx * dz * sin_t;

        tz_x -= q * wa * dx * dz * sin_t;
        tz_y += wa * dz * cos_t;
        tz_z -= q * wa * dz * dz * sin_t;
    }
    const nx = tz_y * tx_z - tz_z * tx_y;
    const ny = tz_z * tx_x - tz_x * tx_z;
    const nz = tz_x * tx_y - tz_y * tx_x;
    const len = @sqrt(nx * nx + ny * ny + nz * nz);
    return .{ .x = nx / len, .y = ny / len, .z = nz / len };
}

// ------------------------------------------------------------
// Tests
// ------------------------------------------------------------

const testing = std.testing;

pub const calm_components = [_]GerstnerComponent{
    .{ .amplitude = 0.30, .wavelength = 60.0, .direction = .{ 1.0, 0.0 }, .speed = 1.5, .steepness = 0.05 },
    .{ .amplitude = 0.15, .wavelength = 35.0, .direction = .{ 0.7071, 0.7071 }, .speed = 1.2, .steepness = 0.05 },
};
pub const calm: WaveParams = .{ .seed = 1001, .components = &calm_components };

pub const choppy_components = [_]GerstnerComponent{
    .{ .amplitude = 0.80, .wavelength = 40.0, .direction = .{ 1.0, 0.0 }, .speed = 3.0, .steepness = 0.25 },
    .{ .amplitude = 0.55, .wavelength = 22.0, .direction = .{ 0.5, 0.866 }, .speed = 2.5, .steepness = 0.30 },
    .{ .amplitude = 0.40, .wavelength = 14.0, .direction = .{ -0.6, 0.8 }, .speed = 2.0, .steepness = 0.30 },
    .{ .amplitude = 0.25, .wavelength = 8.5, .direction = .{ 0.866, -0.5 }, .speed = 1.6, .steepness = 0.25 },
};
pub const choppy: WaveParams = .{ .seed = 1002, .components = &choppy_components };

pub const storm_components = [_]GerstnerComponent{
    .{ .amplitude = 2.5, .wavelength = 55.0, .direction = .{ 1.0, 0.0 }, .speed = 5.5, .steepness = 0.45 },
    .{ .amplitude = 1.8, .wavelength = 32.0, .direction = .{ 0.866, 0.5 }, .speed = 4.5, .steepness = 0.50 },
    .{ .amplitude = 1.4, .wavelength = 20.0, .direction = .{ 0.5, 0.866 }, .speed = 3.5, .steepness = 0.55 },
    .{ .amplitude = 1.0, .wavelength = 12.0, .direction = .{ -0.6, 0.8 }, .speed = 2.8, .steepness = 0.55 },
    .{ .amplitude = 0.6, .wavelength = 7.0, .direction = .{ 0.866, -0.5 }, .speed = 2.2, .steepness = 0.40 },
};
pub const storm: WaveParams = .{ .seed = 1003, .components = &storm_components };

fn assertVec3Equal(a: Vec3, b: Vec3) !void {
    try testing.expectEqual(a.x, b.x);
    try testing.expectEqual(a.y, b.y);
    try testing.expectEqual(a.z, b.z);
}

fn determinismSweep(params: WaveParams, prng_seed: u64) !void {
    var rng = std.Random.DefaultPrng.init(prng_seed);
    const r = rng.random();
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const x = (r.float(f32) - 0.5) * 2000.0;
        const z = (r.float(f32) - 0.5) * 2000.0;
        const t = r.float(f32) * 600.0;
        const h1 = waveHeight(params, x, z, t);
        const h2 = waveHeight(params, x, z, t);
        try testing.expectEqual(h1, h2);
        const d1 = waveDisplacement(params, x, z, t);
        const d2 = waveDisplacement(params, x, z, t);
        try assertVec3Equal(d1, d2);
        const n1 = waveNormal(params, x, z, t);
        const n2 = waveNormal(params, x, z, t);
        try assertVec3Equal(n1, n2);
    }
}

test "determinism: 10k samples, calm" {
    try determinismSweep(calm, 0x1111);
}

test "determinism: 10k samples, choppy" {
    try determinismSweep(choppy, 0x2222);
}

test "determinism: 10k samples, storm" {
    try determinismSweep(storm, 0x3333);
}

test "empty components: flat ocean" {
    const flat: WaveParams = .{ .seed = 1, .components = &.{} };
    try testing.expectEqual(@as(f32, 0), waveHeight(flat, 12.5, -3.0, 4.2));
    try assertVec3Equal(Vec3.zero, waveDisplacement(flat, 12.5, -3.0, 4.2));
    try assertVec3Equal(Vec3.up, waveNormal(flat, 12.5, -3.0, 4.2));
}

test "different seeds produce different waves at same (x,z,t)" {
    const a: WaveParams = .{ .seed = 0xAAAA, .components = &calm_components };
    const b: WaveParams = .{ .seed = 0xBBBB, .components = &calm_components };
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
    while (i < 5000) : (i += 1) {
        const x = (r.float(f32) - 0.5) * 1000.0;
        const z = (r.float(f32) - 0.5) * 1000.0;
        const t = r.float(f32) * 60.0;
        calm_max = @max(calm_max, @abs(waveHeight(calm, x, z, t)));
        storm_max = @max(storm_max, @abs(waveHeight(storm, x, z, t)));
    }
    try testing.expect(storm_max > calm_max * 3.0);
}

test "single component: known height at known phase" {
    // One component aligned with +x: theta = k*x - omega*t + phi.
    // Pick (x,z,t) so theta - phi = 0 → height = A*sin(phi).
    const single = [_]GerstnerComponent{
        .{ .amplitude = 1.0, .wavelength = 20.0, .direction = .{ 1.0, 0.0 }, .speed = 2.0, .steepness = 0.0 },
    };
    const params: WaveParams = .{ .seed = 42, .components = &single };
    const phi = componentPhase(42, 0);
    // theta - phi = k*x - omega*t = 0 at x=0, t=0
    const h = waveHeight(params, 0, 0, 0);
    try testing.expectApproxEqAbs(@sin(phi), h, 1e-6);
}

test "normal is unit length" {
    var rng = std.Random.DefaultPrng.init(0x9999);
    const r = rng.random();
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const x = (r.float(f32) - 0.5) * 500.0;
        const z = (r.float(f32) - 0.5) * 500.0;
        const t = r.float(f32) * 60.0;
        const n = waveNormal(choppy, x, z, t);
        const len = @sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
        try testing.expectApproxEqAbs(@as(f32, 1.0), len, 1e-5);
    }
}

test "normal points up on average" {
    // Surface y-component of normal should be positive almost everywhere
    // (only fails at very high steepness near wave self-intersection).
    var rng = std.Random.DefaultPrng.init(0x7777);
    const r = rng.random();
    var sum_ny: f32 = 0;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const x = (r.float(f32) - 0.5) * 500.0;
        const z = (r.float(f32) - 0.5) * 500.0;
        const t = r.float(f32) * 60.0;
        sum_ny += waveNormal(choppy, x, z, t).y;
    }
    try testing.expect(sum_ny / 1000.0 > 0.9);
}
