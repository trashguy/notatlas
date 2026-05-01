//! YAML → BT Tree loader.
//!
//! Per docs/09-ai-sim.md §5. The on-disk schema is a flat
//! adjacency-list — every node carries an `id`, every parent
//! references children by id. The nested-shape format from §5 of the
//! doc is the *authoring* picture; the loader stores trees flat
//! because:
//!   - it maps 1-to-1 to `bt.Node[]` with no intermediate alloc churn
//!   - validation (every reference is a valid id) is a one-pass
//!     check at load time
//!   - designers usually generate trees from a higher-level tool
//!     anyway; flat format is easier to template
//!
//! Why a custom parser instead of ymlz: ymlz 0.5 doesn't unwrap
//! optional ints in `parseNumericExpression`, can't parse slices of
//! primitives (`[]u16`), and its `parse()` loop assumes fields-read
//! count equals struct-fields count. The tree spec hits all three.
//! Writing a small fit-for-purpose parser is honest engineering
//! given those constraints — the schema is fixed and the surface is
//! ~150 lines.
//!
//! Validation guarantees on load:
//!   - every id is unique and dense (0 .. nodes.len-1)
//!   - every child reference points to a valid id
//!   - the `kind` string matches one of the six composite types or
//!     two leaf types
//!   - kind-specific required fields are present
//!     (e.g. `cooldown` requires `child` + `cooldown_ms`)

const std = @import("std");
const bt = @import("bt.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    // Parser
    UnexpectedEof,
    InvalidSyntax,
    InvalidInteger,
    UnknownKey,
    DuplicateKey,
    MissingKey,
    // Tree-level
    DuplicateNodeId,
    UnknownNodeKind,
    NodeIdOutOfRange,
    InvalidChildRef,
    UnknownParallelPolicy,
    // Per-kind required-field violations
    MissingLeafName,
    MissingChildren,
    MissingChild,
    MissingCooldownMs,
    // Allocation
    OutOfMemory,
};

// ----- public surface -----

/// Loaded tree + the metadata its YAML carried. Owns its memory;
/// caller `deinit`s.
pub const Archetype = struct {
    archetype: []const u8,
    description: []const u8,
    perception_radius: u32,
    nodes: []bt.Node,
    root: bt.NodeId,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Archetype) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Load + validate from a YAML file path. The file's contents are
/// read into the returned Archetype's arena so zero-copy string
/// slices stay valid until `deinit`.
pub fn loadFromFile(gpa: Allocator, abs_path: []const u8) !Archetype {
    const f = try std.fs.cwd().openFile(abs_path, .{});
    defer f.close();
    const stat = try f.stat();

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const buf = try arena.allocator().alloc(u8, stat.size);
    _ = try f.readAll(buf);

    return parseInto(arena, buf);
}

/// Load + validate from a YAML string in memory. The caller's
/// `source` slice is referenced zero-copy by the returned
/// Archetype — keep it live for the Archetype's lifetime, or use
/// `loadFromYamlOwned` to copy.
pub fn loadFromYaml(gpa: Allocator, source: []const u8) !Archetype {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    return parseInto(arena, source);
}

fn parseInto(arena: std.heap.ArenaAllocator, source: []const u8) !Archetype {
    var arena_var = arena;
    errdefer arena_var.deinit();
    var p: Parser = .{ .src = source, .arena = arena_var.allocator() };
    const raw = try p.parseFile();
    const nodes = try buildNodes(arena_var.allocator(), raw);

    const root = raw.root orelse return error.MissingKey;
    if (root >= nodes.len) return error.NodeIdOutOfRange;

    return .{
        .archetype = raw.archetype orelse return error.MissingKey,
        .description = raw.description orelse return error.MissingKey,
        .perception_radius = raw.perception_radius orelse return error.MissingKey,
        .nodes = nodes,
        .root = root,
        .arena = arena_var,
    };
}

/// Build a `bt.Tree` from a loaded archetype, allocating per-AI
/// runtime state. Caller `deinit`s the returned Tree's state slice.
pub fn instantiate(gpa: Allocator, archetype: *const Archetype) !bt.Tree {
    return bt.build(gpa, archetype.nodes, archetype.root);
}

// ----- intermediate (parsed YAML, not yet validated as a tree) -----

const RawNode = struct {
    id: ?u16 = null,
    kind: ?[]const u8 = null,
    leaf: ?[]const u8 = null,
    children: ?[]const u16 = null,
    child: ?u16 = null,
    policy: ?[]const u8 = null,
    cooldown_ms: ?u32 = null,
    max_iter: ?u32 = null,
};

const RawFile = struct {
    archetype: ?[]const u8 = null,
    description: ?[]const u8 = null,
    perception_radius: ?u32 = null,
    root: ?u16 = null,
    nodes: []RawNode = &.{},
};

// ----- conversion (raw → typed Node[]) -----

fn buildNodes(alloc: Allocator, raw: RawFile) ![]bt.Node {
    if (raw.nodes.len == 0) return alloc.alloc(bt.Node, 0);

    // Validate ids: dense, unique, all in range.
    const seen = try alloc.alloc(bool, raw.nodes.len);
    @memset(seen, false);
    for (raw.nodes) |rn| {
        const id = rn.id orelse return error.MissingKey;
        if (id >= raw.nodes.len) return error.NodeIdOutOfRange;
        if (seen[id]) return error.DuplicateNodeId;
        seen[id] = true;
    }

    const nodes = try alloc.alloc(bt.Node, raw.nodes.len);
    for (raw.nodes) |rn| {
        const id = rn.id.?;
        nodes[id] = try convertNode(alloc, rn, raw.nodes.len);
    }
    return nodes;
}

fn convertNode(alloc: Allocator, rn: RawNode, n_total: usize) Error!bt.Node {
    const kind = rn.kind orelse return error.MissingKey;

    if (std.mem.eql(u8, kind, "selector")) {
        const refs = rn.children orelse return error.MissingChildren;
        return .{ .selector = try dupeChildren(alloc, refs, n_total) };
    }
    if (std.mem.eql(u8, kind, "sequence")) {
        const refs = rn.children orelse return error.MissingChildren;
        return .{ .sequence = try dupeChildren(alloc, refs, n_total) };
    }
    if (std.mem.eql(u8, kind, "parallel")) {
        const refs = rn.children orelse return error.MissingChildren;
        const policy_str = rn.policy orelse return error.UnknownParallelPolicy;
        const policy = parsePolicy(policy_str) orelse return error.UnknownParallelPolicy;
        return .{ .parallel = .{
            .children = try dupeChildren(alloc, refs, n_total),
            .policy = policy,
        } };
    }
    if (std.mem.eql(u8, kind, "inverter")) {
        const child = rn.child orelse return error.MissingChild;
        if (child >= n_total) return error.InvalidChildRef;
        return .{ .inverter = child };
    }
    if (std.mem.eql(u8, kind, "cooldown")) {
        const child = rn.child orelse return error.MissingChild;
        const cooldown_ms = rn.cooldown_ms orelse return error.MissingCooldownMs;
        if (child >= n_total) return error.InvalidChildRef;
        return .{ .cooldown = .{ .child = child, .cooldown_ms = cooldown_ms } };
    }
    if (std.mem.eql(u8, kind, "repeat")) {
        const child = rn.child orelse return error.MissingChild;
        if (child >= n_total) return error.InvalidChildRef;
        return .{ .repeat = .{ .child = child, .max_iter = rn.max_iter orelse 0 } };
    }
    if (std.mem.eql(u8, kind, "cond")) {
        const leaf = rn.leaf orelse return error.MissingLeafName;
        return .{ .cond = .{ .name = try alloc.dupeZ(u8, leaf) } };
    }
    if (std.mem.eql(u8, kind, "action")) {
        const leaf = rn.leaf orelse return error.MissingLeafName;
        return .{ .action = .{ .name = try alloc.dupeZ(u8, leaf) } };
    }
    return error.UnknownNodeKind;
}

fn dupeChildren(alloc: Allocator, refs: []const u16, n_total: usize) Error![]bt.NodeId {
    const out = try alloc.alloc(bt.NodeId, refs.len);
    for (refs, 0..) |r, i| {
        if (r >= n_total) return error.InvalidChildRef;
        out[i] = r;
    }
    return out;
}

fn parsePolicy(s: []const u8) ?bt.ParallelPolicy {
    if (std.mem.eql(u8, s, "all_success")) return .all_success;
    if (std.mem.eql(u8, s, "any_success")) return .any_success;
    return null;
}

// ----- mini-parser -----
//
// Scope: enough YAML to parse our flat tree format.
//   - `key: value` pairs at top level
//   - `nodes:` followed by indented list of `- id: N` block items
//   - inside a node: `key: value` pairs, and `children: [0, 1, 2]`
//     flow-style integer arrays
//   - `# comment` lines and trailing comments
//   - blank lines ignored
//   - strings either bareword or `"quoted"` (no escapes; we don't
//     need them)
//
// What's NOT supported (and surfaces as `error.InvalidSyntax`):
//   - block-style sub-arrays (`children:\n  - 0\n  - 1`)
//     — flow style only, keeps the parser tractable
//   - multiline strings, anchors, nested sub-structs beyond `nodes`
//   - inline JSON-style flow maps (`{a: 1, b: 2}`)
//
// All slices returned point into either the source buffer
// (zero-copy strings) or the parser's arena (parsed integers /
// children arrays).

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    arena: Allocator,

    fn parseFile(self: *Parser) Error!RawFile {
        var file: RawFile = .{};
        var node_list: std.ArrayList(RawNode) = .empty;
        defer node_list.deinit(self.arena);

        while (self.peekLine()) |line_info| {
            const line = line_info.content;
            if (line.len == 0) {
                self.advanceLine();
                continue;
            }
            if (line_info.indent != 0) return error.InvalidSyntax;

            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidSyntax;
            const key = std.mem.trim(u8, line[0..colon], " \t");
            const val = std.mem.trim(u8, stripComment(line[colon + 1 ..]), " \t");

            self.advanceLine();

            if (std.mem.eql(u8, key, "archetype")) {
                file.archetype = try unquoteString(val);
            } else if (std.mem.eql(u8, key, "description")) {
                file.description = try unquoteString(val);
            } else if (std.mem.eql(u8, key, "perception_radius")) {
                file.perception_radius = try parseU32(val);
            } else if (std.mem.eql(u8, key, "root")) {
                file.root = try parseU16(val);
            } else if (std.mem.eql(u8, key, "nodes")) {
                if (val.len != 0) return error.InvalidSyntax;
                try self.parseNodeList(&node_list);
            } else {
                return error.UnknownKey;
            }
        }

        file.nodes = try node_list.toOwnedSlice(self.arena);
        return file;
    }

    fn parseNodeList(self: *Parser, list: *std.ArrayList(RawNode)) Error!void {
        while (self.peekLine()) |line_info| {
            if (line_info.content.len == 0) {
                self.advanceLine();
                continue;
            }
            if (line_info.indent == 0) return; // back at top level

            const trimmed = std.mem.trimLeft(u8, line_info.content, " \t");
            if (!std.mem.startsWith(u8, trimmed, "- ")) return error.InvalidSyntax;

            try list.append(self.arena, try self.parseNode(line_info.indent));
        }
    }

    fn parseNode(self: *Parser, item_indent: usize) Error!RawNode {
        var node: RawNode = .{};

        // First line: `  - key: value` — the `- ` leads, parse remaining.
        const first = self.peekLine() orelse return error.UnexpectedEof;
        const trimmed = std.mem.trimLeft(u8, first.content, " \t");
        if (!std.mem.startsWith(u8, trimmed, "- ")) return error.InvalidSyntax;
        const after_dash = trimmed[2..];
        try self.applyNodeKv(&node, after_dash);
        self.advanceLine();

        // Continuation lines: deeper indent than item_indent, no leading `- `.
        while (self.peekLine()) |line_info| {
            if (line_info.content.len == 0) {
                self.advanceLine();
                continue;
            }
            if (line_info.indent <= item_indent) break;
            const next_trimmed = std.mem.trimLeft(u8, line_info.content, " \t");
            if (std.mem.startsWith(u8, next_trimmed, "- ")) break;
            try self.applyNodeKv(&node, next_trimmed);
            self.advanceLine();
        }

        return node;
    }

    fn applyNodeKv(self: *Parser, node: *RawNode, kv_text: []const u8) Error!void {
        const colon = std.mem.indexOfScalar(u8, kv_text, ':') orelse return error.InvalidSyntax;
        const key = std.mem.trim(u8, kv_text[0..colon], " \t");
        const val = std.mem.trim(u8, stripComment(kv_text[colon + 1 ..]), " \t");

        if (std.mem.eql(u8, key, "id")) {
            if (node.id != null) return error.DuplicateKey;
            node.id = try parseU16(val);
        } else if (std.mem.eql(u8, key, "kind")) {
            if (node.kind != null) return error.DuplicateKey;
            node.kind = try unquoteString(val);
        } else if (std.mem.eql(u8, key, "leaf")) {
            if (node.leaf != null) return error.DuplicateKey;
            node.leaf = try unquoteString(val);
        } else if (std.mem.eql(u8, key, "children")) {
            if (node.children != null) return error.DuplicateKey;
            node.children = try self.parseFlowU16Array(val);
        } else if (std.mem.eql(u8, key, "child")) {
            if (node.child != null) return error.DuplicateKey;
            node.child = try parseU16(val);
        } else if (std.mem.eql(u8, key, "policy")) {
            if (node.policy != null) return error.DuplicateKey;
            node.policy = try unquoteString(val);
        } else if (std.mem.eql(u8, key, "cooldown_ms")) {
            if (node.cooldown_ms != null) return error.DuplicateKey;
            node.cooldown_ms = try parseU32(val);
        } else if (std.mem.eql(u8, key, "max_iter")) {
            if (node.max_iter != null) return error.DuplicateKey;
            node.max_iter = try parseU32(val);
        } else {
            return error.UnknownKey;
        }
    }

    fn parseFlowU16Array(self: *Parser, val: []const u8) Error![]u16 {
        if (val.len < 2 or val[0] != '[' or val[val.len - 1] != ']') return error.InvalidSyntax;
        const inside = std.mem.trim(u8, val[1 .. val.len - 1], " \t");
        if (inside.len == 0) return self.arena.alloc(u16, 0);

        var list: std.ArrayList(u16) = .empty;
        defer list.deinit(self.arena);
        var it = std.mem.tokenizeAny(u8, inside, ", \t");
        while (it.next()) |tok| {
            try list.append(self.arena, try parseU16(tok));
        }
        return list.toOwnedSlice(self.arena);
    }

    // ----- line-level scanner -----

    const LineInfo = struct {
        content: []const u8, // line text minus trailing newline; comments preserved (parsed off later)
        indent: usize, // number of leading spaces (tabs not supported)
    };

    fn peekLine(self: *Parser) ?LineInfo {
        var p = self.pos;
        while (p < self.src.len) {
            const end = std.mem.indexOfScalarPos(u8, self.src, p, '\n') orelse self.src.len;
            const line = self.src[p..end];
            const stripped = stripComment(line);
            const trimmed = std.mem.trim(u8, stripped, " \t");
            if (trimmed.len == 0) {
                // blank or comment-only — count as "no content" by skipping
                if (end == self.src.len) return null;
                p = end + 1;
                continue;
            }
            // Compute indent of original (pre-strip) line.
            var indent: usize = 0;
            while (indent < line.len and line[indent] == ' ') indent += 1;
            return .{ .content = line, .indent = indent };
        }
        return null;
    }

    fn advanceLine(self: *Parser) void {
        // Find current line end and move pos past it.
        const end = std.mem.indexOfScalarPos(u8, self.src, self.pos, '\n') orelse self.src.len;
        self.pos = if (end == self.src.len) self.src.len else end + 1;
        // If peekLine() previously skipped blank/comment lines internally, the
        // pos may be on one of those — advance past those too so the next
        // peekLine() sees the same line we just operated on, i.e. nothing.
        while (self.pos < self.src.len) {
            const e2 = std.mem.indexOfScalarPos(u8, self.src, self.pos, '\n') orelse self.src.len;
            const line = self.src[self.pos..e2];
            const trimmed = std.mem.trim(u8, stripComment(line), " \t");
            if (trimmed.len != 0) break;
            self.pos = if (e2 == self.src.len) self.src.len else e2 + 1;
        }
    }
};

fn stripComment(line: []const u8) []const u8 {
    // Bare `#` ends the line. We don't support `#` inside strings yet —
    // none of our schema needs it.
    if (std.mem.indexOfScalar(u8, line, '#')) |i| return line[0..i];
    return line;
}

fn unquoteString(val: []const u8) Error![]const u8 {
    if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
        return val[1 .. val.len - 1];
    }
    if (val.len >= 2 and val[0] == '\'' and val[val.len - 1] == '\'') {
        return val[1 .. val.len - 1];
    }
    if (val.len == 0) return error.InvalidSyntax;
    return val;
}

fn parseU16(val: []const u8) Error!u16 {
    return std.fmt.parseInt(u16, val, 10) catch return error.InvalidInteger;
}

fn parseU32(val: []const u8) Error!u32 {
    return std.fmt.parseInt(u32, val, 10) catch return error.InvalidInteger;
}

// ----- tests -----

const testing = std.testing;

test "load minimal tree — single action leaf" {
    const yaml =
        \\archetype: smoke_test
        \\description: One action, nothing else.
        \\perception_radius: 100
        \\root: 0
        \\nodes:
        \\  - id: 0
        \\    kind: action
        \\    leaf: noop
        \\
    ;
    var arch = try loadFromYaml(testing.allocator, yaml);
    defer arch.deinit();

    try testing.expectEqualStrings("smoke_test", arch.archetype);
    try testing.expectEqual(@as(u32, 100), arch.perception_radius);
    try testing.expectEqual(@as(usize, 1), arch.nodes.len);
    try testing.expectEqual(@as(bt.NodeId, 0), arch.root);
    try testing.expectEqualStrings("noop", arch.nodes[0].action.name);
}

test "load — selector with two cond/action sequences" {
    const yaml =
        \\archetype: two_branch
        \\description: Selector over two sequences.
        \\perception_radius: 200
        \\root: 4
        \\nodes:
        \\  - id: 0
        \\    kind: cond
        \\    leaf: low_hp
        \\  - id: 1
        \\    kind: action
        \\    leaf: flee
        \\  - id: 2
        \\    kind: sequence
        \\    children: [0, 1]
        \\  - id: 3
        \\    kind: action
        \\    leaf: patrol
        \\  - id: 4
        \\    kind: selector
        \\    children: [2, 3]
        \\
    ;
    var arch = try loadFromYaml(testing.allocator, yaml);
    defer arch.deinit();

    try testing.expectEqual(@as(usize, 5), arch.nodes.len);
    try testing.expectEqual(@as(bt.NodeId, 4), arch.root);

    switch (arch.nodes[2]) {
        .sequence => |children| {
            try testing.expectEqual(@as(usize, 2), children.len);
            try testing.expectEqual(@as(bt.NodeId, 0), children[0]);
            try testing.expectEqual(@as(bt.NodeId, 1), children[1]);
        },
        else => return error.WrongKind,
    }
    switch (arch.nodes[4]) {
        .selector => |children| try testing.expectEqual(@as(usize, 2), children.len),
        else => return error.WrongKind,
    }
}

test "load — parallel + cooldown + repeat with options" {
    const yaml =
        \\archetype: combined
        \\description: Exercises every node kind with options.
        \\perception_radius: 300
        \\root: 4
        \\nodes:
        \\  - id: 0
        \\    kind: action
        \\    leaf: aim
        \\  - id: 1
        \\    kind: action
        \\    leaf: fire
        \\  - id: 2
        \\    kind: cooldown
        \\    child: 1
        \\    cooldown_ms: 4000
        \\  - id: 3
        \\    kind: parallel
        \\    policy: any_success
        \\    children: [0, 2]
        \\  - id: 4
        \\    kind: repeat
        \\    child: 3
        \\    max_iter: 5
        \\
    ;
    var arch = try loadFromYaml(testing.allocator, yaml);
    defer arch.deinit();

    switch (arch.nodes[2]) {
        .cooldown => |cd| {
            try testing.expectEqual(@as(bt.NodeId, 1), cd.child);
            try testing.expectEqual(@as(u32, 4000), cd.cooldown_ms);
        },
        else => return error.WrongKind,
    }
    switch (arch.nodes[3]) {
        .parallel => |p| {
            try testing.expectEqual(bt.ParallelPolicy.any_success, p.policy);
            try testing.expectEqual(@as(usize, 2), p.children.len);
        },
        else => return error.WrongKind,
    }
    switch (arch.nodes[4]) {
        .repeat => |r| {
            try testing.expectEqual(@as(bt.NodeId, 3), r.child);
            try testing.expectEqual(@as(u32, 5), r.max_iter);
        },
        else => return error.WrongKind,
    }
}

test "load — comments and blank lines tolerated" {
    const yaml =
        \\# Top-of-file comment
        \\archetype: with_comments  # trailing comment ok
        \\description: Verifies comment + blank-line handling.
        \\
        \\perception_radius: 50
        \\root: 0
        \\nodes:
        \\  # comment between nodes
        \\  - id: 0
        \\    kind: action
        \\    leaf: x
        \\
    ;
    var arch = try loadFromYaml(testing.allocator, yaml);
    defer arch.deinit();
    try testing.expectEqualStrings("with_comments", arch.archetype);
    try testing.expectEqual(@as(usize, 1), arch.nodes.len);
}

test "load + instantiate + tick — end-to-end smoke" {
    const yaml =
        \\archetype: tick_smoke
        \\description: Sequence that always succeeds.
        \\perception_radius: 50
        \\root: 2
        \\nodes:
        \\  - id: 0
        \\    kind: cond
        \\    leaf: always_true
        \\  - id: 1
        \\    kind: action
        \\    leaf: noop
        \\  - id: 2
        \\    kind: sequence
        \\    children: [0, 1]
        \\
    ;
    var arch = try loadFromYaml(testing.allocator, yaml);
    defer arch.deinit();

    var tree = try instantiate(testing.allocator, &arch);
    defer tree.deinit(testing.allocator);

    const Mock = struct {
        const Self = @This();
        fn cond(_: *anyopaque, _: [:0]const u8) bool {
            return true;
        }
        fn action(_: *anyopaque, _: [:0]const u8) bt.Status {
            return .success;
        }
        fn dispatcher(self: *Self) bt.LeafDispatcher {
            return .{ .ptr = self, .vtable = &.{ .cond = cond, .action = action } };
        }
    };
    var mock: Mock = .{};
    var ctx: bt.TickCtx = .{ .now_ms = 0, .dispatcher = mock.dispatcher() };

    try testing.expectEqual(bt.Status.success, tree.tick(&ctx));
}

test "validation — duplicate id rejected" {
    const yaml =
        \\archetype: bad
        \\description: Duplicate id 0.
        \\perception_radius: 10
        \\root: 0
        \\nodes:
        \\  - id: 0
        \\    kind: action
        \\    leaf: a
        \\  - id: 0
        \\    kind: action
        \\    leaf: b
        \\
    ;
    try testing.expectError(error.DuplicateNodeId, loadFromYaml(testing.allocator, yaml));
}

test "validation — out-of-range node id rejected" {
    const yaml =
        \\archetype: bad
        \\description: id 5 with only 2 nodes total.
        \\perception_radius: 10
        \\root: 0
        \\nodes:
        \\  - id: 5
        \\    kind: action
        \\    leaf: a
        \\  - id: 1
        \\    kind: action
        \\    leaf: b
        \\
    ;
    try testing.expectError(error.NodeIdOutOfRange, loadFromYaml(testing.allocator, yaml));
}

test "validation — out-of-range root rejected" {
    const yaml =
        \\archetype: bad
        \\description: root references nonexistent node.
        \\perception_radius: 10
        \\root: 99
        \\nodes:
        \\  - id: 0
        \\    kind: action
        \\    leaf: a
        \\
    ;
    try testing.expectError(error.NodeIdOutOfRange, loadFromYaml(testing.allocator, yaml));
}

test "validation — unknown kind rejected" {
    const yaml =
        \\archetype: bad
        \\description: 'condition' is not a kind.
        \\perception_radius: 10
        \\root: 0
        \\nodes:
        \\  - id: 0
        \\    kind: condition
        \\    leaf: x
        \\
    ;
    try testing.expectError(error.UnknownNodeKind, loadFromYaml(testing.allocator, yaml));
}

test "validation — invalid child ref rejected" {
    const yaml =
        \\archetype: bad
        \\description: sequence references id 99.
        \\perception_radius: 10
        \\root: 1
        \\nodes:
        \\  - id: 0
        \\    kind: action
        \\    leaf: a
        \\  - id: 1
        \\    kind: sequence
        \\    children: [0, 99]
        \\
    ;
    try testing.expectError(error.InvalidChildRef, loadFromYaml(testing.allocator, yaml));
}

test "validation — unknown parallel policy rejected" {
    const yaml =
        \\archetype: bad
        \\description: 'majority' isn't a policy name.
        \\perception_radius: 10
        \\root: 2
        \\nodes:
        \\  - id: 0
        \\    kind: action
        \\    leaf: a
        \\  - id: 1
        \\    kind: action
        \\    leaf: b
        \\  - id: 2
        \\    kind: parallel
        \\    policy: majority
        \\    children: [0, 1]
        \\
    ;
    try testing.expectError(error.UnknownParallelPolicy, loadFromYaml(testing.allocator, yaml));
}

test "validation — cooldown without cooldown_ms rejected" {
    const yaml =
        \\archetype: bad
        \\description: cooldown node missing cooldown_ms.
        \\perception_radius: 10
        \\root: 1
        \\nodes:
        \\  - id: 0
        \\    kind: action
        \\    leaf: fire
        \\  - id: 1
        \\    kind: cooldown
        \\    child: 0
        \\
    ;
    try testing.expectError(error.MissingCooldownMs, loadFromYaml(testing.allocator, yaml));
}

test "validation — cond without leaf rejected" {
    const yaml =
        \\archetype: bad
        \\description: cond node missing leaf name.
        \\perception_radius: 10
        \\root: 0
        \\nodes:
        \\  - id: 0
        \\    kind: cond
        \\
    ;
    try testing.expectError(error.MissingLeafName, loadFromYaml(testing.allocator, yaml));
}

test "parse — unknown top-level key rejected" {
    const yaml =
        \\archetype: bad
        \\description: ok
        \\perception_radius: 10
        \\root: 0
        \\squanch: yes
        \\nodes:
        \\  - id: 0
        \\    kind: action
        \\    leaf: x
        \\
    ;
    try testing.expectError(error.UnknownKey, loadFromYaml(testing.allocator, yaml));
}

test "loadFromFile — pirate_sloop.yaml fixture" {
    var arch = try loadFromFile(testing.allocator, "data/ai/pirate_sloop.yaml");
    defer arch.deinit();

    try testing.expectEqualStrings("pirate_sloop", arch.archetype);
    try testing.expectEqual(@as(u32, 600), arch.perception_radius);
    try testing.expectEqual(@as(usize, 14), arch.nodes.len);
    try testing.expectEqual(@as(bt.NodeId, 12), arch.root);

    // Spot-check the engage branch's cooldown wraps the fire action.
    switch (arch.nodes[6]) {
        .cooldown => |cd| {
            try testing.expectEqual(@as(bt.NodeId, 5), cd.child);
            try testing.expectEqual(@as(u32, 4000), cd.cooldown_ms);
        },
        else => return error.WrongKind,
    }
    // Root selector has 4 branches: flee, engage, pursue, patrol.
    switch (arch.nodes[12]) {
        .selector => |children| try testing.expectEqual(@as(usize, 4), children.len),
        else => return error.WrongKind,
    }
}

test "parse — flow-array with whitespace variants" {
    const yaml =
        \\archetype: ws
        \\description: Whitespace variations in flow array.
        \\perception_radius: 10
        \\root: 1
        \\nodes:
        \\  - id: 0
        \\    kind: action
        \\    leaf: a
        \\  - id: 1
        \\    kind: sequence
        \\    children: [ 0 , 0 , 0 ]
        \\
    ;
    var arch = try loadFromYaml(testing.allocator, yaml);
    defer arch.deinit();
    switch (arch.nodes[1]) {
        .sequence => |children| try testing.expectEqual(@as(usize, 3), children.len),
        else => return error.WrongKind,
    }
}
