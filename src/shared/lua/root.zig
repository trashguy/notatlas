//! Lua module root.
//!
//! Two layers:
//!   - `c` — thin C binding to Lua 5.4 (`lua_c.zig`). Direct extern
//!     fns matching `lua.h`. Use this for raw stack manipulation.
//!   - `bind` — comptime marshaling on top of `c` (`lua_bind.zig`).
//!     `Vm`, `pushValue`/`pullSingle`, `registerFn`, `callFn`. This
//!     is what ai-sim leaves and recipe runners actually use.

pub const c = @import("lua_c.zig");
pub const bind = @import("lua_bind.zig");

// Re-export the marshaling surface so callers don't need to dig into `bind.*`.
pub const Vm = bind.Vm;
pub const Error = bind.Error;
pub const pushValue = bind.pushValue;
pub const pullSingle = bind.pullSingle;
pub const registerFn = bind.registerFn;
pub const callFn = bind.callFn;

test {
    _ = @import("lua_c.zig");
    _ = @import("lua_bind.zig");
}
