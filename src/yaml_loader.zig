//! YAML loaders for `data/waves/*.yaml` (wave kernel params) and
//! `data/ocean.yaml` (shading/foam/fog params).
//!
//! ymlz quirks worth remembering: it panics on blank lines, it can't parse
//! fixed-size arrays, and it parses fields in source-file declaration
//! order. See `feedback_ymlz_blank_lines.md`.

const std = @import("std");
const ymlz = @import("ymlz");
const wave = @import("wave_query.zig");
const ocean_params_mod = @import("ocean_params.zig");

const Allocator = std.mem.Allocator;

// ------------------------------------------------------------
// data/waves/*.yaml
// ------------------------------------------------------------

/// Mirror of `wave.WaveParams` field order; ymlz reads top-level fields
/// in declaration order. Kept separate so ymlz reflection doesn't see the
/// `_pad0` field that exists in the extern struct for std140 alignment.
const RawWaveParams = struct {
    seed: u64,
    iterations: u32,
    drag_multiplier: f32,
    amplitude_m: f32,
    wave_scale_m: f32,
    frequency_mult: f32,
    base_time_mult: f32,
    time_mult: f32,
    weight_decay: f32,
};

fn fromRawWave(raw: RawWaveParams) wave.WaveParams {
    return .{
        .seed = raw.seed,
        .iterations = raw.iterations,
        .drag_multiplier = raw.drag_multiplier,
        .amplitude_m = raw.amplitude_m,
        .wave_scale_m = raw.wave_scale_m,
        .frequency_mult = raw.frequency_mult,
        .base_time_mult = raw.base_time_mult,
        .time_mult = raw.time_mult,
        .weight_decay = raw.weight_decay,
    };
}

pub fn loadFromYaml(allocator: Allocator, yaml_text: []const u8) !wave.WaveParams {
    var parser = try ymlz.Ymlz(RawWaveParams).init(allocator);
    const raw = try parser.loadRaw(yaml_text);
    defer parser.deinit(raw);
    return fromRawWave(raw);
}

pub fn loadFromFile(allocator: Allocator, abs_path: []const u8) !wave.WaveParams {
    var parser = try ymlz.Ymlz(RawWaveParams).init(allocator);
    const raw = try parser.loadFile(abs_path);
    defer parser.deinit(raw);
    return fromRawWave(raw);
}

// ------------------------------------------------------------
// data/ocean.yaml
// ------------------------------------------------------------

const RawColor = struct {
    r: f32,
    g: f32,
    b: f32,
};

const RawOceanParams = struct {
    shallow_color: RawColor,
    deep_color: RawColor,
    crest_curvature_threshold: f32,
    crest_width: f32,
    fog_color: RawColor,
    fog_density: f32,
};

fn fromRawOcean(raw: RawOceanParams) ocean_params_mod.OceanParams {
    return .{
        .shallow_color = .{ raw.shallow_color.r, raw.shallow_color.g, raw.shallow_color.b },
        .deep_color = .{ raw.deep_color.r, raw.deep_color.g, raw.deep_color.b },
        .crest_curvature_threshold = raw.crest_curvature_threshold,
        .crest_width = raw.crest_width,
        .fog_color = .{ raw.fog_color.r, raw.fog_color.g, raw.fog_color.b },
        .fog_density = raw.fog_density,
    };
}

pub fn loadOceanFromFile(allocator: Allocator, abs_path: []const u8) !ocean_params_mod.OceanParams {
    var parser = try ymlz.Ymlz(RawOceanParams).init(allocator);
    const raw = try parser.loadFile(abs_path);
    defer parser.deinit(raw);
    return fromRawOcean(raw);
}

pub fn loadOceanFromYaml(allocator: Allocator, yaml_text: []const u8) !ocean_params_mod.OceanParams {
    var parser = try ymlz.Ymlz(RawOceanParams).init(allocator);
    const raw = try parser.loadRaw(yaml_text);
    defer parser.deinit(raw);
    return fromRawOcean(raw);
}

// ------------------------------------------------------------
// Tests
// ------------------------------------------------------------

const testing = std.testing;

fn assertSameWaveParams(loaded: wave.WaveParams, expected: wave.WaveParams) !void {
    try testing.expectEqual(expected.seed, loaded.seed);
    try testing.expectEqual(expected.iterations, loaded.iterations);
    try testing.expectEqual(expected.drag_multiplier, loaded.drag_multiplier);
    try testing.expectEqual(expected.amplitude_m, loaded.amplitude_m);
    try testing.expectEqual(expected.wave_scale_m, loaded.wave_scale_m);
    try testing.expectEqual(expected.frequency_mult, loaded.frequency_mult);
    try testing.expectEqual(expected.base_time_mult, loaded.base_time_mult);
    try testing.expectEqual(expected.time_mult, loaded.time_mult);
    try testing.expectEqual(expected.weight_decay, loaded.weight_decay);
}

fn loadWaveFixture(rel_path: []const u8) !wave.WaveParams {
    const abs = try std.fs.cwd().realpathAlloc(testing.allocator, rel_path);
    defer testing.allocator.free(abs);
    return loadFromFile(testing.allocator, abs);
}

test "load calm.yaml matches hand-coded fixture" {
    const loaded = try loadWaveFixture("data/waves/calm.yaml");
    try assertSameWaveParams(loaded, wave.calm);
}

test "load choppy.yaml matches hand-coded fixture" {
    const loaded = try loadWaveFixture("data/waves/choppy.yaml");
    try assertSameWaveParams(loaded, wave.choppy);
}

test "load storm.yaml matches hand-coded fixture" {
    const loaded = try loadWaveFixture("data/waves/storm.yaml");
    try assertSameWaveParams(loaded, wave.storm);
}

test "loaded wave produces same heights as hand-coded fixture" {
    const lp = try loadWaveFixture("data/waves/choppy.yaml");
    var rng = std.Random.DefaultPrng.init(0xFEED);
    const r = rng.random();
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const x = (r.float(f32) - 0.5) * 1000.0;
        const z = (r.float(f32) - 0.5) * 1000.0;
        const t = r.float(f32) * 60.0;
        try testing.expectEqual(
            wave.waveHeight(wave.choppy, x, z, t),
            wave.waveHeight(lp, x, z, t),
        );
    }
}

test "load ocean.yaml matches OceanParams.default" {
    const abs = try std.fs.cwd().realpathAlloc(testing.allocator, "data/ocean.yaml");
    defer testing.allocator.free(abs);
    const loaded = try loadOceanFromFile(testing.allocator, abs);
    const want = ocean_params_mod.OceanParams.default;
    inline for (.{ "shallow_color", "deep_color", "fog_color" }) |field| {
        try testing.expectEqual(@field(want, field)[0], @field(loaded, field)[0]);
        try testing.expectEqual(@field(want, field)[1], @field(loaded, field)[1]);
        try testing.expectEqual(@field(want, field)[2], @field(loaded, field)[2]);
    }
    try testing.expectEqual(want.crest_curvature_threshold, loaded.crest_curvature_threshold);
    try testing.expectEqual(want.crest_width, loaded.crest_width);
    try testing.expectEqual(want.fog_density, loaded.fog_density);
}
