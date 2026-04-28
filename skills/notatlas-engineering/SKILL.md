---
name: notatlas-engineering
description: Engineering workflow for the notatlas Zig MMO codebase (waves, wind, buoyancy, Jolt FFI, Vulkan sandbox, and architecture-gated multiplayer planning). Use when tasks involve implementing or reviewing notatlas engine code, adding data-driven configs in `data/*.yaml`, extending physics/render/network subsystems, validating milestone gates, or ensuring changes conform to locked architecture decisions in docs/02-architecture.md.
---

# Notatlas Engineering

Use this skill to do implementation and review work in this repository while preserving locked architecture constraints and milestone-gate discipline.

## Workflow

1. Read scope-critical docs before coding:
- `docs/02-architecture.md`
- `docs/03-engine-subsystems.md`
- `docs/04-roadmap.md`
- `docs/07-anti-patterns.md`
- `docs/08-engineering-skill-base.md`

2. Locate affected modules:
- Core exports: `src/root.zig`
- Deterministic kernels: `src/wave_query.zig`, `src/wind_query.zig`
- Data loading: `src/yaml_loader.zig`
- Physics: `src/physics/*`
- Sandbox orchestration: `src/main.zig`
- Render stack: `src/render/*`

3. Apply non-negotiable invariants:
- Keep deterministic kernels pure and testable.
- Keep fixed-step simulation separate from render interpolation.
- Keep gameplay/content tuning in YAML or Lua, not hardcoded constants.
- Keep hot-reload failures non-fatal (log and continue with previous valid state).
- Preserve locked architecture decisions unless explicitly reopened.

4. Validate every meaningful change:
- Run `zig build test`.
- If render/physics path changed, run sandbox path for smoke validation.
- Add or update tests near edited module, especially for determinism and edge cases.

## Implementation Patterns

### Deterministic subsystem pattern

- Implement pure query API first.
- Add fixture presets in code.
- Add property tests (determinism, bounds, no-NaN).
- Add YAML loader parity tests against `data/`.

### YAML loader pattern

- Define a `Raw*` parse struct in source-field order.
- Convert into runtime struct with explicit ownership semantics.
- Provide deinit for owned slices.
- Add tests for schema parity and behavior parity.

### Jolt wrapper pattern

- Add C ABI in `jolt_c_api.h/.cpp`.
- Mirror extern signature in `src/physics/jolt.zig`.
- Add ergonomic wrapper method on `System` when appropriate.
- Maintain ABI/build flag parity with `build.zig` Jolt config.

## Stress-Gate Discipline

Before expanding gameplay scope, insist on milestone gate evidence:

- Buoyancy stability soak (no divergence).
- Replication/bandwidth synthetic tests before combat/content scaling.
- Harbor renderer load tests before dense-structure content scaling.

If a gate fails, prioritize fixing architecture/perf issues before adding content.

## References

For concise constraints and working checklists, read:

- `references/notatlas-constraints.md`
