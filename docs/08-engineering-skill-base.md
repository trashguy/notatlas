# 08 — Engineering Skill Base

This document is the working skill base for contributors and coding agents.
It consolidates architecture constraints, implementation patterns, and execution playbooks based on the current repository state.

Last updated: 2026-04-28

## 1. Reality check: current repo state

This repo is not purely planning anymore. It already contains:

- Zig build + test harness (`build.zig`, `src/root.zig`)
- Deterministic wave kernel + tests (`src/wave_query.zig`)
- Deterministic wind field + tests (`src/wind_query.zig`)
- YAML loaders for waves/ocean/hull/wind (`src/yaml_loader.zig`)
- Jolt integration via C wrapper (`src/physics/jolt.zig`, `src/physics/jolt_c_api.*`)
- Buoyancy system (`src/physics/buoyancy.zig`)
- Vulkan sandbox renderer and hot-reload loop (`src/main.zig`, `src/render/*`)
- Data presets in `data/` and shaders in `assets/shaders/`

Practical phase interpretation:

- Phase 0 milestones M1–M5 are materially underway in-engine.
- Doc architecture in `docs/02-architecture.md` remains the decision source for multiplayer/service work.

## 2. Locked constraints (do not relitigate)

When implementing features, preserve these constraints unless explicitly reopened:

- 60Hz authoritative ship/player sim, 20Hz AI, 5Hz env.
- Hybrid determinism: deterministic waves/wind/projectiles; auth+interp for rigid bodies/players.
- Jolt physics via Zig FFI.
- NATS subject model:
  - `sim.entity.<id>.*` for mobile entities
  - `env.cell.<x>_<y>.*` for environmental/cell state
- Cells are interest managers, not state owners.
- Pose compression target ~16B.
- 4-tier replication model (always / visual / close-combat / boarded).
- LiveKit voice off gameplay path.
- Harbor performance and naval-scale stress gates before content expansion.

Primary references:

- `docs/02-architecture.md`
- `docs/03-engine-subsystems.md`
- `docs/04-roadmap.md`
- `docs/07-anti-patterns.md`

## 3. Codebase skill map

### 3.1 Core module surface

- `src/root.zig` exports:
  - `math`
  - `wave_query`
  - `wind_query`
  - `ocean_params`
  - `hull_params`
  - `player`
  - `yaml_loader`

Skill rule:

- Add reusable engine-level logic behind `src/root.zig` exports.
- Keep sandbox-only orchestration in `src/main.zig`.

### 3.2 Build system and dependencies

- `build.zig` currently builds:
  - `notatlas` static library
  - tests for `notatlas` module
  - vendored Jolt static lib (including wrapper)
  - sandbox executable `notatlas-sandbox`
- Shader compile path:
  - Embedded compile at build-time via `glslc`
  - Runtime hot-reload compile path in sandbox for edited shaders

Skill rule:

- Treat `build.zig` as production infra.
- Preserve C++ flags/ABI definitions parity with Jolt build assumptions.

### 3.3 Data model and loaders

Current data files used directly:

- `data/waves/*.yaml`
- `data/ocean.yaml`
- `data/ships/box.yaml`
- `data/wind.yaml`

Loader contract (`src/yaml_loader.zig`):

- Parse YAML into raw structs in source declaration order.
- Convert raw structs to runtime params.
- Own heap slices for dynamic arrays (`storms`, `sample_points`) and provide explicit deinit paths.

Skill rule:

- Every new YAML-backed subsystem should copy this pattern:
  1. `RawX` parse struct
  2. `fromRawX` transformer
  3. `loadXFromFile` + optional `loadXFromYaml`
  4. fixture parity tests

### 3.4 Deterministic kernels

#### Wave kernel (`src/wave_query.zig`)

- Deterministic function of `(params, x, z, t)`.
- Normal computed via finite-difference sampling against same height fn.
- Includes deterministic sweeps and property tests.

#### Wind kernel (`src/wind_query.zig`)

- Global base wind + per-storm toroidal cell contributions.
- Deterministic hash-based per-cell derived properties.
- `stormCenter` exposed as stable query API.
- Includes broad invariants (determinism, bounds, no NaN, drift behavior).

Skill rule:

- Keep kernels pure, side-effect free, and data-in/data-out.
- Add tests for numerical stability and deterministic replay before integration.

### 3.5 Physics layer

- `src/physics/jolt.zig`: clean wrapper over raw C ABI.
- `src/physics/buoyancy.zig`: per-sample buoyancy + drag force accumulation.

Skill rule:

- Engine-level force systems should consume wrappers (`System`, `BodyId`) not raw extern calls.
- Per-tick sim logic must be safe under fixed-step accumulation and not assume render frame rate.

### 3.6 Sandbox orchestration

`src/main.zig` currently demonstrates:

- Fixed-step physics loop at 60Hz
- interpolation for render pose
- player/passenger composition on moving ship
- data + shader hot reload
- soak/perf instrumentation

Skill rule:

- Use sandbox as milestone proving ground.
- Don’t leak sandbox-specific assumptions into reusable modules.

## 4. Working invariants (must hold)

- Client and server evaluating same deterministic kernel inputs must produce matching outputs within expected float tolerance.
- Physics is stepped at fixed dt; render interpolates between snapshots.
- Hot-reload failures should degrade gracefully (log + keep running old data).
- New subsystem data should be externally tunable through YAML/Lua, not hardcoded constants.
- Any architecture evolution must preserve Pillar 1 and Pillar 2 stress-gate viability.

## 5. Implementation playbooks

### Playbook A — Add a new deterministic simulation kernel

1. Create `src/<kernel>.zig` with pure API.
2. Add default/preset fixtures in code for non-file fallback and tests.
3. Add deterministic sweeps and invariants in unit tests.
4. Add YAML loader shapes in `src/yaml_loader.zig` or dedicated loader module.
5. Wire exports through `src/root.zig`.
6. Integrate only after tests pass.

Definition of done:

- Determinism tests pass repeatedly.
- No-NaN/edge-range tests pass.
- Loader fixture parity test passes against `data/`.

### Playbook B — Add a data-backed ship/environment parameter set

1. Define schema in `data/...`.
2. Add `Raw*` parse struct in loader.
3. Convert into runtime struct with explicit ownership semantics.
4. Add deinit path if dynamic memory exists.
5. Add tests for:
   - field parity
   - representative behavior parity

Definition of done:

- Hot-reload path can accept the data without restart (unless explicitly documented as restart-required).

### Playbook C — Extend Jolt wrapper safely

1. Add function to `jolt_c_api.h/.cpp`.
2. Mirror extern signature in `src/physics/jolt.zig`.
3. Add idiomatic wrapper method in `System` when appropriate.
4. Validate ABI assumptions preserved by build flags.

Definition of done:

- wrapper compiles in Debug/Release
- sandbox or tests exercise new path without invalid handles

### Playbook D — Add replication/protocol primitives (Phase 1+)

1. Define mechanism in code first, thresholds in data.
2. Keep subject naming compliant with architecture doc.
3. Build synthetic load tests before gameplay features.
4. Add observability counters from day one.

Definition of done:

- milestone stress test passes target budgets before content coupling.

## 6. Testing skill base

Current test entrypoint:

- `zig build test`

Recommended near-term additions:

- dedicated integration test target for wave+buoyancy long-duration stability
- deterministic replay test fixture for wind storms over fixed seeds
- shader compile smoke test in CI for all `assets/shaders/*`

Test quality checklist:

- property tests over random samples
- known-edge tests (0 iterations, zero storms, wrap boundaries)
- regression tests for historical bug classes (NaN, wrap teleports, damping explosions)

## 7. Performance and profiling skill base

Performance priorities:

1. Sim tick stability (60Hz)
2. Replication bandwidth envelope
3. Harbor rendering frame budget

Current instrumentation strengths:

- Soak stats for physics and passenger composition
- 1Hz frame perf logging window

Recommended next instrumentation:

- per-subsystem tick timings in fixed-step loop
- event counters for hot-reload success/failure
- serialized perf snapshots for milestone gate comparisons

## 8. Data and schema conventions

- Favor YAML for structured static data.
- Keep field names explicit and unit-bearing (`*_m`, `*_mps`, `*_rad`, `*_s`).
- Avoid hidden defaults for gameplay-significant fields.
- Add comments in data files for operator-facing tunables.

Naming conventions:

- `*_params.zig` for data structs/config bundles
- `*_query.zig` for deterministic sampling/query functions
- `*_loader` behavior centralized in `yaml_loader` unless subsystem complexity justifies split

## 9. Architectural risk watchlist

Track these as active risks during implementation:

- Determinism drift between CPU and GPU implementations
- Fixed-step starvation under frame stalls
- Hot-reload invalid states causing silent behavior divergence
- Growing sandbox orchestration complexity reducing module clarity
- Early feature creep that bypasses stress gates

Mitigation defaults:

- Add deterministic parity tests before extending features.
- Add explicit logs and counters around fallback/error paths.
- Keep milestone gate criteria objective and scriptable.

## 10. Contributor workflow skill base

Before coding:

1. Read relevant docs in `docs/` based on subsystem.
2. Identify locked decisions touched by the change.
3. Define measurable gate for the change.

During coding:

1. Keep reusable logic in `src/` modules, not in `main.zig`.
2. Add/extend tests in same PR.
3. Preserve data-driven knobs.

Before merge:

1. Run tests.
2. Run sandbox path if render/physics touched.
3. Validate no architecture decision violations.
4. Capture notes for milestone gate deltas.

## 11. Suggested next high-leverage docs

To extend this skill base further, add:

- `docs/09-testing-strategy.md` (gate-driven test matrix)
- `docs/10-observability.md` (metrics/events/log schema)
- `docs/11-network-protocol.md` (pose packet, event payload schemas)
- `docs/12-runtime-config.md` (hot-reloadability and restart-required matrix)

## 12. Quick reference

Key files:

- `build.zig`
- `src/main.zig`
- `src/root.zig`
- `src/wave_query.zig`
- `src/wind_query.zig`
- `src/yaml_loader.zig`
- `src/physics/jolt.zig`
- `src/physics/buoyancy.zig`
- `docs/02-architecture.md`
- `docs/03-engine-subsystems.md`
- `docs/04-roadmap.md`
- `docs/07-anti-patterns.md`

Core principle:

- Prove scale-critical architecture with synthetic gates first; only then expand content.

## 13. Skill usage in PR flow

Use the two project skills in this order:

1. `notatlas-engineering`
- Use during implementation and refactors.
- Goal: keep code aligned with locked architecture and data-driven patterns while adding tests.

2. `notatlas-architecture-review`
- Use before merge (or when requesting review).
- Goal: findings-first audit for architecture compliance, stress-gate readiness, and scale/perf risk.

Recommended PR sequence:

1. Implement with `notatlas-engineering`.
2. Run tests and relevant sandbox smoke checks.
3. Review with `notatlas-architecture-review` and address findings.
4. Re-run validation and finalize.
