---
name: Lua 5.4 + thin C binding (not LuaJIT, not ziglua)
description: Locked 2026-04-30 in docs/09-ai-sim.md §13 q3. notatlas embeds PUC Lua 5.4 (vendored C source) with a hand-rolled thin C-API binding in src/shared/lua_c.zig. NOT LuaJIT (frozen at 5.1 + FFI), NOT ziglua/zig-gamedev wrappers.
type: project
originSessionId: c0f21592-5ca9-4571-9536-a4e657490842
---
**Decision: PUC Lua 5.4 + thin C binding.** Vendor the Lua C source under `vendor/lua/`; bind directly against `lua.h`/`lualib.h`/`lauxlib.h` in `src/shared/lua_c.zig`; layer marshaling in `src/shared/lua_bind.zig` on top.

**Why Lua 5.4 over LuaJIT:**
- Modern data types matter for the audience writing scripts. Phase 2/3 brings in FiveM/RP-modding devs (per memory `project_asset_pipeline_fivem_team.md`) who expect modern Lua semantics — real integers, generic for, to-be-closed, modern bitwise operators, goto. LuaJIT freezes them at 5.1 + a partial 5.2 backport for the project's lifetime.
- Perf headroom LuaJIT would buy is unused at our call rates. AI is 20 Hz × 200 ships × ~10 leaves = ~20k Lua C-calls/sec. PUC Lua 5.4 reference interpreter does ~50M/sec; we're at 0.04% of capacity. The HFT instinct of "more perf is wiser" mis-fires here — this is the analytics layer, not the matching engine.
- LuaJIT's vendored build is genuinely worse: DynASM + per-arch assembly. PUC Lua is ~30 plain .c files, builds anywhere. Cross-compile to Windows is trivial.
- LuaJIT stewardship is in maintenance mode (Mike Pall stepped back); PUC Lua is actively maintained on 5.4.7+.

**Why thin C binding over ziglua:**
- Project memory `feedback_thin_c_bindings.md` is explicit: bind against the library's own C API in our tree; don't pull zig-gamedev/etc. wrapper modules.
- ziglua versioning + transitive deps would couple notatlas to a wrapper's evolution; we pay that cost forever for a one-time binding write.
- Smaller surface to audit and cross-compile.
- fallen-runes uses ziglua; that's its choice. notatlas's `lua_bind.zig` lifts the *marshaling logic* (comptime push/pull, struct round-trips) but retargets it from `zlua.*` to our own thin layer.

**How to apply:**
- When adding new Lua-touching code, import from `src/shared/lua_c.zig` (the thin layer) or `src/shared/lua_bind.zig` (the marshaling), never from a wrapper module.
- If a future Phase needs LuaJIT for a *specific* hot path (e.g. recipe eval feeding deterministic projectile resolution at kHz rates), that's a contained migration of that subsystem — don't migrate the whole AI/recipe surface.
- The migration risk is asymmetric: 5.4 → LuaJIT means deleting modern features from leaves; LuaJIT → 5.4 means removing FFI use sites. Either direction is contained as long as scripts stay small.
- Recipes (`docs/05`) and ai-sim leaves (`docs/09`) share this binding. Adding either subsystem doesn't add a second VM dep.

**TypeScript dev front-end (added 2026-05-01):** Lua stays as the runtime, but designers will author in TypeScript via `tstl` (TypeScriptToLua) once content tooling lands. See `project_typescript_dev_frontend.md`. This is what "FiveM is moving to TS" actually means in practice — transpiler, not runtime swap.
