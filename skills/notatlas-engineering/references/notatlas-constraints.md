# notatlas constraints quick reference

## Locked architecture highlights

- Tick rates: 60Hz player/ship, 20Hz AI, 5Hz env.
- Determinism model: waves/wind/projectiles deterministic; rigid body and characters authoritative+interpolated.
- Physics: Jolt via Zig FFI.
- Subject model:
  - `sim.entity.<id>.*` for mobile entities
  - `env.cell.<x>_<y>.*` for cell/environment state
- Cells are interest managers, not state owners.
- Replication tiers: always / visual / close-combat / boarded.
- Voice transport stays off gameplay path.

## Repository implementation reality (2026-04-28)

- Active wave and wind deterministic kernels with tests.
- YAML loaders for wave/ocean/hull/wind configs.
- Jolt wrapper + buoyancy subsystem in use.
- Vulkan sandbox with hot reload and soak/perf instrumentation.

## Code guardrails

- Keep reusable engine logic out of `src/main.zig`.
- Keep data-driven tuning in `data/` with loader/test parity.
- Add deterministic and edge-case tests when touching kernels.
- Preserve fixed-step sim + render interpolation split.

## Gate-first mindset

- Pass subsystem stress gates before adding content complexity.
- If perf or replication budgets fail, stop and fix substrate first.
