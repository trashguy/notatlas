# vendor/lua provenance

| Field | Value |
|---|---|
| Upstream project | Lua (PUC-Rio reference implementation) |
| Version | 5.4.8 |
| Release date | 2025-05-21 |
| Source URL | https://www.lua.org/ftp/lua-5.4.8.tar.gz |
| SHA256 | `4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae` |
| License | MIT (see terminal copyright block in `src/lua.h`) |
| Vendored on | 2026-04-30 |

## Why vendored

Per `feedback_thin_c_bindings.md` (project memory), notatlas binds
against C/C++ libraries' own C APIs in our own tree rather than pulling
zig-gamedev / wrapper modules. Lua is C99, ~30 plain `.c` files, and
trivial to compile from source via `build.zig`. Vendoring keeps the
build hermetic: no Zig package manager round-trip for a stable upstream
that updates ~once a year.

VM choice (PUC Lua 5.4 over LuaJIT) is locked in
`docs/09-ai-sim.md` §13 q3 and memory
`architecture_lua_54_thin_c_binding.md`.

## How it's built

`build.zig` defines `buildLua(b, target, optimize)` which compiles the
33 library `.c` files under `src/` into a static library `liblua.a`.
The two CLI mains (`lua.c` for the standalone interpreter, `luac.c` for
the bytecode compiler) are intentionally excluded — notatlas embeds Lua
as a library, not a host program.

Compile defines:

| Target | Defines | Reason |
|---|---|---|
| Linux | `LUA_USE_LINUX` | Enables POSIX + `dlopen` for native module loading; standard upstream Linux config minus readline (we don't ship a Lua REPL). |
| Windows | (none) | Lua's default config works for Windows without flags. |

Standard: `c99` (Lua's documented requirement).

## How to bump

When upstream releases a new 5.4.x:

1. `curl -sSL -o lua-5.4.X.tar.gz https://www.lua.org/ftp/lua-5.4.X.tar.gz`
2. Verify SHA256 against https://www.lua.org/ftp/
3. `rm -rf vendor/lua && tar xzf lua-5.4.X.tar.gz && mv lua-5.4.X vendor/lua`
4. Update version + SHA256 in this file
5. Update version row in `THIRD_PARTY_LICENSES.md`
6. `zig build test` — the binding tests cover the C API surface we use;
   if upstream changes a function signature, they catch it.

Stay on 5.4.x. A jump to 5.5 (when it ships) is a separate decision —
the binding will need an audit for any changed C API signatures.

## What's NOT included from upstream

- `Makefile`, `doc/` HTML — kept (harmless, ~few hundred KB), since
  having the upstream README/manual locally is useful and `build.zig`
  ignores them.

## License

Lua is MIT-licensed by Lua.org / PUC-Rio (1994-2025). The license text
is embedded as a comment block at the bottom of every header including
`src/lua.h`. See `THIRD_PARTY_LICENSES.md` at repo root for the
project-wide third-party license inventory.
