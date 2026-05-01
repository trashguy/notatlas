---
name: TypeScript-via-tstl is the planned dev front-end (Lua at runtime)
description: 2026-05-01 plan: when content tooling lands, wire TypeScriptToLua into the build pipeline so FiveM-background devs author in .ts; runtime stays Lua 5.4. Driven by the team announcing a TS pivot mid-Phase-1.
type: project
originSessionId: e2740a41-5ada-4d7b-b126-d6d078d00607
---
**Decision: TS as authoring layer, Lua 5.4 as runtime.**

When content tooling lands (Phase 2/3 per `project_asset_pipeline_fivem_team.md`), wire [TypeScriptToLua](https://typescripttolua.github.io/) (`tstl`) into the build pipeline so designers author `.ts` and ship-time-compile to `.lua`. The Lua 5.4 lock from 2026-04-30 (`architecture_lua_54_thin_c_binding.md`) is unchanged — we keep the embedding story (thin C binding, ~30 ns/call, ~300 KB binary, ~1 MB resident).

**Why:** Phase 2/3 audience is moving from Lua to TS in the FiveM ecosystem. What "FiveM TS" actually means in practice is `tstl`, not a runtime swap; teams are still on Lua, just authoring in TS for types + modern syntax. We follow the same pattern.

**Why NOT pivot the runtime to V8 / QuickJS:**
- V8 per-call overhead is 15–60× Lua's (~500 ns – 2 µs vs ~30 ns), with a ~30 MB binary and ~80 MB resident isolate. ai-sim's hot path is call-boundary-bound, not compute-bound, so the steady-state JIT win doesn't show up at our scale (docs/09 §4.4 already has huge headroom).
- QuickJS is competitive on embedding (~600 KB, similar per-call to Lua) but loses the steady-state advantage and is interp-only — no upside.
- Migrating to JS runtime means re-doing the entire embedding story for a feature (TS DX) that `tstl` provides for free.

**How to apply:**
- Don't propose embedding V8/Node/QuickJS as a Lua replacement.
- When content tooling Phase begins, plan for `tstl` as a build step alongside the YAML loader.
- Flag the known `tstl` gotchas early when the time comes: no native `async/await` (no event loop unless we expose one), some TS idioms require Lua-flavored equivalents (truthy coercion of `0`/`""`, string ops, no `Map`/`Set` 1:1), `tstl` has its own subset of TS-stdlib it can transpile.
- If anyone says "FiveM is moving to TS" — confirm they mean `tstl`, not the experimental FXServer Node runtime. The Node-runtime path would be a separate (unattractive) conversation.

**What this does NOT change:**
- Lua 5.4 stays as the embedded VM. Yesterday's `architecture_lua_54_thin_c_binding.md` lock is intact.
- ai-sim leaves and recipes (docs/05, docs/09) author surface stays the same shape; transpiler is upstream of leaf source.
