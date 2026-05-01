//! Comptime Lua marshaling layer.
//!
//! Layered on top of `lua_c.zig`. Provides:
//!
//!   - `Vm` — owned wrapper around `*lua.State` with init/deinit.
//!   - `pushValue(comptime T, value)` — push a Zig value to the Lua
//!     stack. Handles ints, floats, bools, strings, optionals, enums
//!     (as their `@tagName`), and structs (as tables, recursively).
//!   - `pullSingle(comptime T, idx)` — read a Zig value from a stack
//!     index. Inverse of `pushValue` for the supported subset.
//!   - `registerFn(name, comptime fn)` — register a Zig function as a
//!     Lua-callable global. The wrapper is comptime-generated from the
//!     Zig function's signature; arguments are pulled by position,
//!     results pushed.
//!   - `callFn(name, args_tuple, comptime ReturnType)` — call a
//!     Lua-defined global with marshaled arguments and return.
//!
//! Ported from fallen-runes' `lua_bind.zig`, retargeted from the
//! `zlua` wrapper module to our thin `lua_c.zig` C binding (per
//! memory `feedback_thin_c_bindings.md`). Trust/Side filtering and
//! doc-gen hooks present in fallen-runes were intentionally NOT
//! lifted — both are fallen-runes-specific surface area we don't
//! need yet. Add back in their own commits if the use case appears.

const std = @import("std");
const lua = @import("lua_c.zig");

pub const Error = error{
    LuaInit,
    LuaSyntax,
    LuaRuntime,
    LuaMemory,
    LuaTypeMismatch,
    LuaUnknownFn,
};

/// Owned Lua VM. One per ai-sim cohort, one per recipe pool, etc.
/// Not thread-safe — Lua states are single-threaded by construction.
pub const Vm = struct {
    L: *lua.State,

    pub fn init() Error!Vm {
        const L = lua.luaL_newstate() orelse return error.LuaInit;
        lua.luaL_openlibs(L);
        return .{ .L = L };
    }

    pub fn deinit(self: *Vm) void {
        lua.close(self.L);
        self.* = undefined;
    }

    /// Load and execute a Lua source chunk. Anything the chunk defines
    /// as a global stays in the VM's global table afterward.
    pub fn doString(self: *Vm, source: [:0]const u8) Error!void {
        const rc = lua.luaL_dostring(self.L, source.ptr);
        return mapError(self.L, rc);
    }
};

// ----- error mapping -----

fn mapError(L: *lua.State, rc: c_int) Error!void {
    switch (rc) {
        lua.OK => return,
        lua.ERRSYNTAX => {
            logTopAsString(L, "lua syntax error");
            lua.pop(L, 1);
            return error.LuaSyntax;
        },
        lua.ERRRUN => {
            logTopAsString(L, "lua runtime error");
            lua.pop(L, 1);
            return error.LuaRuntime;
        },
        lua.ERRMEM => return error.LuaMemory,
        else => {
            logTopAsString(L, "lua unknown error");
            lua.pop(L, 1);
            return error.LuaRuntime;
        },
    }
}

fn logTopAsString(L: *lua.State, prefix: []const u8) void {
    if (lua.tostring(L, -1)) |s| {
        std.log.warn("{s}: {s}", .{ prefix, std.mem.span(s) });
    } else {
        std.log.warn("{s}: <no message>", .{prefix});
    }
}

// ----- pull (Lua stack -> Zig) -----

/// Read a Zig value of type `T` from stack index `idx`. Returns sane
/// defaults on type mismatch (0 for numbers, "" for strings) — same
/// semantics fallen-runes settled on. Callers that want strict
/// type-checking should use `lua.luaL_check*` directly.
pub fn pullSingle(L: *lua.State, comptime T: type, idx: c_int) T {
    return switch (@typeInfo(T)) {
        .int => pullInteger(L, T, idx),
        .float => pullFloat(L, T, idx),
        .bool => lua.toboolean(L, idx) != 0,
        .pointer => blk: {
            if (comptime isStringType(T)) {
                const s = lua.tostring(L, idx) orelse break :blk "";
                break :blk std.mem.span(s);
            }
            @compileError("Unsupported pointer type for Lua pull: " ++ @typeName(T));
        },
        .optional => |opt| pullOptional(L, opt.child, idx),
        .@"enum" => pullEnum(L, T, idx),
        else => @compileError("Unsupported pull type for Lua binding: " ++ @typeName(T)),
    };
}

fn pullInteger(L: *lua.State, comptime T: type, idx: c_int) T {
    const raw: lua.Integer = lua.tointeger(L, idx);
    return std.math.cast(T, raw) orelse 0;
}

fn pullFloat(L: *lua.State, comptime T: type, idx: c_int) T {
    const raw: lua.Number = lua.tonumber(L, idx);
    return @floatCast(raw);
}

fn pullOptional(L: *lua.State, comptime Child: type, idx: c_int) ?Child {
    if (lua.isnoneornil(L, idx)) return null;
    return pullSingle(L, Child, idx);
}

/// Pull an enum value. The Lua side may pass either the tag name as a
/// string (preferred — survives copy-paste from logs and is what
/// `pushValue` for enums emits) or the integer ordinal. String form
/// wins if both could parse.
fn pullEnum(L: *lua.State, comptime T: type, idx: c_int) T {
    if (lua.isstring(L, idx) != 0) {
        const s = lua.tostring(L, idx) orelse return @as(T, @enumFromInt(0));
        return std.meta.stringToEnum(T, std.mem.span(s)) orelse @as(T, @enumFromInt(0));
    }
    if (lua.isinteger(L, idx) != 0) {
        const n: lua.Integer = lua.tointeger(L, idx);
        const tag = std.math.cast(@typeInfo(T).@"enum".tag_type, n) orelse return @as(T, @enumFromInt(0));
        return std.meta.intToEnum(T, tag) catch @as(T, @enumFromInt(0));
    }
    return @as(T, @enumFromInt(0));
}

// ----- push (Zig -> Lua stack) -----

/// Push a Zig value of type `T`. Recursive for structs (each field
/// becomes a table entry keyed by field name) and optionals (nil if
/// `null`, otherwise the inner value). Enums become their `@tagName`
/// as a string — round-trips via `pullEnum`.
pub fn pushValue(L: *lua.State, comptime T: type, value: T) void {
    switch (@typeInfo(T)) {
        .int, .comptime_int => lua.pushinteger(L, @intCast(value)),
        .float, .comptime_float => lua.pushnumber(L, @floatCast(value)),
        .bool => lua.pushboolean(L, @intFromBool(value)),
        .void => {},
        .pointer => {
            if (comptime isStringType(T)) {
                lua.pushstring(L, value.ptr);
            } else {
                @compileError("Unsupported pointer type for Lua push: " ++ @typeName(T));
            }
        },
        .optional => |opt| {
            if (value) |v| {
                pushValue(L, opt.child, v);
            } else {
                lua.pushnil(L);
            }
        },
        .@"struct" => |s| {
            lua.createtable(L, 0, @intCast(s.fields.len));
            inline for (s.fields) |field| {
                pushValue(L, field.type, @field(value, field.name));
                lua.setfield(L, -2, field.name.ptr);
            }
        },
        .@"enum" => {
            lua.pushstring(L, @tagName(value));
        },
        else => @compileError("Unsupported push type for Lua binding: " ++ @typeName(T)),
    }
}

fn pushResult(L: *lua.State, comptime T: type, value: T) c_int {
    if (T == void) return 0;
    pushValue(L, T, value);
    return 1;
}

// ----- comptime function wrapping -----

fn isStringType(comptime T: type) bool {
    if (T == [:0]const u8) return true;
    if (T == []const u8) return true;
    return false;
}

fn PullArgsTuple(comptime params: []const std.builtin.Type.Fn.Param) type {
    var fields: [params.len]std.builtin.Type.StructField = undefined;
    inline for (0..params.len) |i| {
        fields[i] = .{
            .name = std.fmt.comptimePrint("{d}", .{i}),
            .type = params[i].type.?,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = 0,
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = true,
    } });
}

fn pullArgs(L: *lua.State, comptime params: []const std.builtin.Type.Fn.Param) PullArgsTuple(params) {
    var args: PullArgsTuple(params) = undefined;
    inline for (0..params.len) |i| {
        const ParamType = params[i].type.?;
        args[i] = pullSingle(L, ParamType, @as(c_int, @intCast(i + 1)));
    }
    return args;
}

/// Generate a Lua C-callback that adapts a Zig function. Arguments are
/// pulled by position from the Lua stack; result is pushed back.
fn makeWrapper(comptime FnType: type, comptime func: FnType) lua.CFunction {
    const info = @typeInfo(FnType).@"fn";
    const params = info.params;
    const ReturnType = info.return_type.?;
    const Wrapper = struct {
        fn cb(L_opt: ?*lua.State) callconv(.c) c_int {
            const L = L_opt.?;
            const args = pullArgs(L, params);
            const result = @call(.auto, func, args);
            return pushResult(L, ReturnType, result);
        }
    };
    return Wrapper.cb;
}

/// Register a Zig function as a Lua-callable global with name `name`.
/// The function's argument and return types must be supported by
/// `pullSingle` / `pushValue` (ints, floats, bools, strings,
/// optionals, structs, enums).
pub fn registerFn(
    vm: *Vm,
    comptime name: [:0]const u8,
    comptime func: anytype,
) void {
    const FnType = @TypeOf(func);
    const wrapper = makeWrapper(FnType, func);
    lua.pushcfunction(vm.L, wrapper);
    lua.setglobal(vm.L, name.ptr);
}

// ----- calling Lua-defined functions -----

/// Call a Lua-defined global function by name with positional
/// arguments and read back a typed result. `args` is a tuple/struct
/// whose fields are pushed in order.
pub fn callFn(
    vm: *Vm,
    comptime name: [:0]const u8,
    args: anytype,
    comptime ReturnType: type,
) Error!ReturnType {
    const ArgsType = @TypeOf(args);
    const args_info = @typeInfo(ArgsType).@"struct";

    const t = lua.getglobal(vm.L, name.ptr);
    if (t != lua.TFUNCTION) {
        lua.pop(vm.L, 1);
        return error.LuaUnknownFn;
    }

    inline for (args_info.fields) |field| {
        pushValue(vm.L, field.type, @field(args, field.name));
    }

    const nargs: c_int = @intCast(args_info.fields.len);
    const nresults: c_int = if (ReturnType == void) 0 else 1;
    const rc = lua.pcall(vm.L, nargs, nresults, 0);
    try mapError(vm.L, rc);

    if (ReturnType == void) return;
    const result = pullSingle(vm.L, ReturnType, -1);
    lua.pop(vm.L, 1);
    return result;
}

// ----- tests -----

const testing = std.testing;

test "Vm init / deinit" {
    var vm = try Vm.init();
    defer vm.deinit();
    try testing.expectEqual(@as(c_int, 0), lua.gettop(vm.L));
}

test "doString — return value left on stack stays" {
    var vm = try Vm.init();
    defer vm.deinit();
    try vm.doString("x = 7 * 6");
    _ = lua.getglobal(vm.L, "x");
    try testing.expectEqual(@as(lua.Integer, 42), lua.tointeger(vm.L, -1));
    lua.pop(vm.L, 1);
}

test "doString surfaces syntax error as Error.LuaSyntax" {
    var vm = try Vm.init();
    defer vm.deinit();
    try testing.expectError(error.LuaSyntax, vm.doString("function ("));
}

test "doString surfaces runtime error as Error.LuaRuntime" {
    var vm = try Vm.init();
    defer vm.deinit();
    try testing.expectError(error.LuaRuntime, vm.doString("error('boom')"));
}

test "pushValue / pullSingle round-trip — primitives" {
    var vm = try Vm.init();
    defer vm.deinit();

    pushValue(vm.L, u32, 0x01_000_002);
    try testing.expectEqual(@as(u32, 0x01_000_002), pullSingle(vm.L, u32, -1));
    lua.pop(vm.L, 1);

    pushValue(vm.L, f32, 3.5);
    try testing.expectEqual(@as(f32, 3.5), pullSingle(vm.L, f32, -1));
    lua.pop(vm.L, 1);

    pushValue(vm.L, bool, true);
    try testing.expect(pullSingle(vm.L, bool, -1));
    lua.pop(vm.L, 1);

    pushValue(vm.L, [:0]const u8, "starboard");
    try testing.expectEqualStrings("starboard", pullSingle(vm.L, []const u8, -1));
    lua.pop(vm.L, 1);
}

test "pushValue / pullSingle — optionals" {
    var vm = try Vm.init();
    defer vm.deinit();

    const Some: ?i32 = 42;
    pushValue(vm.L, ?i32, Some);
    try testing.expectEqual(@as(?i32, 42), pullSingle(vm.L, ?i32, -1));
    lua.pop(vm.L, 1);

    const None: ?i32 = null;
    pushValue(vm.L, ?i32, None);
    try testing.expectEqual(@as(?i32, null), pullSingle(vm.L, ?i32, -1));
    lua.pop(vm.L, 1);
}

test "pushValue — struct round-trips through Lua" {
    var vm = try Vm.init();
    defer vm.deinit();

    const Pose = struct { x: f32, y: f32, z: f32 };
    pushValue(vm.L, Pose, .{ .x = 1.0, .y = 2.0, .z = 3.0 });
    lua.setglobal(vm.L, "p");

    try vm.doString("ok = p.x == 1.0 and p.y == 2.0 and p.z == 3.0");
    _ = lua.getglobal(vm.L, "ok");
    try testing.expect(pullSingle(vm.L, bool, -1));
    lua.pop(vm.L, 1);
}

test "pushValue / pullSingle — enum as @tagName" {
    var vm = try Vm.init();
    defer vm.deinit();

    const Status = enum { success, failure, running };
    pushValue(vm.L, Status, .running);
    try testing.expectEqual(Status.running, pullSingle(vm.L, Status, -1));
    lua.pop(vm.L, 1);

    // Strings round-trip too — designers can return "running" from Lua.
    try vm.doString("s = 'failure'");
    _ = lua.getglobal(vm.L, "s");
    try testing.expectEqual(Status.failure, pullSingle(vm.L, Status, -1));
    lua.pop(vm.L, 1);
}

test "registerFn — Zig fn callable from Lua" {
    var vm = try Vm.init();
    defer vm.deinit();

    const ns = struct {
        fn add(a: i32, b: i32) i32 {
            return a + b;
        }
        fn ge(a: f32, b: f32) bool {
            return a >= b;
        }
    };

    registerFn(&vm, "add", ns.add);
    registerFn(&vm, "ge", ns.ge);

    try vm.doString("r = add(40, 2)");
    _ = lua.getglobal(vm.L, "r");
    try testing.expectEqual(@as(lua.Integer, 42), lua.tointeger(vm.L, -1));
    lua.pop(vm.L, 1);

    try vm.doString("low = ge(0.2, 0.3)");
    _ = lua.getglobal(vm.L, "low");
    try testing.expectEqual(false, pullSingle(vm.L, bool, -1));
    lua.pop(vm.L, 1);
}

test "callFn — call Lua-defined function with args + typed return" {
    var vm = try Vm.init();
    defer vm.deinit();

    try vm.doString(
        \\function low_hp(self, ctx)
        \\    return self.hp < ctx.threshold
        \\end
    );

    const Self = struct { hp: f32 };
    const Ctx = struct { threshold: f32 };

    const wounded = try callFn(&vm, "low_hp", .{
        Self{ .hp = 0.2 },
        Ctx{ .threshold = 0.3 },
    }, bool);
    try testing.expectEqual(true, wounded);

    const healthy = try callFn(&vm, "low_hp", .{
        Self{ .hp = 0.9 },
        Ctx{ .threshold = 0.3 },
    }, bool);
    try testing.expectEqual(false, healthy);
}

test "callFn — Lua returns enum tag string" {
    var vm = try Vm.init();
    defer vm.deinit();

    try vm.doString(
        \\function decide(self, ctx)
        \\    if self.hp < 0.3 then return 'failure'
        \\    elseif ctx.in_range then return 'success'
        \\    else return 'running' end
        \\end
    );

    const Status = enum { success, failure, running };
    const Self = struct { hp: f32 };
    const Ctx = struct { in_range: bool };

    try testing.expectEqual(
        Status.failure,
        try callFn(&vm, "decide", .{ Self{ .hp = 0.1 }, Ctx{ .in_range = true } }, Status),
    );
    try testing.expectEqual(
        Status.success,
        try callFn(&vm, "decide", .{ Self{ .hp = 0.9 }, Ctx{ .in_range = true } }, Status),
    );
    try testing.expectEqual(
        Status.running,
        try callFn(&vm, "decide", .{ Self{ .hp = 0.9 }, Ctx{ .in_range = false } }, Status),
    );
}

test "callFn — unknown function" {
    var vm = try Vm.init();
    defer vm.deinit();
    try testing.expectError(error.LuaUnknownFn, callFn(&vm, "nope", .{}, void));
}

test "callFn — Lua-side runtime error surfaces as Error.LuaRuntime" {
    var vm = try Vm.init();
    defer vm.deinit();
    try vm.doString("function bad() error('explode') end");
    try testing.expectError(error.LuaRuntime, callFn(&vm, "bad", .{}, void));
}
