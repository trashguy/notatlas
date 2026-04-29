//! YAML loaders for `data/waves/*.yaml` (wave kernel params) and
//! `data/ocean.yaml` (shading/foam/fog params).
//!
//! ymlz quirks worth remembering: it panics on blank lines, it can't parse
//! fixed-size arrays, and it parses fields in source-file declaration
//! order. See `feedback_ymlz_blank_lines.md`.

const std = @import("std");
const ymlz = @import("ymlz");
const wave = @import("wave_query.zig");
const wind = @import("wind_query.zig");
const ocean_params_mod = @import("ocean_params.zig");
const hull_mod = @import("hull_params.zig");
const replication = @import("shared/replication.zig");

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
// data/ships/*.yaml
// ------------------------------------------------------------

const RawSamplePoint = struct {
    x: f32,
    y: f32,
    z: f32,
};

const RawHullParams = struct {
    half_extents_x: f32,
    half_extents_y: f32,
    half_extents_z: f32,
    mass_kg: f32,
    cell_half_height: f32,
    cell_cross_section: f32,
    drag_per_point: f32,
    sample_points: []RawSamplePoint,
};

/// Parse a hull YAML and return params with sample points copied into a
/// caller-owned slice. Caller frees via `HullParams.deinit(gpa)`.
pub fn loadHullFromFile(gpa: Allocator, abs_path: []const u8) !hull_mod.HullParams {
    var parser = try ymlz.Ymlz(RawHullParams).init(gpa);
    const raw = try parser.loadFile(abs_path);
    defer parser.deinit(raw);

    const samples = try gpa.alloc([3]f32, raw.sample_points.len);
    errdefer gpa.free(samples);
    for (raw.sample_points, 0..) |p, i| samples[i] = .{ p.x, p.y, p.z };

    return .{
        .half_extents = .{ raw.half_extents_x, raw.half_extents_y, raw.half_extents_z },
        .mass_kg = raw.mass_kg,
        .cell_half_height = raw.cell_half_height,
        .cell_cross_section = raw.cell_cross_section,
        .drag_per_point = raw.drag_per_point,
        .sample_points = samples,
    };
}

// ------------------------------------------------------------
// data/wind.yaml
// ------------------------------------------------------------

const RawWindStorm = struct {
    radius_m: f32,
    strength_mps: f32,
    speed_mps: f32,
    vortex_mix: f32,
};

const RawWindParams = struct {
    seed: u64,
    base_speed_mps: f32,
    base_direction_rad: f32,
    shift_period_s: f32,
    shift_amplitude_rad: f32,
    storm_world_m: f32,
    storms: []RawWindStorm,
};

/// Parse a wind YAML and return params with storms copied into a
/// caller-owned slice. Caller frees via `WindParams.deinit(gpa)`.
pub fn loadWindFromFile(gpa: Allocator, abs_path: []const u8) !wind.WindParams {
    var parser = try ymlz.Ymlz(RawWindParams).init(gpa);
    const raw = try parser.loadFile(abs_path);
    defer parser.deinit(raw);

    const cells = try gpa.alloc(wind.WindStorm, raw.storms.len);
    errdefer gpa.free(cells);
    for (raw.storms, 0..) |s, i| cells[i] = .{
        .radius_m = s.radius_m,
        .strength_mps = s.strength_mps,
        .speed_mps = s.speed_mps,
        .vortex_mix = s.vortex_mix,
    };

    return .{
        .seed = raw.seed,
        .base_speed_mps = raw.base_speed_mps,
        .base_direction_rad = raw.base_direction_rad,
        .shift_period_s = raw.shift_period_s,
        .shift_amplitude_rad = raw.shift_amplitude_rad,
        .storm_world_m = raw.storm_world_m,
        .storms = cells,
    };
}

// ------------------------------------------------------------
// data/tier_distances.yaml
// ------------------------------------------------------------

const RawTierThresholds = struct {
    fleet_aggregate_range_m: f32,
    visual_range_m: f32,
    close_combat_range_m: f32,
};

pub fn loadTierThresholdsFromFile(
    allocator: Allocator,
    abs_path: []const u8,
) !replication.TierThresholds {
    var parser = try ymlz.Ymlz(RawTierThresholds).init(allocator);
    const raw = try parser.loadFile(abs_path);
    defer parser.deinit(raw);
    return .{
        .fleet_aggregate_range_m = raw.fleet_aggregate_range_m,
        .visual_range_m = raw.visual_range_m,
        .close_combat_range_m = raw.close_combat_range_m,
    };
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

test "load box hull.yaml round-trips fields and 8 sample points" {
    const abs = try std.fs.cwd().realpathAlloc(testing.allocator, "data/ships/box.yaml");
    defer testing.allocator.free(abs);
    const hull = try loadHullFromFile(testing.allocator, abs);
    defer hull.deinit(testing.allocator);

    // Updated at M5.5 to a 4 × 2.5 × 6 m rectangle (more boat-like than
    // the original 4 m cube). 2×2×2 sample grid still spans the volume.
    try testing.expectEqual(@as(f32, 2.0), hull.half_extents[0]);
    try testing.expectEqual(@as(f32, 1.25), hull.half_extents[1]);
    try testing.expectEqual(@as(f32, 3.0), hull.half_extents[2]);
    try testing.expectEqual(@as(f32, 15000.0), hull.mass_kg);
    try testing.expectEqual(@as(f32, 0.625), hull.cell_half_height);
    try testing.expectEqual(@as(f32, 6.0), hull.cell_cross_section);
    try testing.expectEqual(@as(f32, 15000.0), hull.drag_per_point);

    try testing.expectEqual(@as(usize, 8), hull.sample_points.len);
    for (hull.sample_points) |p| {
        try testing.expect(p[0] == 1.0 or p[0] == -1.0);
        try testing.expect(p[1] == 0.625 or p[1] == -0.625);
        try testing.expect(p[2] == 1.5 or p[2] == -1.5);
    }
}

test "load wind.yaml matches storm preset fixture" {
    const abs = try std.fs.cwd().realpathAlloc(testing.allocator, "data/wind.yaml");
    defer testing.allocator.free(abs);
    const loaded = try loadWindFromFile(testing.allocator, abs);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(wind.storm.seed, loaded.seed);
    try testing.expectEqual(wind.storm.base_speed_mps, loaded.base_speed_mps);
    try testing.expectEqual(wind.storm.base_direction_rad, loaded.base_direction_rad);
    try testing.expectEqual(wind.storm.shift_period_s, loaded.shift_period_s);
    try testing.expectEqual(wind.storm.shift_amplitude_rad, loaded.shift_amplitude_rad);
    try testing.expectEqual(wind.storm.storm_world_m, loaded.storm_world_m);
    try testing.expectEqual(wind.storm.storms.len, loaded.storms.len);
    for (wind.storm.storms, loaded.storms) |w, l| {
        try testing.expectEqual(w.radius_m, l.radius_m);
        try testing.expectEqual(w.strength_mps, l.strength_mps);
        try testing.expectEqual(w.speed_mps, l.speed_mps);
        try testing.expectEqual(w.vortex_mix, l.vortex_mix);
    }
}

test "loaded wind produces same windAt as preset" {
    const abs = try std.fs.cwd().realpathAlloc(testing.allocator, "data/wind.yaml");
    defer testing.allocator.free(abs);
    const loaded = try loadWindFromFile(testing.allocator, abs);
    defer loaded.deinit(testing.allocator);

    var rng = std.Random.DefaultPrng.init(0xBEEF);
    const r = rng.random();
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const x = (r.float(f32) - 0.5) * 4000.0;
        const z = (r.float(f32) - 0.5) * 4000.0;
        const t = r.float(f32) * 600.0;
        const a = wind.windAt(wind.storm, x, z, t);
        const b = wind.windAt(loaded, x, z, t);
        try testing.expectEqual(a[0], b[0]);
        try testing.expectEqual(a[1], b[1]);
    }
}

test "load tier_distances.yaml matches TierThresholds.default" {
    const abs = try std.fs.cwd().realpathAlloc(testing.allocator, "data/tier_distances.yaml");
    defer testing.allocator.free(abs);
    const loaded = try loadTierThresholdsFromFile(testing.allocator, abs);
    const want = replication.TierThresholds.default;
    try testing.expectEqual(want.fleet_aggregate_range_m, loaded.fleet_aggregate_range_m);
    try testing.expectEqual(want.visual_range_m, loaded.visual_range_m);
    try testing.expectEqual(want.close_combat_range_m, loaded.close_combat_range_m);
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
