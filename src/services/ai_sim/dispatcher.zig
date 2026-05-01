//! Lua-backed `bt.LeafDispatcher` for ai-sim.
//!
//! Each cohort owns one Lua VM (per docs/09 §13 q3). Per AI per tick:
//!
//!   1. main calls `disp.beginAi(ai, &ctx)` — pushes `ctx` as a Lua
//!      global, latches the current AI for set_input helpers.
//!   2. `tree.tick(&bt_ctx)` — leaves run as Lua globals. Conds return
//!      bool; actions return the @tagName Status string. Action leaves
//!      may call the registered helpers below to mutate the AI's
//!      pending_input.
//!   3. main calls `disp.endAi()` — clears the latch + ctx global.
//!
//! Registered Lua helpers (set up once at `LuaDispatcher.init`):
//!
//!   set_thrust(x)   — clamp [-1,1], write into pending_input.thrust
//!   set_steer(x)    — clamp [-1,1], write into pending_input.steer
//!   set_fire(b)     — boolean trigger for the cannon latch
//!
//! Helpers retrieve `*LuaDispatcher` via a lightuserdata stash in
//! the Lua registry (`registry_key`). One global write at init,
//! O(1) lookup per call. Single-threaded VM so the latch is safe.
//!
//! Missing globals + Lua runtime errors fail closed (cond→false,
//! action→failure). A typo'd leaf name falls through to a sibling
//! branch instead of crashing the cohort.

const std = @import("std");
const lua = @import("lua");
const notatlas = @import("notatlas");
const bt = notatlas.bt;

const ai_state = @import("state.zig");
const perception = @import("perception.zig");

/// Registry key under which `*LuaDispatcher` is stashed as a
/// lightuserdata. Read by the registered set_input helpers each call.
const registry_key: [*:0]const u8 = "_notatlas_ai_dispatcher";

pub const LuaDispatcher = struct {
    vm: *lua.Vm,
    /// Currently-ticking AI, latched by `beginAi` and cleared by
    /// `endAi`. The set_input helpers mutate `current_ai.?.pending_input`.
    /// Single-threaded (one VM = one cohort = one ticking AI at a time).
    current_ai: ?*ai_state.AiShip = null,

    pub fn init(vm: *lua.Vm) LuaDispatcher {
        var d: LuaDispatcher = .{ .vm = vm };
        // Stash *LuaDispatcher in the registry so the registered C
        // fns can find their target without closure capture.
        // NOTE: stores the stack address of `d`, which is fine here
        // because main copies the returned value into a stable slot
        // and re-stashes (see `restash`). Tests that stack-init the
        // dispatcher and never move it are also fine.
        d.stash();
        d.registerInputHelpers();
        return d;
    }

    /// Re-stash `*self` in the Lua registry. Call after the dispatcher
    /// has been moved (e.g., copied into a long-lived slot in main).
    /// init()'s stash points at the in-flight stack address; once main
    /// has the value somewhere stable, call this so the registered
    /// helpers see the right pointer.
    pub fn restash(self: *LuaDispatcher) void {
        self.stash();
    }

    fn stash(self: *LuaDispatcher) void {
        lua.c.pushlightuserdata(self.vm.L, @ptrCast(self));
        lua.c.setfield(self.vm.L, lua.c.REGISTRYINDEX, registry_key);
    }

    fn registerInputHelpers(self: *LuaDispatcher) void {
        lua.c.pushcfunction(self.vm.L, setThrustC);
        lua.c.setglobal(self.vm.L, "set_thrust");
        lua.c.pushcfunction(self.vm.L, setSteerC);
        lua.c.setglobal(self.vm.L, "set_steer");
        lua.c.pushcfunction(self.vm.L, setFireC);
        lua.c.setglobal(self.vm.L, "set_fire");
    }

    /// Latch `ai` as the target of the upcoming tree.tick + push the
    /// perception ctx as a Lua global named `ctx`. Pair with `endAi()`.
    pub fn beginAi(self: *LuaDispatcher, ai: *ai_state.AiShip, ctx: *const perception.PerceptionCtx) void {
        self.current_ai = ai;
        lua.bind.pushValue(self.vm.L, perception.PerceptionCtx, ctx.*);
        lua.c.setglobal(self.vm.L, "ctx");
    }

    pub fn endAi(self: *LuaDispatcher) void {
        self.current_ai = null;
        lua.c.pushnil(self.vm.L);
        lua.c.setglobal(self.vm.L, "ctx");
    }

    pub fn dispatcher(self: *LuaDispatcher) bt.LeafDispatcher {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    const vtable: bt.LeafDispatcher.VTable = .{
        .cond = &condThunk,
        .action = &actionThunk,
    };

    fn condThunk(ptr: *anyopaque, name: [:0]const u8) bool {
        const self: *LuaDispatcher = @ptrCast(@alignCast(ptr));
        return callForBool(self.vm, name);
    }

    fn actionThunk(ptr: *anyopaque, name: [:0]const u8) bt.Status {
        const self: *LuaDispatcher = @ptrCast(@alignCast(ptr));
        return callForStatus(self.vm, name);
    }
};

// ----- registered Lua helpers (C-callable) -----

fn fetchDispatcher(L: *lua.c.State) ?*LuaDispatcher {
    _ = lua.c.getfield(L, lua.c.REGISTRYINDEX, registry_key);
    const ptr = lua.c.touserdata(L, -1);
    lua.c.pop(L, 1);
    return @ptrCast(@alignCast(ptr));
}

fn ensurePending(ai: *ai_state.AiShip) *@TypeOf(ai.pending_input.?) {
    if (ai.pending_input == null) ai.pending_input = .{};
    return &ai.pending_input.?;
}

fn clamp1(v: f64) f32 {
    if (v < -1.0) return -1.0;
    if (v > 1.0) return 1.0;
    return @floatCast(v);
}

fn setThrustC(L_opt: ?*lua.c.State) callconv(.c) c_int {
    const L = L_opt.?;
    const disp = fetchDispatcher(L) orelse return 0;
    const ai = disp.current_ai orelse return 0;
    const v = lua.c.luaL_checknumber(L, 1);
    ensurePending(ai).thrust = clamp1(v);
    return 0;
}

fn setSteerC(L_opt: ?*lua.c.State) callconv(.c) c_int {
    const L = L_opt.?;
    const disp = fetchDispatcher(L) orelse return 0;
    const ai = disp.current_ai orelse return 0;
    const v = lua.c.luaL_checknumber(L, 1);
    ensurePending(ai).steer = clamp1(v);
    return 0;
}

fn setFireC(L_opt: ?*lua.c.State) callconv(.c) c_int {
    const L = L_opt.?;
    const disp = fetchDispatcher(L) orelse return 0;
    const ai = disp.current_ai orelse return 0;
    const b = lua.c.toboolean(L, 1) != 0;
    ensurePending(ai).fire = b;
    return 0;
}

// ----- BT leaf call path -----

fn callForBool(vm: *lua.Vm, name: [:0]const u8) bool {
    const L = vm.L;
    const t = lua.c.getglobal(L, name.ptr);
    if (t != lua.c.TFUNCTION) {
        std.log.debug("ai-sim: cond leaf '{s}' is not a function (type={d})", .{ name, t });
        lua.c.pop(L, 1);
        return false;
    }
    const rc = lua.c.pcall(L, 0, 1, 0);
    if (rc != lua.c.OK) {
        if (lua.c.tostring(L, -1)) |s| {
            std.log.warn("ai-sim: cond '{s}' lua error: {s}", .{ name, std.mem.span(s) });
        }
        lua.c.pop(L, 1);
        return false;
    }
    const b = lua.c.toboolean(L, -1) != 0;
    lua.c.pop(L, 1);
    return b;
}

fn callForStatus(vm: *lua.Vm, name: [:0]const u8) bt.Status {
    const L = vm.L;
    const t = lua.c.getglobal(L, name.ptr);
    if (t != lua.c.TFUNCTION) {
        std.log.debug("ai-sim: action leaf '{s}' is not a function (type={d})", .{ name, t });
        lua.c.pop(L, 1);
        return .failure;
    }
    const rc = lua.c.pcall(L, 0, 1, 0);
    if (rc != lua.c.OK) {
        if (lua.c.tostring(L, -1)) |s| {
            std.log.warn("ai-sim: action '{s}' lua error: {s}", .{ name, std.mem.span(s) });
        }
        lua.c.pop(L, 1);
        return .failure;
    }
    const cstr = lua.c.tostring(L, -1) orelse {
        lua.c.pop(L, 1);
        return .failure;
    };
    const tag = std.mem.span(cstr);
    lua.c.pop(L, 1);
    return std.meta.stringToEnum(bt.Status, tag) orelse .failure;
}

// ----- tests -----
//
// Tests use a real Lua VM + the bt module's public surface to exercise
// the dispatcher end-to-end (no mocks). Same pattern as bt.zig's own
// integration tests, with Lua replacing the MockDispatcher.

const testing = std.testing;
const wire = @import("wire");

test "dispatcher: missing leaf cond fails closed" {
    var vm = try lua.Vm.init();
    defer vm.deinit();

    var d = LuaDispatcher.init(&vm);
    d.restash();
    const dispatcher = d.dispatcher();
    try testing.expectEqual(false, dispatcher.cond("does_not_exist"));
}

test "dispatcher: missing leaf action fails closed" {
    var vm = try lua.Vm.init();
    defer vm.deinit();

    var d = LuaDispatcher.init(&vm);
    d.restash();
    const dispatcher = d.dispatcher();
    try testing.expectEqual(bt.Status.failure, dispatcher.action("does_not_exist"));
}

test "dispatcher: cond true / false round-trip" {
    var vm = try lua.Vm.init();
    defer vm.deinit();

    try vm.doString(
        \\function yes() return true end
        \\function no()  return false end
    );

    var d = LuaDispatcher.init(&vm);
    d.restash();
    const dispatcher = d.dispatcher();
    try testing.expectEqual(true, dispatcher.cond("yes"));
    try testing.expectEqual(false, dispatcher.cond("no"));
}

test "dispatcher: action returns Status by tag string" {
    var vm = try lua.Vm.init();
    defer vm.deinit();

    try vm.doString(
        \\function done() return "success" end
        \\function busy() return "running" end
        \\function nope() return "failure" end
        \\function bad()  return "garbage" end
    );

    var d = LuaDispatcher.init(&vm);
    d.restash();
    const dispatcher = d.dispatcher();
    try testing.expectEqual(bt.Status.success, dispatcher.action("done"));
    try testing.expectEqual(bt.Status.running, dispatcher.action("busy"));
    try testing.expectEqual(bt.Status.failure, dispatcher.action("nope"));
    try testing.expectEqual(bt.Status.failure, dispatcher.action("bad"));
}

test "dispatcher: lua runtime error treated as failure" {
    var vm = try lua.Vm.init();
    defer vm.deinit();

    try vm.doString("function explode() error('boom') end");

    var d = LuaDispatcher.init(&vm);
    d.restash();
    const dispatcher = d.dispatcher();
    try testing.expectEqual(bt.Status.failure, dispatcher.action("explode"));
    try testing.expectEqual(false, dispatcher.cond("explode"));
}

test "dispatcher: drives a real bt tree" {
    var vm = try lua.Vm.init();
    defer vm.deinit();
    try vm.doString(
        \\function ready() return true end
        \\function go()    return "success" end
    );

    var d = LuaDispatcher.init(&vm);
    d.restash();

    // sequence(cond ready, action go) — runs cond then action.
    const nodes = try testing.allocator.alloc(bt.Node, 3);
    defer testing.allocator.free(nodes);
    nodes[0] = .{ .cond = .{ .name = "ready" } };
    nodes[1] = .{ .action = .{ .name = "go" } };
    nodes[2] = .{ .sequence = &.{ 0, 1 } };

    var tree = try bt.build(testing.allocator, nodes, 2);
    defer tree.deinit(testing.allocator);

    var ctx: bt.TickCtx = .{ .now_ms = 0, .dispatcher = d.dispatcher() };
    try testing.expectEqual(bt.Status.success, tree.tick(&ctx));
}

test "dispatcher: set_thrust mutates current_ai pending_input" {
    var vm = try lua.Vm.init();
    defer vm.deinit();

    try vm.doString("function go() set_thrust(0.7) return \"success\" end");

    var d = LuaDispatcher.init(&vm);
    d.restash();

    var ai: ai_state.AiShip = .{
        .id = 0x01000003,
        .tree = undefined, // unused for this test
    };

    // Synthetic ctx — beginAi will push it; values are irrelevant for
    // this test (the leaf only calls set_thrust).
    const ctx: perception.PerceptionCtx = .{
        .tick = 0,
        .dt = 0.05,
        .own_pose = .{ .x = 0, .y = 0, .z = 0, .qx = 0, .qy = 0, .qz = 0, .qw = 1 },
        .own_vel = .{ .lin = .{ .x = 0, .y = 0, .z = 0 }, .ang = .{ .x = 0, .y = 0, .z = 0 } },
        .own_hp = 1.0,
        .wind = .{ .dir = 0, .speed = 0 },
        .cell = .{ .x = 0, .y = 0 },
        .nearest_enemy = null,
    };

    d.beginAi(&ai, &ctx);
    defer d.endAi();

    const dispatcher = d.dispatcher();
    try testing.expectEqual(bt.Status.success, dispatcher.action("go"));
    try testing.expect(ai.pending_input != null);
    try testing.expectApproxEqAbs(@as(f32, 0.7), ai.pending_input.?.thrust, 1e-6);
}

test "dispatcher: set_thrust clamps to [-1, 1]" {
    var vm = try lua.Vm.init();
    defer vm.deinit();

    try vm.doString(
        \\function over()  set_thrust(2.5)  return "success" end
        \\function under() set_thrust(-2.5) return "success" end
    );

    var d = LuaDispatcher.init(&vm);
    d.restash();

    var ai: ai_state.AiShip = .{ .id = 0x01000003, .tree = undefined };
    const ctx: perception.PerceptionCtx = .{
        .tick = 0,
        .dt = 0.05,
        .own_pose = .{ .x = 0, .y = 0, .z = 0, .qx = 0, .qy = 0, .qz = 0, .qw = 1 },
        .own_vel = .{ .lin = .{ .x = 0, .y = 0, .z = 0 }, .ang = .{ .x = 0, .y = 0, .z = 0 } },
        .own_hp = 1.0,
        .wind = .{ .dir = 0, .speed = 0 },
        .cell = .{ .x = 0, .y = 0 },
        .nearest_enemy = null,
    };

    d.beginAi(&ai, &ctx);
    defer d.endAi();
    const dispatcher = d.dispatcher();

    _ = dispatcher.action("over");
    try testing.expectApproxEqAbs(@as(f32, 1.0), ai.pending_input.?.thrust, 1e-6);
    _ = dispatcher.action("under");
    try testing.expectApproxEqAbs(@as(f32, -1.0), ai.pending_input.?.thrust, 1e-6);
}

test "dispatcher: leaf reads ctx.own_pose from pushed global" {
    var vm = try lua.Vm.init();
    defer vm.deinit();

    try vm.doString(
        \\function read_x()
        \\  set_thrust(ctx.own_pose.x)
        \\  return "success"
        \\end
    );

    var d = LuaDispatcher.init(&vm);
    d.restash();

    var ai: ai_state.AiShip = .{ .id = 0x01000003, .tree = undefined };
    const ctx: perception.PerceptionCtx = .{
        .tick = 0,
        .dt = 0.05,
        .own_pose = .{ .x = 0.5, .y = 0, .z = 0, .qx = 0, .qy = 0, .qz = 0, .qw = 1 },
        .own_vel = .{ .lin = .{ .x = 0, .y = 0, .z = 0 }, .ang = .{ .x = 0, .y = 0, .z = 0 } },
        .own_hp = 1.0,
        .wind = .{ .dir = 0, .speed = 0 },
        .cell = .{ .x = 0, .y = 0 },
        .nearest_enemy = null,
    };

    d.beginAi(&ai, &ctx);
    defer d.endAi();
    const dispatcher = d.dispatcher();
    _ = dispatcher.action("read_x");
    try testing.expectApproxEqAbs(@as(f32, 0.5), ai.pending_input.?.thrust, 1e-6);
}

test "dispatcher: nearest_enemy nil reads as nil in lua" {
    var vm = try lua.Vm.init();
    defer vm.deinit();

    try vm.doString(
        \\function has_enemy() return ctx.nearest_enemy ~= nil end
    );

    var d = LuaDispatcher.init(&vm);
    d.restash();

    var ai: ai_state.AiShip = .{ .id = 0x01000003, .tree = undefined };
    const ctx_nil: perception.PerceptionCtx = .{
        .tick = 0,
        .dt = 0.05,
        .own_pose = .{ .x = 0, .y = 0, .z = 0, .qx = 0, .qy = 0, .qz = 0, .qw = 1 },
        .own_vel = .{ .lin = .{ .x = 0, .y = 0, .z = 0 }, .ang = .{ .x = 0, .y = 0, .z = 0 } },
        .own_hp = 1.0,
        .wind = .{ .dir = 0, .speed = 0 },
        .cell = .{ .x = 0, .y = 0 },
        .nearest_enemy = null,
    };

    d.beginAi(&ai, &ctx_nil);
    defer d.endAi();
    const dispatcher = d.dispatcher();
    try testing.expectEqual(false, dispatcher.cond("has_enemy"));
}

test "dispatcher: PD steer reads ctx.own_vel.ang.y and damps overshoot" {
    // Smoke for the PD heading controller in pirate_sloop.lua. We
    // re-implement steer_toward inline in the test so the assertions
    // pin the math, not the lua file. If pirate_sloop.lua's tuning
    // changes, this test stays anchored to the controller form.
    //
    // Output is the negation of the PD law because +steer drives a
    // -Y torque on the bow lateral force (verified by torque calc in
    // ship-sim/main.zig applyShipInputForces) → ω_y decreases →
    // heading decreases. To make heading INCREASE toward a positive
    // diff, the controller emits NEGATIVE steer.
    var vm = try lua.Vm.init();
    defer vm.deinit();

    try vm.doString(
        \\local kp, kd = 2.0 / math.pi, 0.5
        \\local function clamp(v) if v <  -1 then return -1 end
        \\                        if v >   1 then return  1 end
        \\                        return v end
        \\function steer()
        \\  local diff = math.pi  -- desired requires +π rotation
        \\  local omega = ctx.own_vel.ang.y
        \\  set_steer(clamp(-(kp * diff - kd * omega)))
        \\  return "success"
        \\end
    );

    var d = LuaDispatcher.init(&vm);
    d.restash();

    var ai: ai_state.AiShip = .{ .id = 0x01000003, .tree = undefined };

    // Case 1: angvel_y = 0, diff = +π → controller demands full
    // negative steer (which produces +Y torque, growing ω_y, growing
    // heading toward target).
    {
        const ctx: perception.PerceptionCtx = .{
            .tick = 0,
            .dt = 0.05,
            .own_pose = .{ .x = 0, .y = 0, .z = 0, .qx = 0, .qy = 0, .qz = 0, .qw = 1 },
            .own_vel = .{
                .lin = .{ .x = 0, .y = 0, .z = 0 },
                .ang = .{ .x = 0, .y = 0, .z = 0 },
            },
            .own_hp = 1.0,
            .wind = .{ .dir = 0, .speed = 0 },
            .cell = .{ .x = 0, .y = 0 },
            .nearest_enemy = null,
        };
        d.beginAi(&ai, &ctx);
        defer d.endAi();
        _ = d.dispatcher().action("steer");
        try testing.expectApproxEqAbs(@as(f32, -1.0), ai.pending_input.?.steer, 1e-6);
    }

    // Case 2: ship is already rotating toward the desired heading at
    // ω = +1.0 rad/s (correct direction since heading needs to grow).
    // Kp*π = 2.0, Kd*ω = 0.5; raw PD = 1.5; output = -1.5 → clamp to
    // -1.0. Still demanding full counter-torque; damping has authority
    // but the error dominates.
    {
        const ctx: perception.PerceptionCtx = .{
            .tick = 0,
            .dt = 0.05,
            .own_pose = .{ .x = 0, .y = 0, .z = 0, .qx = 0, .qy = 0, .qz = 0, .qw = 1 },
            .own_vel = .{
                .lin = .{ .x = 0, .y = 0, .z = 0 },
                .ang = .{ .x = 0, .y = 1.0, .z = 0 },
            },
            .own_hp = 1.0,
            .wind = .{ .dir = 0, .speed = 0 },
            .cell = .{ .x = 0, .y = 0 },
            .nearest_enemy = null,
        };
        d.beginAi(&ai, &ctx);
        defer d.endAi();
        _ = d.dispatcher().action("steer");
        try testing.expectApproxEqAbs(@as(f32, -1.0), ai.pending_input.?.steer, 1e-6);
    }

    // Case 3: ship is rotating well past the desired rate. ω = +5.0
    // rad/s. Kp*π = 2.0, Kd*ω = 2.5 → raw PD = -0.5; output = +0.5,
    // i.e. the command flips positive (away from the target direction)
    // to brake the overshoot. This is the case the PD damping targets.
    {
        const ctx: perception.PerceptionCtx = .{
            .tick = 0,
            .dt = 0.05,
            .own_pose = .{ .x = 0, .y = 0, .z = 0, .qx = 0, .qy = 0, .qz = 0, .qw = 1 },
            .own_vel = .{
                .lin = .{ .x = 0, .y = 0, .z = 0 },
                .ang = .{ .x = 0, .y = 5.0, .z = 0 },
            },
            .own_hp = 1.0,
            .wind = .{ .dir = 0, .speed = 0 },
            .cell = .{ .x = 0, .y = 0 },
            .nearest_enemy = null,
        };
        d.beginAi(&ai, &ctx);
        defer d.endAi();
        _ = d.dispatcher().action("steer");
        try testing.expectApproxEqAbs(@as(f32, 0.5), ai.pending_input.?.steer, 1e-6);
    }
}

test "dispatcher: helpers no-op when no ai is latched" {
    var vm = try lua.Vm.init();
    defer vm.deinit();

    try vm.doString("function set() set_thrust(0.5) return \"success\" end");

    var d = LuaDispatcher.init(&vm);
    d.restash();
    // No beginAi — current_ai is null. set_thrust must silently no-op.
    const dispatcher = d.dispatcher();
    _ = dispatcher.action("set");
    // No way to assert anything mutated; the assertion is "didn't crash".
    _ = wire.InputMsg{};
}
