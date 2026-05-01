//! Lua-backed `bt.LeafDispatcher` for ai-sim.
//!
//! Each cohort owns one Lua VM (per docs/09 §13 q3). The dispatcher
//! resolves a leaf's `name` (a runtime `[:0]const u8` from the BT
//! `Node.Leaf`) as a Lua global and calls it with no args. Returns:
//!   - cond:   `bool`  (Lua function returns truthy/falsy)
//!   - action: `Status` (Lua function returns the @tagName string —
//!             "success" / "failure" / "running")
//!
//! Step 5 is no-args: leaves are stateless and don't yet read a
//! perception ctx. Step 6 (docs/09 §7 / §14 step 5→6) wraps this with
//! a ctx-table push before the call. The dispatcher type stays the
//! same; only the call sites change.
//!
//! Missing globals fail closed: cond returns false, action returns
//! .failure. Lua-side runtime errors are logged and treated as
//! failure. This keeps a typo'd leaf name from crashing the cohort —
//! the BT tree just drops to a sibling branch (e.g., the patrol
//! fallback in pirate_sloop.yaml).

const std = @import("std");
const lua = @import("lua");
const notatlas = @import("notatlas");
const bt = notatlas.bt;

pub const LuaDispatcher = struct {
    vm: *lua.Vm,

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

test "dispatcher: missing leaf cond fails closed" {
    var vm = try lua.Vm.init();
    defer vm.deinit();

    var d = LuaDispatcher{ .vm = &vm };
    const dispatcher = d.dispatcher();
    try testing.expectEqual(false, dispatcher.cond("does_not_exist"));
}

test "dispatcher: missing leaf action fails closed" {
    var vm = try lua.Vm.init();
    defer vm.deinit();

    var d = LuaDispatcher{ .vm = &vm };
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

    var d = LuaDispatcher{ .vm = &vm };
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

    var d = LuaDispatcher{ .vm = &vm };
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

    var d = LuaDispatcher{ .vm = &vm };
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

    var d = LuaDispatcher{ .vm = &vm };

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
