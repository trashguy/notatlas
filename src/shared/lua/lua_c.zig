//! Thin Lua 5.4 C-API binding.
//!
//! Direct `extern fn` declarations against the upstream Lua headers. No
//! wrapping, no namespacing — the function names match `lua.h` /
//! `lualib.h` / `lauxlib.h` exactly. Higher-level Zig ergonomics (push
//! a struct as a table, pull a typed argument by index) live in
//! `lua_bind.zig`, layered on top of this file.
//!
//! Why thin: project memory `feedback_thin_c_bindings.md` — bind
//! against the library's own C API in our own tree; don't pull
//! ziglua / zig-gamedev wrapper modules. fallen-runes uses ziglua;
//! notatlas does not.
//!
//! Coverage: the subset of Lua's C API used by notatlas's marshaling
//! layer and tests. Not a full mirror of `lua.h` — we add functions
//! here as they're needed. Ports of unused calls are wasted maintenance.

const std = @import("std");

pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
    @cInclude("lauxlib.h");
});

// ----- core types -----

pub const State = c.lua_State;
pub const CFunction = c.lua_CFunction;
pub const Integer = c.lua_Integer;
pub const Number = c.lua_Number;
pub const KContext = c.lua_KContext;
pub const KFunction = c.lua_KFunction;

// ----- type tags -----

pub const TNONE = c.LUA_TNONE;
pub const TNIL = c.LUA_TNIL;
pub const TBOOLEAN = c.LUA_TBOOLEAN;
pub const TLIGHTUSERDATA = c.LUA_TLIGHTUSERDATA;
pub const TNUMBER = c.LUA_TNUMBER;
pub const TSTRING = c.LUA_TSTRING;
pub const TTABLE = c.LUA_TTABLE;
pub const TFUNCTION = c.LUA_TFUNCTION;
pub const TUSERDATA = c.LUA_TUSERDATA;
pub const TTHREAD = c.LUA_TTHREAD;

// ----- pcall return codes -----

pub const OK = c.LUA_OK;
pub const YIELD = c.LUA_YIELD;
pub const ERRRUN = c.LUA_ERRRUN;
pub const ERRSYNTAX = c.LUA_ERRSYNTAX;
pub const ERRMEM = c.LUA_ERRMEM;
pub const ERRERR = c.LUA_ERRERR;

// ----- pseudo-indices -----

pub const REGISTRYINDEX = c.LUA_REGISTRYINDEX;
pub fn upvalueindex(i: c_int) c_int {
    return REGISTRYINDEX - i;
}

pub const MULTRET = c.LUA_MULTRET;

// ----- state lifecycle -----

pub const newstate = c.lua_newstate;
pub const close = c.lua_close;
pub const newthread = c.lua_newthread;
pub const luaL_newstate = c.luaL_newstate;
pub const luaL_openlibs = c.luaL_openlibs;

// ----- stack manipulation -----

pub const gettop = c.lua_gettop;
pub const settop = c.lua_settop;
pub const pushvalue = c.lua_pushvalue;
pub const remove = c.lua_remove;
pub const insert = c.lua_insert;
pub const replace = c.lua_replace;
pub const copy = c.lua_copy;
pub const checkstack = c.lua_checkstack;

pub fn pop(L: *State, n: c_int) void {
    settop(L, -n - 1);
}

// ----- type queries -----

pub const @"type" = c.lua_type;
pub const typename = c.lua_typename;
pub const isnumber = c.lua_isnumber;
pub const isstring = c.lua_isstring;
pub const iscfunction = c.lua_iscfunction;
pub const isinteger = c.lua_isinteger;
pub const isuserdata = c.lua_isuserdata;
pub const rawequal = c.lua_rawequal;
pub const compare = c.lua_compare;

pub fn isfunction(L: *State, idx: c_int) bool {
    return @"type"(L, idx) == TFUNCTION;
}
pub fn istable(L: *State, idx: c_int) bool {
    return @"type"(L, idx) == TTABLE;
}
pub fn isnil(L: *State, idx: c_int) bool {
    return @"type"(L, idx) == TNIL;
}
pub fn isboolean(L: *State, idx: c_int) bool {
    return @"type"(L, idx) == TBOOLEAN;
}
pub fn isthread(L: *State, idx: c_int) bool {
    return @"type"(L, idx) == TTHREAD;
}
pub fn isnone(L: *State, idx: c_int) bool {
    return @"type"(L, idx) == TNONE;
}
pub fn isnoneornil(L: *State, idx: c_int) bool {
    return @"type"(L, idx) <= TNIL;
}

// ----- read from stack -----

pub const tonumberx = c.lua_tonumberx;
pub const tointegerx = c.lua_tointegerx;
pub const toboolean = c.lua_toboolean;
pub const tolstring = c.lua_tolstring;
pub const rawlen = c.lua_rawlen;
pub const tocfunction = c.lua_tocfunction;
pub const touserdata = c.lua_touserdata;
pub const tothread = c.lua_tothread;
pub const topointer = c.lua_topointer;

pub fn tonumber(L: *State, idx: c_int) Number {
    return tonumberx(L, idx, null);
}
pub fn tointeger(L: *State, idx: c_int) Integer {
    return tointegerx(L, idx, null);
}
pub fn tostring(L: *State, idx: c_int) ?[*:0]const u8 {
    return tolstring(L, idx, null);
}

// ----- push to stack -----

pub const pushnil = c.lua_pushnil;
pub const pushnumber = c.lua_pushnumber;
pub const pushinteger = c.lua_pushinteger;
pub const pushcclosure = c.lua_pushcclosure;
pub const pushboolean = c.lua_pushboolean;
pub const pushlightuserdata = c.lua_pushlightuserdata;
pub const pushthread = c.lua_pushthread;

// `lua_pushstring` / `lua_pushlstring` return a `const char*` to the
// duplicated string. Callers almost never want it; wrap as void and
// expose the returning forms separately for the rare case (e.g.
// pinning the duplicated buffer).
pub fn pushstring(L: *State, s: [*:0]const u8) void {
    _ = c.lua_pushstring(L, s);
}
pub fn pushlstring(L: *State, s: [*]const u8, len: usize) void {
    _ = c.lua_pushlstring(L, s, len);
}
pub const pushstring_returning = c.lua_pushstring;
pub const pushlstring_returning = c.lua_pushlstring;

pub fn pushcfunction(L: *State, fnref: CFunction) void {
    pushcclosure(L, fnref, 0);
}

// ----- table access -----

pub const getglobal = c.lua_getglobal;
pub const setglobal = c.lua_setglobal;
pub const gettable = c.lua_gettable;
pub const settable = c.lua_settable;
pub const getfield = c.lua_getfield;
pub const setfield = c.lua_setfield;
pub const geti = c.lua_geti;
pub const seti = c.lua_seti;
pub const rawget = c.lua_rawget;
pub const rawset = c.lua_rawset;
pub const rawgeti = c.lua_rawgeti;
pub const rawseti = c.lua_rawseti;
pub const createtable = c.lua_createtable;
pub const newuserdatauv = c.lua_newuserdatauv;
pub const getmetatable = c.lua_getmetatable;
pub const setmetatable = c.lua_setmetatable;
pub const next = c.lua_next;

pub fn newtable(L: *State) void {
    createtable(L, 0, 0);
}

// ----- call / load / pcall -----

pub const callk = c.lua_callk;
pub const pcallk = c.lua_pcallk;
pub const load = c.lua_load;
pub const dump = c.lua_dump;

pub fn call(L: *State, nargs: c_int, nresults: c_int) void {
    callk(L, nargs, nresults, 0, null);
}
pub fn pcall(L: *State, nargs: c_int, nresults: c_int, errfunc: c_int) c_int {
    return pcallk(L, nargs, nresults, errfunc, 0, null);
}

// ----- auxlib (luaL_*) -----

pub const luaL_loadstring = c.luaL_loadstring;
pub const luaL_loadbufferx = c.luaL_loadbufferx;
pub const luaL_loadfilex = c.luaL_loadfilex;
pub const luaL_dofile_unused: void = {}; // luaL_dofile is a macro; expand inline if we ever need it.
pub const luaL_error = c.luaL_error;
pub const luaL_argerror = c.luaL_argerror;
pub const luaL_typeerror = c.luaL_typeerror;
pub const luaL_checknumber = c.luaL_checknumber;
pub const luaL_checkinteger = c.luaL_checkinteger;
pub const luaL_checklstring = c.luaL_checklstring;
pub const luaL_optinteger = c.luaL_optinteger;
pub const luaL_optnumber = c.luaL_optnumber;
pub const luaL_optlstring = c.luaL_optlstring;
pub const luaL_checktype = c.luaL_checktype;
pub const luaL_checkany = c.luaL_checkany;
pub const luaL_ref = c.luaL_ref;
pub const luaL_unref = c.luaL_unref;
pub const luaL_setfuncs = c.luaL_setfuncs;
pub const luaL_newlib_unused: void = {}; // macro; emit `newtable` + `luaL_setfuncs` inline at call sites.
pub const luaL_register = c.luaL_register;

pub fn luaL_dostring(L: *State, str: [*:0]const u8) c_int {
    const rc = luaL_loadstring(L, str);
    if (rc != OK) return rc;
    return pcall(L, 0, MULTRET, 0);
}

pub fn luaL_checkstring(L: *State, n: c_int) [*:0]const u8 {
    return luaL_checklstring(L, n, null);
}

// ----- error helpers -----

pub const @"error" = c.lua_error;
pub const traceback = c.luaL_traceback;

// ----- gc -----

pub const gc = c.lua_gc;
pub const GCSTOP = c.LUA_GCSTOP;
pub const GCRESTART = c.LUA_GCRESTART;
pub const GCCOLLECT = c.LUA_GCCOLLECT;
pub const GCCOUNT = c.LUA_GCCOUNT;
pub const GCCOUNTB = c.LUA_GCCOUNTB;

// ----- version sanity (compile-time) -----

comptime {
    if (c.LUA_VERSION_NUM != 504) {
        @compileError("notatlas expects Lua 5.4; vendor/lua is something else");
    }
}

// ----- smoke tests -----

test "open and close a Lua state" {
    const L = luaL_newstate() orelse return error.LuaAllocFailed;
    defer close(L);
    luaL_openlibs(L);
    try std.testing.expectEqual(@as(c_int, 0), gettop(L));
}

test "evaluate a string and read a return value" {
    const L = luaL_newstate() orelse return error.LuaAllocFailed;
    defer close(L);
    luaL_openlibs(L);

    const rc = luaL_dostring(L, "return 7 * 6");
    try std.testing.expectEqual(OK, rc);
    try std.testing.expect(isnumber(L, -1) != 0);
    try std.testing.expectEqual(@as(Integer, 42), tointeger(L, -1));
    pop(L, 1);
    try std.testing.expectEqual(@as(c_int, 0), gettop(L));
}

test "set and read a global integer" {
    const L = luaL_newstate() orelse return error.LuaAllocFailed;
    defer close(L);
    luaL_openlibs(L);

    pushinteger(L, 1234);
    setglobal(L, "answer");
    _ = getglobal(L, "answer");
    try std.testing.expect(isinteger(L, -1) != 0);
    try std.testing.expectEqual(@as(Integer, 1234), tointeger(L, -1));
    pop(L, 1);
}

test "pcall surfaces a runtime error" {
    const L = luaL_newstate() orelse return error.LuaAllocFailed;
    defer close(L);
    luaL_openlibs(L);

    const rc = luaL_dostring(L, "error('boom')");
    try std.testing.expectEqual(ERRRUN, rc);
    try std.testing.expect(isstring(L, -1) != 0);
    pop(L, 1);
}

test "round-trip a string through a Lua table" {
    const L = luaL_newstate() orelse return error.LuaAllocFailed;
    defer close(L);
    luaL_openlibs(L);

    newtable(L);
    pushstring(L, "starboard");
    setfield(L, -2, "side");
    _ = getfield(L, -1, "side");
    const s = tostring(L, -1) orelse return error.NotAString;
    try std.testing.expectEqualStrings("starboard", std.mem.span(s));
    pop(L, 2);
    try std.testing.expectEqual(@as(c_int, 0), gettop(L));
}

test "Lua 5.4 integer/float distinction is observable" {
    // The headline reason we picked 5.4 over LuaJIT — 5.1 collapses
    // these into a single numeric type. If this ever fails after a
    // version bump, the binding's assumptions need an audit.
    const L = luaL_newstate() orelse return error.LuaAllocFailed;
    defer close(L);
    luaL_openlibs(L);

    try std.testing.expectEqual(OK, luaL_dostring(L, "return 3"));
    try std.testing.expect(isinteger(L, -1) != 0);
    pop(L, 1);

    try std.testing.expectEqual(OK, luaL_dostring(L, "return 3.0"));
    try std.testing.expect(isinteger(L, -1) == 0);
    try std.testing.expect(isnumber(L, -1) != 0);
    pop(L, 1);
}
