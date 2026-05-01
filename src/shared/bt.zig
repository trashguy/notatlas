//! Behavior Tree runtime — six node types, leaf dispatch via interface.
//!
//! Per docs/09-ai-sim.md §4. Composite traversal stays in Zig; leaves
//! cross into Lua via the `LeafDispatcher` interface, which the
//! ai-sim service implements with a Lua VM. Tests use a mock
//! dispatcher backed by a hashmap so this file stays VM-agnostic.
//!
//! Tree shape is immutable per archetype (built from YAML or
//! hand-coded for tests). Runtime state per AI lives in `Tree.state`,
//! a parallel slice indexed by node position. Cooldown / repeat
//! counters reset on tree reload — acceptable per docs/09 §9.

const std = @import("std");

pub const Status = enum {
    success,
    failure,
    running,
};

/// Identifier for a node within a Tree's flat `nodes` array. Children
/// reference parents/siblings by NodeId so trees serialize cleanly
/// and per-node state lives in a parallel array indexed the same way.
pub const NodeId = u16;
pub const invalid_node: NodeId = std.math.maxInt(NodeId);

/// Failure policy for `parallel`. v1 supports the two policies BT
/// literature names; add more if a tree actually needs them.
pub const ParallelPolicy = enum {
    /// `success` if all children `success`; `failure` if any child fails.
    all_success,
    /// `success` if any child `success`; `failure` only when all fail.
    any_success,
};

pub const Node = union(enum) {
    selector: []const NodeId,
    sequence: []const NodeId,
    parallel: Parallel,
    inverter: NodeId,
    cooldown: Cooldown,
    repeat: Repeat,
    cond: Leaf,
    action: Leaf,

    pub const Parallel = struct {
        children: []const NodeId,
        policy: ParallelPolicy,
    };

    pub const Cooldown = struct {
        child: NodeId,
        cooldown_ms: u32,
    };

    pub const Repeat = struct {
        child: NodeId,
        max_iter: u32, // 0 = repeat forever (until child fails)
    };

    pub const Leaf = struct {
        /// Function name to dispatch through the LeafDispatcher.
        name: [:0]const u8,
    };
};

/// Per-node mutable runtime state. Lives in `Tree.state`, parallel
/// to `nodes`. Most node kinds need nothing here; cooldown and repeat
/// are the only stateful kinds in v1.
pub const NodeState = union(enum) {
    none,
    cooldown: struct { last_success_ms: ?i64 = null },
    repeat: struct { iter: u32 = 0 },
};

/// One AI's BT instance. The `nodes` slice is shared across all AIs of
/// the same archetype (immutable tree shape); each AI owns its own
/// `state` slice. `root` is the entry point.
pub const Tree = struct {
    nodes: []const Node,
    state: []NodeState,
    root: NodeId,

    pub fn deinit(self: *Tree, alloc: std.mem.Allocator) void {
        alloc.free(self.state);
        self.* = undefined;
    }

    /// Run one tick from the root. Returns the root's Status.
    pub fn tick(self: *Tree, ctx: *TickCtx) Status {
        return tickNode(self, ctx, self.root);
    }
};

/// Inputs threaded through one tick of the tree. Caller owns the
/// dispatcher; `now_ms` is the same monotonic clock the cooldown
/// nodes compare against.
pub const TickCtx = struct {
    now_ms: i64,
    dispatcher: LeafDispatcher,
};

/// Erased interface for invoking cond/action leaves. ai-sim's
/// production impl is backed by a Lua VM (see lua_bind.zig); tests
/// here use a hashmap-backed mock.
pub const LeafDispatcher = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        cond: *const fn (ctx: *anyopaque, name: [:0]const u8) bool,
        action: *const fn (ctx: *anyopaque, name: [:0]const u8) Status,
    };

    pub fn cond(self: LeafDispatcher, name: [:0]const u8) bool {
        return self.vtable.cond(self.ptr, name);
    }

    pub fn action(self: LeafDispatcher, name: [:0]const u8) Status {
        return self.vtable.action(self.ptr, name);
    }
};

// ----- traversal -----

fn tickNode(tree: *Tree, ctx: *TickCtx, id: NodeId) Status {
    return switch (tree.nodes[id]) {
        .selector => |children| tickSelector(tree, ctx, children),
        .sequence => |children| tickSequence(tree, ctx, children),
        .parallel => |p| tickParallel(tree, ctx, p),
        .inverter => |child| tickInverter(tree, ctx, child),
        .cooldown => |cd| tickCooldown(tree, ctx, id, cd),
        .repeat => |r| tickRepeat(tree, ctx, id, r),
        .cond => |leaf| if (ctx.dispatcher.cond(leaf.name)) .success else .failure,
        .action => |leaf| ctx.dispatcher.action(leaf.name),
    };
}

fn tickSelector(tree: *Tree, ctx: *TickCtx, children: []const NodeId) Status {
    for (children) |child_id| {
        const s = tickNode(tree, ctx, child_id);
        switch (s) {
            .success, .running => return s,
            .failure => continue,
        }
    }
    return .failure;
}

fn tickSequence(tree: *Tree, ctx: *TickCtx, children: []const NodeId) Status {
    for (children) |child_id| {
        const s = tickNode(tree, ctx, child_id);
        switch (s) {
            .failure, .running => return s,
            .success => continue,
        }
    }
    return .success;
}

fn tickParallel(tree: *Tree, ctx: *TickCtx, p: Node.Parallel) Status {
    var n_success: usize = 0;
    var n_failure: usize = 0;
    var n_running: usize = 0;
    for (p.children) |child_id| {
        switch (tickNode(tree, ctx, child_id)) {
            .success => n_success += 1,
            .failure => n_failure += 1,
            .running => n_running += 1,
        }
    }
    return switch (p.policy) {
        .all_success => if (n_failure > 0)
            .failure
        else if (n_running > 0)
            .running
        else
            .success,
        .any_success => if (n_success > 0)
            .success
        else if (n_running > 0)
            .running
        else
            .failure,
    };
}

fn tickInverter(tree: *Tree, ctx: *TickCtx, child_id: NodeId) Status {
    return switch (tickNode(tree, ctx, child_id)) {
        .success => .failure,
        .failure => .success,
        .running => .running,
    };
}

fn tickCooldown(tree: *Tree, ctx: *TickCtx, id: NodeId, cd: Node.Cooldown) Status {
    const state = &tree.state[id].cooldown;
    if (state.last_success_ms) |last| {
        if (ctx.now_ms - last < @as(i64, @intCast(cd.cooldown_ms))) {
            return .failure;
        }
    }
    const s = tickNode(tree, ctx, cd.child);
    if (s == .success) state.last_success_ms = ctx.now_ms;
    return s;
}

fn tickRepeat(tree: *Tree, ctx: *TickCtx, id: NodeId, r: Node.Repeat) Status {
    const state = &tree.state[id].repeat;
    while (true) {
        const s = tickNode(tree, ctx, r.child);
        switch (s) {
            .running => return .running,
            .failure => {
                state.iter = 0;
                return .failure;
            },
            .success => {
                state.iter += 1;
                if (r.max_iter != 0 and state.iter >= r.max_iter) {
                    state.iter = 0;
                    return .success;
                }
                // 0 = repeat forever, fall through to next iter
            },
        }
    }
}

// ----- builder helpers (used by tests until the YAML loader lands) -----

/// Build a Tree from a flat `nodes` slice. Allocates a parallel
/// `state` slice initialized per node kind (cooldown / repeat get
/// fresh state; everything else is `.none`).
pub fn build(alloc: std.mem.Allocator, nodes: []const Node, root: NodeId) !Tree {
    const state = try alloc.alloc(NodeState, nodes.len);
    for (nodes, 0..) |n, i| {
        state[i] = switch (n) {
            .cooldown => .{ .cooldown = .{} },
            .repeat => .{ .repeat = .{} },
            else => .none,
        };
    }
    return .{ .nodes = nodes, .state = state, .root = root };
}

// ----- tests -----

const testing = std.testing;

const MockDispatcher = struct {
    cond_results: std.StringHashMap(bool),
    action_results: std.StringHashMap(Status),
    cond_calls: usize = 0,
    action_calls: usize = 0,

    fn init(alloc: std.mem.Allocator) MockDispatcher {
        return .{
            .cond_results = .init(alloc),
            .action_results = .init(alloc),
        };
    }

    fn deinit(self: *MockDispatcher) void {
        self.cond_results.deinit();
        self.action_results.deinit();
    }

    fn dispatcher(self: *MockDispatcher) LeafDispatcher {
        const V = struct {
            fn cond(ctx: *anyopaque, name: [:0]const u8) bool {
                const m: *MockDispatcher = @ptrCast(@alignCast(ctx));
                m.cond_calls += 1;
                return m.cond_results.get(std.mem.span(name.ptr)) orelse false;
            }
            fn action(ctx: *anyopaque, name: [:0]const u8) Status {
                const m: *MockDispatcher = @ptrCast(@alignCast(ctx));
                m.action_calls += 1;
                return m.action_results.get(std.mem.span(name.ptr)) orelse .failure;
            }
        };
        return .{
            .ptr = self,
            .vtable = &.{ .cond = V.cond, .action = V.action },
        };
    }
};

test "single action leaf returns its status" {
    var mock = MockDispatcher.init(testing.allocator);
    defer mock.deinit();
    try mock.action_results.put("act", .success);

    const nodes = [_]Node{.{ .action = .{ .name = "act" } }};
    var tree = try build(testing.allocator, &nodes, 0);
    defer tree.deinit(testing.allocator);

    var ctx: TickCtx = .{ .now_ms = 0, .dispatcher = mock.dispatcher() };
    try testing.expectEqual(Status.success, tree.tick(&ctx));
    try testing.expectEqual(@as(usize, 1), mock.action_calls);
}

test "selector picks first non-failure child" {
    var mock = MockDispatcher.init(testing.allocator);
    defer mock.deinit();
    try mock.action_results.put("a", .failure);
    try mock.action_results.put("b", .success);
    try mock.action_results.put("c", .failure);

    const nodes = [_]Node{
        .{ .action = .{ .name = "a" } }, // 0
        .{ .action = .{ .name = "b" } }, // 1
        .{ .action = .{ .name = "c" } }, // 2
        .{ .selector = &.{ 0, 1, 2 } }, // 3 (root)
    };
    var tree = try build(testing.allocator, &nodes, 3);
    defer tree.deinit(testing.allocator);

    var ctx: TickCtx = .{ .now_ms = 0, .dispatcher = mock.dispatcher() };
    try testing.expectEqual(Status.success, tree.tick(&ctx));
    // Selector should NOT have called "c" — it stopped at "b"'s success.
    try testing.expectEqual(@as(usize, 2), mock.action_calls);
}

test "selector returns failure if all children fail" {
    var mock = MockDispatcher.init(testing.allocator);
    defer mock.deinit();
    try mock.action_results.put("a", .failure);
    try mock.action_results.put("b", .failure);

    const nodes = [_]Node{
        .{ .action = .{ .name = "a" } },
        .{ .action = .{ .name = "b" } },
        .{ .selector = &.{ 0, 1 } },
    };
    var tree = try build(testing.allocator, &nodes, 2);
    defer tree.deinit(testing.allocator);

    var ctx: TickCtx = .{ .now_ms = 0, .dispatcher = mock.dispatcher() };
    try testing.expectEqual(Status.failure, tree.tick(&ctx));
}

test "sequence stops at first failure" {
    var mock = MockDispatcher.init(testing.allocator);
    defer mock.deinit();
    try mock.action_results.put("a", .success);
    try mock.action_results.put("b", .failure);
    try mock.action_results.put("c", .success);

    const nodes = [_]Node{
        .{ .action = .{ .name = "a" } },
        .{ .action = .{ .name = "b" } },
        .{ .action = .{ .name = "c" } },
        .{ .sequence = &.{ 0, 1, 2 } },
    };
    var tree = try build(testing.allocator, &nodes, 3);
    defer tree.deinit(testing.allocator);

    var ctx: TickCtx = .{ .now_ms = 0, .dispatcher = mock.dispatcher() };
    try testing.expectEqual(Status.failure, tree.tick(&ctx));
    try testing.expectEqual(@as(usize, 2), mock.action_calls);
}

test "sequence returns success only when all succeed" {
    var mock = MockDispatcher.init(testing.allocator);
    defer mock.deinit();
    try mock.action_results.put("a", .success);
    try mock.action_results.put("b", .success);

    const nodes = [_]Node{
        .{ .action = .{ .name = "a" } },
        .{ .action = .{ .name = "b" } },
        .{ .sequence = &.{ 0, 1 } },
    };
    var tree = try build(testing.allocator, &nodes, 2);
    defer tree.deinit(testing.allocator);

    var ctx: TickCtx = .{ .now_ms = 0, .dispatcher = mock.dispatcher() };
    try testing.expectEqual(Status.success, tree.tick(&ctx));
}

test "running short-circuits both selector and sequence" {
    var mock = MockDispatcher.init(testing.allocator);
    defer mock.deinit();
    try mock.action_results.put("a", .running);

    {
        const nodes = [_]Node{
            .{ .action = .{ .name = "a" } },
            .{ .action = .{ .name = "b" } },
            .{ .selector = &.{ 0, 1 } },
        };
        var tree = try build(testing.allocator, &nodes, 2);
        defer tree.deinit(testing.allocator);
        var ctx: TickCtx = .{ .now_ms = 0, .dispatcher = mock.dispatcher() };
        try testing.expectEqual(Status.running, tree.tick(&ctx));
    }
    {
        const nodes = [_]Node{
            .{ .action = .{ .name = "a" } },
            .{ .action = .{ .name = "b" } },
            .{ .sequence = &.{ 0, 1 } },
        };
        var tree = try build(testing.allocator, &nodes, 2);
        defer tree.deinit(testing.allocator);
        var ctx: TickCtx = .{ .now_ms = 0, .dispatcher = mock.dispatcher() };
        try testing.expectEqual(Status.running, tree.tick(&ctx));
    }
}

test "cond gates a sequence" {
    var mock = MockDispatcher.init(testing.allocator);
    defer mock.deinit();
    try mock.cond_results.put("low_hp", true);
    try mock.action_results.put("flee", .running);

    const nodes = [_]Node{
        .{ .cond = .{ .name = "low_hp" } },
        .{ .action = .{ .name = "flee" } },
        .{ .sequence = &.{ 0, 1 } },
    };
    var tree = try build(testing.allocator, &nodes, 2);
    defer tree.deinit(testing.allocator);

    var ctx: TickCtx = .{ .now_ms = 0, .dispatcher = mock.dispatcher() };
    try testing.expectEqual(Status.running, tree.tick(&ctx));

    // Flip the cond — now flee shouldn't even run.
    try mock.cond_results.put("low_hp", false);
    mock.action_calls = 0;
    try testing.expectEqual(Status.failure, tree.tick(&ctx));
    try testing.expectEqual(@as(usize, 0), mock.action_calls);
}

test "inverter flips success and failure but passes running" {
    var mock = MockDispatcher.init(testing.allocator);
    defer mock.deinit();
    try mock.action_results.put("a", .success);

    const nodes = [_]Node{
        .{ .action = .{ .name = "a" } },
        .{ .inverter = 0 },
    };
    var tree = try build(testing.allocator, &nodes, 1);
    defer tree.deinit(testing.allocator);

    var ctx: TickCtx = .{ .now_ms = 0, .dispatcher = mock.dispatcher() };
    try testing.expectEqual(Status.failure, tree.tick(&ctx));

    try mock.action_results.put("a", .failure);
    try testing.expectEqual(Status.success, tree.tick(&ctx));

    try mock.action_results.put("a", .running);
    try testing.expectEqual(Status.running, tree.tick(&ctx));
}

test "cooldown blocks for the configured window after success" {
    var mock = MockDispatcher.init(testing.allocator);
    defer mock.deinit();
    try mock.action_results.put("fire", .success);

    const nodes = [_]Node{
        .{ .action = .{ .name = "fire" } },
        .{ .cooldown = .{ .child = 0, .cooldown_ms = 4000 } },
    };
    var tree = try build(testing.allocator, &nodes, 1);
    defer tree.deinit(testing.allocator);

    var ctx: TickCtx = .{ .now_ms = 0, .dispatcher = mock.dispatcher() };
    // First fire: cooldown not yet started, fire returns success.
    try testing.expectEqual(Status.success, tree.tick(&ctx));

    // Within the cooldown window: blocked, returns failure, child not called.
    ctx.now_ms = 1000;
    const before = mock.action_calls;
    try testing.expectEqual(Status.failure, tree.tick(&ctx));
    try testing.expectEqual(before, mock.action_calls);

    // Just past the window: fires again.
    ctx.now_ms = 4001;
    try testing.expectEqual(Status.success, tree.tick(&ctx));
}

test "repeat — runs child max_iter times" {
    var mock = MockDispatcher.init(testing.allocator);
    defer mock.deinit();
    try mock.action_results.put("a", .success);

    const nodes = [_]Node{
        .{ .action = .{ .name = "a" } },
        .{ .repeat = .{ .child = 0, .max_iter = 3 } },
    };
    var tree = try build(testing.allocator, &nodes, 1);
    defer tree.deinit(testing.allocator);

    var ctx: TickCtx = .{ .now_ms = 0, .dispatcher = mock.dispatcher() };
    try testing.expectEqual(Status.success, tree.tick(&ctx));
    try testing.expectEqual(@as(usize, 3), mock.action_calls);
}

test "repeat — child failure ends loop and returns failure" {
    var mock = MockDispatcher.init(testing.allocator);
    defer mock.deinit();
    try mock.action_results.put("a", .failure);

    const nodes = [_]Node{
        .{ .action = .{ .name = "a" } },
        .{ .repeat = .{ .child = 0, .max_iter = 5 } },
    };
    var tree = try build(testing.allocator, &nodes, 1);
    defer tree.deinit(testing.allocator);

    var ctx: TickCtx = .{ .now_ms = 0, .dispatcher = mock.dispatcher() };
    try testing.expectEqual(Status.failure, tree.tick(&ctx));
    try testing.expectEqual(@as(usize, 1), mock.action_calls);
}

test "parallel — all_success policy" {
    var mock = MockDispatcher.init(testing.allocator);
    defer mock.deinit();
    try mock.action_results.put("a", .success);
    try mock.action_results.put("b", .success);
    try mock.action_results.put("c", .running);

    const nodes = [_]Node{
        .{ .action = .{ .name = "a" } },
        .{ .action = .{ .name = "b" } },
        .{ .action = .{ .name = "c" } },
        .{ .parallel = .{ .children = &.{ 0, 1, 2 }, .policy = .all_success } },
    };
    var tree = try build(testing.allocator, &nodes, 3);
    defer tree.deinit(testing.allocator);

    var ctx: TickCtx = .{ .now_ms = 0, .dispatcher = mock.dispatcher() };
    // Two success, one running -> all_success returns running (waiting on c).
    try testing.expectEqual(Status.running, tree.tick(&ctx));

    try mock.action_results.put("c", .success);
    try testing.expectEqual(Status.success, tree.tick(&ctx));

    try mock.action_results.put("c", .failure);
    try testing.expectEqual(Status.failure, tree.tick(&ctx));
}

test "parallel — any_success policy" {
    var mock = MockDispatcher.init(testing.allocator);
    defer mock.deinit();
    try mock.action_results.put("a", .failure);
    try mock.action_results.put("b", .success);

    const nodes = [_]Node{
        .{ .action = .{ .name = "a" } },
        .{ .action = .{ .name = "b" } },
        .{ .parallel = .{ .children = &.{ 0, 1 }, .policy = .any_success } },
    };
    var tree = try build(testing.allocator, &nodes, 2);
    defer tree.deinit(testing.allocator);

    var ctx: TickCtx = .{ .now_ms = 0, .dispatcher = mock.dispatcher() };
    try testing.expectEqual(Status.success, tree.tick(&ctx));
}

test "pirate-sloop-shape tree — full integration" {
    // The example tree from docs/09-ai-sim.md §5, condensed.
    var mock = MockDispatcher.init(testing.allocator);
    defer mock.deinit();
    try mock.cond_results.put("low_hp", false);
    try mock.cond_results.put("enemy_in_range", true);
    try mock.action_results.put("flee_to_open_water", .running);
    try mock.action_results.put("aim_broadside", .running);
    try mock.action_results.put("fire_broadside", .success);
    try mock.action_results.put("intercept", .running);
    try mock.action_results.put("patrol_waypoints", .running);

    const nodes = [_]Node{
        // Flee branch: cond + action
        .{ .cond = .{ .name = "low_hp" } }, // 0
        .{ .action = .{ .name = "flee_to_open_water" } }, // 1
        .{ .sequence = &.{ 0, 1 } }, // 2

        // Combat branch: cond + parallel(aim, cooldown(fire))
        .{ .cond = .{ .name = "enemy_in_range" } }, // 3
        .{ .action = .{ .name = "aim_broadside" } }, // 4
        .{ .action = .{ .name = "fire_broadside" } }, // 5
        .{ .cooldown = .{ .child = 5, .cooldown_ms = 4000 } }, // 6
        .{ .parallel = .{ .children = &.{ 4, 6 }, .policy = .any_success } }, // 7
        .{ .sequence = &.{ 3, 7 } }, // 8

        // Patrol fallback
        .{ .action = .{ .name = "patrol_waypoints" } }, // 9

        // Root selector
        .{ .selector = &.{ 2, 8, 9 } }, // 10
    };
    var tree = try build(testing.allocator, &nodes, 10);
    defer tree.deinit(testing.allocator);

    var ctx: TickCtx = .{ .now_ms = 0, .dispatcher = mock.dispatcher() };

    // hp ok, enemy in range: combat branch wins, fire returns success
    // -> parallel returns success -> sequence success.
    try testing.expectEqual(Status.success, tree.tick(&ctx));

    // Within cooldown window now; second tick should still hit aim
    // (running) but fire_broadside is gated. parallel policy is
    // any_success: aim is running, cooldown returns failure -> running.
    ctx.now_ms = 100;
    try testing.expectEqual(Status.running, tree.tick(&ctx));

    // Drop hp below threshold: flee branch takes priority.
    try mock.cond_results.put("low_hp", true);
    try testing.expectEqual(Status.running, tree.tick(&ctx));
}
