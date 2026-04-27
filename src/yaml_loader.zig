const std = @import("std");
const ymlz = @import("ymlz");
const wave = @import("wave_query.zig");

const Allocator = std.mem.Allocator;

const RawDirection = struct {
    x: f32,
    z: f32,
};

const RawGerstnerComponent = struct {
    amplitude: f32,
    wavelength: f32,
    direction: RawDirection,
    speed: f32,
    steepness: f32,
};

const RawWaveParams = struct {
    seed: u64,
    components: []RawGerstnerComponent,
};

pub const LoadedWaveParams = struct {
    seed: u64,
    components: []wave.GerstnerComponent,
    allocator: Allocator,

    pub fn params(self: *const LoadedWaveParams) wave.WaveParams {
        return .{ .seed = self.seed, .components = self.components };
    }

    pub fn deinit(self: *LoadedWaveParams) void {
        self.allocator.free(self.components);
    }
};

pub fn loadFromYaml(allocator: Allocator, yaml_text: []const u8) !LoadedWaveParams {
    var parser = try ymlz.Ymlz(RawWaveParams).init(allocator);
    const raw = try parser.loadRaw(yaml_text);
    defer parser.deinit(raw);

    const components = try allocator.alloc(wave.GerstnerComponent, raw.components.len);
    errdefer allocator.free(components);

    for (raw.components, 0..) |rc, i| {
        components[i] = .{
            .amplitude = rc.amplitude,
            .wavelength = rc.wavelength,
            .direction = .{ rc.direction.x, rc.direction.z },
            .speed = rc.speed,
            .steepness = rc.steepness,
        };
    }

    return .{
        .seed = raw.seed,
        .components = components,
        .allocator = allocator,
    };
}

pub fn loadFromFile(allocator: Allocator, abs_path: []const u8) !LoadedWaveParams {
    var parser = try ymlz.Ymlz(RawWaveParams).init(allocator);
    const raw = try parser.loadFile(abs_path);
    defer parser.deinit(raw);

    const components = try allocator.alloc(wave.GerstnerComponent, raw.components.len);
    errdefer allocator.free(components);

    for (raw.components, 0..) |rc, i| {
        components[i] = .{
            .amplitude = rc.amplitude,
            .wavelength = rc.wavelength,
            .direction = .{ rc.direction.x, rc.direction.z },
            .speed = rc.speed,
            .steepness = rc.steepness,
        };
    }

    return .{
        .seed = raw.seed,
        .components = components,
        .allocator = allocator,
    };
}

// ------------------------------------------------------------
// Tests
// ------------------------------------------------------------

const testing = std.testing;

fn assertSameWaveParams(loaded: wave.WaveParams, expected: wave.WaveParams) !void {
    try testing.expectEqual(expected.seed, loaded.seed);
    try testing.expectEqual(expected.components.len, loaded.components.len);
    for (expected.components, loaded.components) |e, l| {
        try testing.expectEqual(e.amplitude, l.amplitude);
        try testing.expectEqual(e.wavelength, l.wavelength);
        try testing.expectEqual(e.direction[0], l.direction[0]);
        try testing.expectEqual(e.direction[1], l.direction[1]);
        try testing.expectEqual(e.speed, l.speed);
        try testing.expectEqual(e.steepness, l.steepness);
    }
}

fn loadFixture(rel_path: []const u8) !LoadedWaveParams {
    const abs = try std.fs.cwd().realpathAlloc(testing.allocator, rel_path);
    defer testing.allocator.free(abs);
    return loadFromFile(testing.allocator, abs);
}

test "load calm.yaml matches hand-coded fixture" {
    var loaded = try loadFixture("data/waves/calm.yaml");
    defer loaded.deinit();
    try assertSameWaveParams(loaded.params(), wave.calm);
}

test "load choppy.yaml matches hand-coded fixture" {
    var loaded = try loadFixture("data/waves/choppy.yaml");
    defer loaded.deinit();
    try assertSameWaveParams(loaded.params(), wave.choppy);
}

test "load storm.yaml matches hand-coded fixture" {
    var loaded = try loadFixture("data/waves/storm.yaml");
    defer loaded.deinit();
    try assertSameWaveParams(loaded.params(), wave.storm);
}

test "loaded wave produces same heights as hand-coded fixture" {
    var loaded = try loadFixture("data/waves/choppy.yaml");
    defer loaded.deinit();
    const lp = loaded.params();
    var rng = std.Random.DefaultPrng.init(0xFEED);
    const r = rng.random();
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const x = (r.float(f32) - 0.5) * 1000.0;
        const z = (r.float(f32) - 0.5) * 1000.0;
        const t = r.float(f32) * 60.0;
        try testing.expectEqual(
            wave.waveHeight(wave.choppy, x, z, t),
            wave.waveHeight(lp, x, z, t),
        );
    }
}
