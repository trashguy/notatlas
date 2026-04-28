# notatlas architecture review checklist

## Locked decision checks

- Tick rates and authority boundaries unchanged.
- Deterministic kernels remain deterministic for same `(params, x, z, t)`.
- NATS subject naming follows locked scheme.
- Cell ownership model not regressed to state-owning cells.
- Replication tier semantics preserved.

## Testing checks

- Unit tests exist for changed deterministic math.
- Edge-case tests include bounds, wrap behavior, and no-NaN guarantees.
- Integration/soak evidence exists when touching physics loops.
- Synthetic scale tests are required before feature expansion across gates.

## Performance checks

- Change includes perf impact statement or metrics path.
- No obvious per-frame O(N^2) growth in hot paths.
- Render or network budget impact identified where relevant.

## Data-driven checks

- Tuning constants externalized where practical.
- Loader paths and ownership/deinit patterns are correct.
- Config schema changes have validation/test coverage.

## Reporting checks

- Findings list starts with highest severity.
- Every finding includes: risk, why it matters, and concrete fix direction.
- Explicitly state if no findings were discovered and mention residual risks.
