//! Inheritance-aware loader for `data/hulls/*.yaml`.
//!
//! On-disk schema accepts an optional `extends: <relative path>`
//! field. The loader walks the chain depth-first, merges child OVER
//! parent (any non-null field on the child overrides the parent's
//! value, arrays REPLACE rather than append), then validates that
//! every required field on `HullConfig` is non-null at the leaf.
//!
//! Why a hand-rolled parser instead of ymlz: ymlz panics on missing
//! fields (it parses in declaration order and fails when fewer
//! fields than the struct are present), which kills the whole
//! `extends` premise — children are *expected* to leave most fields
//! empty. Fit-for-purpose flat-key parser based on the same shape as
//! `shared/bt_loader.zig`.
//!
//! Path resolution: `extends:` values are resolved relative to the
//! file containing the `extends:` line. So `data/hulls/sloop.yaml`
//! saying `extends: _base.yaml` looks up `data/hulls/_base.yaml`.
//! Use a leading `./` if you want to be explicit.

const std = @import("std");
const hull_config = @import("hull_config.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    UnexpectedEof,
    InvalidSyntax,
    InvalidNumber,
    UnknownKey,
    DuplicateKey,
    MissingField,
    ExtendsCycle,
    OutOfMemory,
    FileTooBig,
} || std.fs.File.OpenError || std.fs.File.ReadError || std.fs.File.StatError || std.fs.Dir.RealPathError;

/// Loaded hull + its arena. Owns every slice the config points at;
/// caller `deinit`s when done.
pub const Hull = struct {
    config: hull_config.HullConfig,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Hull) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const max_extends_depth: u32 = 8;

pub fn loadFromFile(gpa: Allocator, abs_path: []const u8) Error!Hull {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const raw = try loadRaw(aa, abs_path, 0);
    const cfg = try resolve(aa, raw);
    return .{ .config = cfg, .arena = arena };
}

// ----- raw (per-file) shape -----

const RawSample = struct {
    x: ?f32 = null,
    y: ?f32 = null,
    z: ?f32 = null,
};

const RawCannon = struct {
    offset_x: ?f32 = null,
    offset_y: ?f32 = null,
    offset_z: ?f32 = null,
    cooldown_s: ?f32 = null,
    range_m: ?f32 = null,
};

const RawHull = struct {
    extends: ?[]const u8 = null,
    half_extents_x: ?f32 = null,
    half_extents_y: ?f32 = null,
    half_extents_z: ?f32 = null,
    mass_kg: ?f32 = null,
    hp_max: ?f32 = null,
    cell_half_height: ?f32 = null,
    cell_cross_section: ?f32 = null,
    drag_per_point: ?f32 = null,
    sail_force_max_n: ?f32 = null,
    sail_baseline_mps: ?f32 = null,
    steer_max_n: ?f32 = null,
    sample_points: ?[]RawSample = null,
    cannons: ?[]RawCannon = null,
};

// ----- chain resolution -----

fn loadRaw(arena_alloc: Allocator, abs_path: []const u8, depth: u32) Error!RawHull {
    if (depth > max_extends_depth) return error.ExtendsCycle;

    const f = try std.fs.cwd().openFile(abs_path, .{});
    defer f.close();
    const stat = try f.stat();
    if (stat.size > 1 << 20) return error.FileTooBig; // 1 MB sanity cap
    const buf = try arena_alloc.alloc(u8, stat.size);
    _ = try f.readAll(buf);

    var p: Parser = .{ .src = buf, .arena = arena_alloc };
    var raw = try p.parseFile();

    if (raw.extends) |ext_path| {
        const dir = std.fs.path.dirname(abs_path) orelse ".";
        const joined = try std.fs.path.resolve(arena_alloc, &.{ dir, ext_path });
        const parent = try loadRaw(arena_alloc, joined, depth + 1);
        raw = mergeOver(parent, raw);
    }
    return raw;
}

/// Merge `child` over `parent`. Any field set on `child` (non-null)
/// wins; otherwise the parent's value passes through. Arrays
/// (`sample_points`, `cannons`) REPLACE wholesale when the child
/// sets them — there's no append/insert/diff. Composing batteries
/// across multiple inheritance levels is the child's job.
fn mergeOver(parent: RawHull, child: RawHull) RawHull {
    return .{
        .extends = null, // already resolved
        .half_extents_x = child.half_extents_x orelse parent.half_extents_x,
        .half_extents_y = child.half_extents_y orelse parent.half_extents_y,
        .half_extents_z = child.half_extents_z orelse parent.half_extents_z,
        .mass_kg = child.mass_kg orelse parent.mass_kg,
        .hp_max = child.hp_max orelse parent.hp_max,
        .cell_half_height = child.cell_half_height orelse parent.cell_half_height,
        .cell_cross_section = child.cell_cross_section orelse parent.cell_cross_section,
        .drag_per_point = child.drag_per_point orelse parent.drag_per_point,
        .sail_force_max_n = child.sail_force_max_n orelse parent.sail_force_max_n,
        .sail_baseline_mps = child.sail_baseline_mps orelse parent.sail_baseline_mps,
        .steer_max_n = child.steer_max_n orelse parent.steer_max_n,
        .sample_points = child.sample_points orelse parent.sample_points,
        .cannons = child.cannons orelse parent.cannons,
    };
}

fn resolve(arena_alloc: Allocator, raw: RawHull) Error!hull_config.HullConfig {
    const samples_raw = raw.sample_points orelse return error.MissingField;
    const cannons_raw = raw.cannons orelse return error.MissingField;

    const samples = try arena_alloc.alloc([3]f32, samples_raw.len);
    for (samples_raw, 0..) |s, i| {
        samples[i] = .{
            s.x orelse return error.MissingField,
            s.y orelse return error.MissingField,
            s.z orelse return error.MissingField,
        };
    }

    const cannons = try arena_alloc.alloc(hull_config.Cannon, cannons_raw.len);
    for (cannons_raw, 0..) |c, i| {
        cannons[i] = .{
            .offset_x = c.offset_x orelse return error.MissingField,
            .offset_y = c.offset_y orelse return error.MissingField,
            .offset_z = c.offset_z orelse return error.MissingField,
            .cooldown_s = c.cooldown_s orelse return error.MissingField,
            .range_m = c.range_m orelse return error.MissingField,
        };
    }

    return .{
        .half_extents = .{
            raw.half_extents_x orelse return error.MissingField,
            raw.half_extents_y orelse return error.MissingField,
            raw.half_extents_z orelse return error.MissingField,
        },
        .mass_kg = raw.mass_kg orelse return error.MissingField,
        .hp_max = raw.hp_max orelse return error.MissingField,
        .cell_half_height = raw.cell_half_height orelse return error.MissingField,
        .cell_cross_section = raw.cell_cross_section orelse return error.MissingField,
        .drag_per_point = raw.drag_per_point orelse return error.MissingField,
        .sail_force_max_n = raw.sail_force_max_n orelse return error.MissingField,
        .sail_baseline_mps = raw.sail_baseline_mps orelse return error.MissingField,
        .steer_max_n = raw.steer_max_n orelse return error.MissingField,
        .sample_points = samples,
        .cannons = cannons,
    };
}

// ----- parser -----
//
// Scope: top-level `key: value` pairs, plus two array keys
// (`sample_points`, `cannons`) whose elements are nested
// `- key: value` blocks. Same shape as `shared/bt_loader.zig`'s
// `nodes:` parser. Comments (`#`), blank lines, and quoted strings
// are handled.

const LineInfo = struct {
    indent: usize,
    content: []const u8,
};

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    arena: Allocator,

    fn parseFile(self: *Parser) Error!RawHull {
        var raw: RawHull = .{};
        while (self.peekLine()) |line_info| {
            if (line_info.content.len == 0) {
                self.advanceLine();
                continue;
            }
            if (line_info.indent != 0) return error.InvalidSyntax;
            const line = line_info.content;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidSyntax;
            const key = std.mem.trim(u8, line[0..colon], " \t");
            const val = std.mem.trim(u8, stripComment(line[colon + 1 ..]), " \t");
            self.advanceLine();
            try self.applyTopKey(&raw, key, val);
        }
        return raw;
    }

    fn applyTopKey(self: *Parser, raw: *RawHull, key: []const u8, val: []const u8) Error!void {
        if (std.mem.eql(u8, key, "extends")) {
            if (raw.extends != null) return error.DuplicateKey;
            raw.extends = try unquoteString(val);
            return;
        }
        if (std.mem.eql(u8, key, "sample_points")) {
            if (raw.sample_points != null) return error.DuplicateKey;
            if (val.len != 0) return error.InvalidSyntax;
            raw.sample_points = try self.parseSampleList();
            return;
        }
        if (std.mem.eql(u8, key, "cannons")) {
            if (raw.cannons != null) return error.DuplicateKey;
            if (val.len != 0) return error.InvalidSyntax;
            raw.cannons = try self.parseCannonList();
            return;
        }

        // Numeric scalars. The repetition is intentional — comptime
        // generation here would be longer than the explicit list,
        // and field names trip the same `eql + parse` shape.
        const num = try parseFloat(val);
        if (std.mem.eql(u8, key, "half_extents_x")) {
            try assignOnce(&raw.half_extents_x, num);
        } else if (std.mem.eql(u8, key, "half_extents_y")) {
            try assignOnce(&raw.half_extents_y, num);
        } else if (std.mem.eql(u8, key, "half_extents_z")) {
            try assignOnce(&raw.half_extents_z, num);
        } else if (std.mem.eql(u8, key, "mass_kg")) {
            try assignOnce(&raw.mass_kg, num);
        } else if (std.mem.eql(u8, key, "hp_max")) {
            try assignOnce(&raw.hp_max, num);
        } else if (std.mem.eql(u8, key, "cell_half_height")) {
            try assignOnce(&raw.cell_half_height, num);
        } else if (std.mem.eql(u8, key, "cell_cross_section")) {
            try assignOnce(&raw.cell_cross_section, num);
        } else if (std.mem.eql(u8, key, "drag_per_point")) {
            try assignOnce(&raw.drag_per_point, num);
        } else if (std.mem.eql(u8, key, "sail_force_max_n")) {
            try assignOnce(&raw.sail_force_max_n, num);
        } else if (std.mem.eql(u8, key, "sail_baseline_mps")) {
            try assignOnce(&raw.sail_baseline_mps, num);
        } else if (std.mem.eql(u8, key, "steer_max_n")) {
            try assignOnce(&raw.steer_max_n, num);
        } else {
            return error.UnknownKey;
        }
    }

    fn parseSampleList(self: *Parser) Error![]RawSample {
        var list: std.ArrayListUnmanaged(RawSample) = .{};
        while (self.peekLine()) |line_info| {
            if (line_info.content.len == 0) {
                self.advanceLine();
                continue;
            }
            if (line_info.indent == 0) break;
            const sample = try self.parseSampleItem(line_info.indent);
            try list.append(self.arena, sample);
        }
        return try list.toOwnedSlice(self.arena);
    }

    fn parseSampleItem(self: *Parser, item_indent: usize) Error!RawSample {
        var sample: RawSample = .{};
        const first = self.peekLine() orelse return error.UnexpectedEof;
        const trimmed = std.mem.trimLeft(u8, first.content, " \t");
        if (!std.mem.startsWith(u8, trimmed, "- ")) return error.InvalidSyntax;
        try self.applySampleKv(&sample, trimmed[2..]);
        self.advanceLine();

        while (self.peekLine()) |line_info| {
            if (line_info.content.len == 0) {
                self.advanceLine();
                continue;
            }
            if (line_info.indent <= item_indent) break;
            const inner = std.mem.trimLeft(u8, line_info.content, " \t");
            if (std.mem.startsWith(u8, inner, "- ")) break;
            try self.applySampleKv(&sample, inner);
            self.advanceLine();
        }
        return sample;
    }

    fn applySampleKv(self: *Parser, s: *RawSample, line: []const u8) Error!void {
        _ = self;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidSyntax;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const val = std.mem.trim(u8, stripComment(line[colon + 1 ..]), " \t");
        const num = try parseFloat(val);
        if (std.mem.eql(u8, key, "x")) try assignOnce(&s.x, num)
        else if (std.mem.eql(u8, key, "y")) try assignOnce(&s.y, num)
        else if (std.mem.eql(u8, key, "z")) try assignOnce(&s.z, num)
        else return error.UnknownKey;
    }

    fn parseCannonList(self: *Parser) Error![]RawCannon {
        var list: std.ArrayListUnmanaged(RawCannon) = .{};
        while (self.peekLine()) |line_info| {
            if (line_info.content.len == 0) {
                self.advanceLine();
                continue;
            }
            if (line_info.indent == 0) break;
            const c = try self.parseCannonItem(line_info.indent);
            try list.append(self.arena, c);
        }
        return try list.toOwnedSlice(self.arena);
    }

    fn parseCannonItem(self: *Parser, item_indent: usize) Error!RawCannon {
        var c: RawCannon = .{};
        const first = self.peekLine() orelse return error.UnexpectedEof;
        const trimmed = std.mem.trimLeft(u8, first.content, " \t");
        if (!std.mem.startsWith(u8, trimmed, "- ")) return error.InvalidSyntax;
        try self.applyCannonKv(&c, trimmed[2..]);
        self.advanceLine();

        while (self.peekLine()) |line_info| {
            if (line_info.content.len == 0) {
                self.advanceLine();
                continue;
            }
            if (line_info.indent <= item_indent) break;
            const inner = std.mem.trimLeft(u8, line_info.content, " \t");
            if (std.mem.startsWith(u8, inner, "- ")) break;
            try self.applyCannonKv(&c, inner);
            self.advanceLine();
        }
        return c;
    }

    fn applyCannonKv(self: *Parser, c: *RawCannon, line: []const u8) Error!void {
        _ = self;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidSyntax;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const val = std.mem.trim(u8, stripComment(line[colon + 1 ..]), " \t");
        const num = try parseFloat(val);
        if (std.mem.eql(u8, key, "offset_x")) try assignOnce(&c.offset_x, num)
        else if (std.mem.eql(u8, key, "offset_y")) try assignOnce(&c.offset_y, num)
        else if (std.mem.eql(u8, key, "offset_z")) try assignOnce(&c.offset_z, num)
        else if (std.mem.eql(u8, key, "cooldown_s")) try assignOnce(&c.cooldown_s, num)
        else if (std.mem.eql(u8, key, "range_m")) try assignOnce(&c.range_m, num)
        else return error.UnknownKey;
    }

    // ----- low-level line walker -----

    fn peekLine(self: *Parser) ?LineInfo {
        if (self.pos >= self.src.len) return null;
        const line_end = std.mem.indexOfScalarPos(u8, self.src, self.pos, '\n') orelse self.src.len;
        const raw_line = self.src[self.pos..line_end];
        // Strip comments + trailing whitespace.
        const stripped = std.mem.trimRight(u8, stripComment(raw_line), " \t\r");
        // Indent is leading-space count.
        var indent: usize = 0;
        while (indent < stripped.len and stripped[indent] == ' ') indent += 1;
        const content = stripped[indent..];
        return .{ .indent = indent, .content = content };
    }

    fn advanceLine(self: *Parser) void {
        const line_end = std.mem.indexOfScalarPos(u8, self.src, self.pos, '\n') orelse self.src.len;
        self.pos = if (line_end < self.src.len) line_end + 1 else self.src.len;
    }
};

fn stripComment(line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, line, '#')) |i| return line[0..i];
    return line;
}

fn unquoteString(val: []const u8) Error![]const u8 {
    if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
        return val[1 .. val.len - 1];
    }
    return val;
}

fn parseFloat(val: []const u8) Error!f32 {
    return std.fmt.parseFloat(f32, val) catch error.InvalidNumber;
}

fn assignOnce(slot: *?f32, num: f32) Error!void {
    if (slot.* != null) return error.DuplicateKey;
    slot.* = num;
}

// ----- tests -----

const testing = std.testing;

test "load _base.yaml: every required field non-null" {
    var hull = try loadFromFile(testing.allocator, "data/hulls/_base.yaml");
    defer hull.deinit();
    try testing.expectEqual(@as(f32, 2.0), hull.config.half_extents[0]);
    try testing.expectEqual(@as(f32, 1.25), hull.config.half_extents[1]);
    try testing.expectEqual(@as(f32, 3.0), hull.config.half_extents[2]);
    try testing.expectEqual(@as(f32, 15000.0), hull.config.mass_kg);
    try testing.expectEqual(@as(f32, 300.0), hull.config.hp_max);
    try testing.expectEqual(@as(f32, 60000.0), hull.config.sail_force_max_n);
    try testing.expectEqual(@as(f32, 30000.0), hull.config.steer_max_n);
    try testing.expectEqual(@as(usize, 8), hull.config.sample_points.len);
    try testing.expectEqual(@as(usize, 1), hull.config.cannons.len);
    try testing.expectEqual(@as(f32, 2.0), hull.config.cannons[0].offset_x);
    try testing.expectEqual(@as(f32, 1.5), hull.config.cannons[0].cooldown_s);
    try testing.expectEqual(@as(f32, 200.0), hull.config.cannons[0].range_m);
}

test "extends-only child resolves to parent's values" {
    // `data/hulls/sloop.yaml` is `extends: _base.yaml` with no
    // overrides — should match `_base.yaml` field-for-field.
    var sloop = try loadFromFile(testing.allocator, "data/hulls/sloop.yaml");
    defer sloop.deinit();
    var base = try loadFromFile(testing.allocator, "data/hulls/_base.yaml");
    defer base.deinit();
    try testing.expectEqual(base.config.mass_kg, sloop.config.mass_kg);
    try testing.expectEqual(base.config.hp_max, sloop.config.hp_max);
    try testing.expectEqual(base.config.sail_force_max_n, sloop.config.sail_force_max_n);
    try testing.expectEqual(base.config.sample_points.len, sloop.config.sample_points.len);
    try testing.expectEqual(base.config.cannons.len, sloop.config.cannons.len);
}

test "child overrides win, untouched fields inherit" {
    // Synthesize a tier hull in a tmp dir that overrides mass + hp,
    // adds a 2-cannon battery, leaves the rest from base.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_yaml =
        \\half_extents_x: 2.0
        \\half_extents_y: 1.25
        \\half_extents_z: 3.0
        \\mass_kg: 15000
        \\hp_max: 300
        \\cell_half_height: 0.625
        \\cell_cross_section: 6.0
        \\drag_per_point: 15000
        \\sail_force_max_n: 60000
        \\sail_baseline_mps: 10
        \\steer_max_n: 30000
        \\sample_points:
        \\  - x: -1
        \\    y: -0.625
        \\    z: -1.5
        \\  - x: 1
        \\    y: 0.625
        \\    z: 1.5
        \\cannons:
        \\  - offset_x: 2.0
        \\    offset_y: 1.0
        \\    offset_z: 0.0
        \\    cooldown_s: 1.5
        \\    range_m: 200
    ;
    try tmp.dir.writeFile(.{ .sub_path = "_base.yaml", .data = base_yaml });

    const tier_yaml =
        \\extends: _base.yaml
        \\mass_kg: 22000
        \\hp_max: 450
        \\cannons:
        \\  - offset_x: 2.5
        \\    offset_y: 1.0
        \\    offset_z: -2.0
        \\    cooldown_s: 1.5
        \\    range_m: 200
        \\  - offset_x: 2.5
        \\    offset_y: 1.0
        \\    offset_z: 2.0
        \\    cooldown_s: 1.5
        \\    range_m: 200
    ;
    try tmp.dir.writeFile(.{ .sub_path = "tier.yaml", .data = tier_yaml });

    const path = try tmp.dir.realpathAlloc(testing.allocator, "tier.yaml");
    defer testing.allocator.free(path);

    var tier = try loadFromFile(testing.allocator, path);
    defer tier.deinit();

    // Overridden:
    try testing.expectEqual(@as(f32, 22000), tier.config.mass_kg);
    try testing.expectEqual(@as(f32, 450), tier.config.hp_max);
    try testing.expectEqual(@as(usize, 2), tier.config.cannons.len);
    try testing.expectEqual(@as(f32, -2.0), tier.config.cannons[0].offset_z);
    try testing.expectEqual(@as(f32, 2.0), tier.config.cannons[1].offset_z);
    // Inherited from base:
    try testing.expectEqual(@as(f32, 2.0), tier.config.half_extents[0]);
    try testing.expectEqual(@as(f32, 60000), tier.config.sail_force_max_n);
    try testing.expectEqual(@as(f32, 30000), tier.config.steer_max_n);
    try testing.expectEqual(@as(usize, 2), tier.config.sample_points.len);
}

test "missing required field at leaf surfaces MissingField" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // No extends, missing mass_kg.
    const yaml =
        \\half_extents_x: 2.0
        \\half_extents_y: 1.25
        \\half_extents_z: 3.0
        \\hp_max: 300
        \\cell_half_height: 0.625
        \\cell_cross_section: 6.0
        \\drag_per_point: 15000
        \\sail_force_max_n: 60000
        \\sail_baseline_mps: 10
        \\steer_max_n: 30000
        \\sample_points:
        \\  - x: 0
        \\    y: 0
        \\    z: 0
        \\cannons:
        \\  - offset_x: 0
        \\    offset_y: 0
        \\    offset_z: 0
        \\    cooldown_s: 1
        \\    range_m: 100
    ;
    try tmp.dir.writeFile(.{ .sub_path = "broken.yaml", .data = yaml });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "broken.yaml");
    defer testing.allocator.free(path);

    try testing.expectError(error.MissingField, loadFromFile(testing.allocator, path));
}

test "extends cycle bounded by max_extends_depth" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = "extends: b.yaml\n";
    const b = "extends: a.yaml\n";
    try tmp.dir.writeFile(.{ .sub_path = "a.yaml", .data = a });
    try tmp.dir.writeFile(.{ .sub_path = "b.yaml", .data = b });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "a.yaml");
    defer testing.allocator.free(path);
    try testing.expectError(error.ExtendsCycle, loadFromFile(testing.allocator, path));
}
