---
name: notatlas-architecture-review
description: Strict architecture and performance-gate review workflow for the notatlas project. Enforces locked architecture decisions, determinism guarantees, replication model integrity, stress-gate discipline, and anti-pattern avoidance with zero tolerance for silent drift.
---

# Notatlas Architecture Review

Use this skill when the user asks for a review, audit, risk check, or readiness assessment.

## Review Mode

1. Report findings first, ordered by severity.
2. Focus on regressions, architecture violations, scale risks, and missing tests.
3. Include concrete file references and specific remediation guidance.
4. Keep summaries brief and secondary.
5. Do not assume intent — evaluate only observable behavior and evidence.

## Severity Model

- P0: Immediate blocker. Violates locked architecture, determinism guarantees, replication model, or safety/performance invariants.
- P1: High-risk defect. Likely to fail milestone gate or cause major instability at scale.
- P2: Important weakness. Degrades maintainability, scalability, or tuning ability over time.
- P3: Minor issue. Documentation, clarity, or consistency concern.

## Mandatory Architecture Checks

### Locked Decisions (Zero Drift Policy)

The following decisions are LOCKED and cannot be changed without an explicit ADR (Architecture Decision Record):

- Tick model:  
  - 60Hz: authoritative player/ship  
  - 20Hz: AI  
  - 5Hz: environment  

- Determinism split:  
  - Deterministic: waves, wind, projectiles  
  - Authoritative/interpolated: rigid bodies, players  

- Subject model:  
  - `sim.entity.<id>.*` (mobile entities)  
  - `env.cell.<x>_<y>.*` (environment state)  

- Cells act as **interest managers only**, never state owners.

- 4-tier replication model must remain intact (see `docs/09-replication-model.md`).

- Voice systems must remain completely off the gameplay path.

### Enforcement Rules

- Any deviation from the above requires a referenced ADR ID.
- Missing ADR reference → **automatic P0**.
- Partial compliance or “temporary exception” → **P0**.

### Subject Model Integrity (Strict)

- Subject namespaces must match EXACTLY:
  - `sim.entity.<id>.*`
  - `env.cell.<x>_<y>.*`

- The following are violations:
  - Prefix changes (`sim.entities`, `env.cells`)
  - Structural changes (`entity.sim.*`)
  - Mixed or dual ownership models

Violations → **P1 (or P0 if systemic)**

### Replication Model Enforcement

All changes must preserve the 4-tier replication architecture as defined in:
- `docs/09-replication-model.md`

### Requirements

- Clear mapping of data to replication tier
- No cross-tier leakage or shortcut paths
- Bandwidth impact must be quantified against `docs/10-perf-targets.md`

Missing mapping or unclear tier assignment → **P1**

### Determinism Enforcement

Systems marked deterministic must include **proof**, not claims.

### Required Evidence

- Replay test demonstrating identical outcomes across runs
- State hash/checksum comparison across ticks
- Cross-platform or multi-run consistency validation
- No NaN/undefined propagation under stress

### Tolerance

- Floating-point deviation must remain within defined epsilon (if unspecified → must be justified)

Missing or incomplete determinism proof → **P1**

## Stress-Gate Readiness Checks

Any subsystem change must provide evidence for milestone progression.

### Required Evidence (as applicable)

- Determinism test coverage and replay validation
- Fixed-step stability under soak conditions
- Bandwidth measurements vs targets in `docs/10-perf-targets.md`
- CPU/frame-time measurements for dense scenarios
- No-NaN / no-divergence validation

### Enforcement

- Claims without numeric evidence → **P1**
- Missing stress validation for scale-sensitive systems → **P1**

## Data-Driven Compliance

### Requirements

The following MUST be data-driven (YAML/Lua):

- Gameplay tuning values
- AI thresholds, timers, and behaviors
- Environmental parameters

### Rules

- Config must live in `data/*.yaml` or approved scripting layer
- Loader and test parity must exist
- Values must be reloadable or wipe-adjustable

### Violations

- Hardcoded tuning values → **P2**
- Hidden constants blocking iteration → **P2**
- Missing loader/test coverage → **P2**

## Anti-Pattern Guard

Cross-check all changes against:
- `docs/07-anti-patterns.md`

### Enforcement

If a match is suspected, the review MUST include:

1. The specific anti-pattern name
2. Why this change matches it
3. The concrete risk if left unaddressed

### Common Critical Patterns

- Architecture bypasses recreating Atlas-style coupling
- Scaling-by-hope (no synthetic stress validation)
- Gameplay rules reintroducing known churn drivers

Unjustified or ignored anti-pattern match → **P1**

## Performance & Budget Enforcement

All performance-sensitive changes must reference:

- `docs/10-perf-targets.md`

### Requirements

- Explicit numeric comparison against budget
- Clear measurement method (profiling, test scenario, etc.)

### Violations

- No numeric targets → **P1**
- Vague “should be fine” claims → **P1**

## Output Template

Use this structure strictly:

1. Findings (ordered by severity)
2. Open questions / assumptions
3. Gate readiness summary
4. Short change summary
5. Confidence level (High / Medium / Low)

## Review Principles

- No assumption of correctness without evidence
- No acceptance of “temporary” architectural violations
- Prefer rejection over silent risk accumulation
- Enforce consistency over convenience

## References

- `references/review-checklist.md`
- `docs/09-replication-model.md`
- `docs/10-perf-targets.md`
- `docs/07-anti-patterns.md`
