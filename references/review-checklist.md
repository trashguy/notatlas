# Review Checklist (Enforcement)

This checklist is **mandatory** for all architecture reviews.

It is designed to:

- Prevent silent architecture drift
- Enforce determinism and replication integrity
- Ensure performance and scale readiness
- Eliminate subjective “looks fine” approvals

If any required item cannot be answered with evidence → escalate.

# How to Use

- Walk through each section in order
- Mark each item as:
  - ✅ Pass (with evidence)
  - ❌ Fail (with reason)
  - ⚠️ Unknown (treated as FAIL unless justified)

- Unknown or missing evidence defaults to **P1**

# 1. Scope & Change Clarity

- What files/systems are affected?
- What behavior is changing?
- What tier(s) of replication are impacted (T0–T3)?

## Checks

- Clear description of change exists → required
- Replication tier assignment provided → required

❌ Missing clarity → P1

# 2. Locked Architecture Compliance

## Tick Model

- 60Hz player/ship preserved?
- 20Hz AI preserved?
- 5Hz environment preserved?

## Determinism Split

- Deterministic systems unchanged?
- No deterministic → authoritative leakage?

## Subject Model

- Uses EXACT:
  - `sim.entity.<id>.*`
  - `env.cell.<x>_<y>.*`

## Cells

- Cells used ONLY for interest management?
- No state stored in cells?

## Replication Model

- Matches 4-tier model exactly?
- No new implicit tiers introduced?

## ADR Check

- Any deviation includes ADR reference?

❌ Violations:
- No ADR for deviation → P0
- Structural drift → P0/P1

# 3. Replication Integrity

- What tier is each piece of data in?
- Why is that tier correct?

## Checks

- No cross-tier leakage?
- No T3 → gameplay dependency?
- No snapshot (T2) used as primary state?
- T1 contains only required deterministic inputs?

## Bandwidth

- Bytes/sec estimated?
- Within `docs/10-perf-targets.md`?

❌ Violations:
- Cross-tier violation → P0
- Missing bandwidth accounting → P1

# 4. Determinism & Simulation

(Only applies to deterministic systems)

## Required Evidence

- Replay test exists?
- State hash/checksum validated?
- No NaN under stress?
- No frame-rate dependent logic?

## Questions

- Can this system diverge across runs?
- Does it depend on non-deterministic input?

❌ Violations:
- No determinism proof → P1
- Divergence risk → P0

# 5. Performance & Scaling

## CPU

- Cost per tick measured?
- Within budget?

## Scaling

- Behavior at 1k+ entities tested?
- Any O(N²) patterns?

## Network

- Bandwidth impact measured?
- Within per-client budget?

## Client

- Frame-time impact measured?
- Dense scene tested?

❌ Violations:
- No measurement → P1
- Budget exceed → P1/P0
- Quadratic scaling → P0

# 6. Stress & Soak Validation

## Required Scenarios

- High entity count (1000+)
- Packet loss (1–5%)
- Latency (50–200ms)
- Join/leave churn

## Checks

- Evidence provided (logs, captures)?
- Stable over time?

❌ Violations:
- No stress validation → P1
- Instability → P1/P0

# 7. Data-Driven Compliance

## Checks

- Are tuning values externalized?
- Stored in `data/*.yaml` or Lua?

- Loader exists?
- Test coverage exists?

## Questions

- Can designers retune without code change?
- Are there hidden constants?

❌ Violations:
- Hardcoded tuning → P2
- Missing loader/test → P2

# 8. Anti-Pattern Scan

Reference: `docs/07-anti-patterns.md`

## Required

If any pattern matches, reviewer MUST document:

1. Pattern name
2. Why it matches
3. Risk if ignored

## Common Checks

- Architecture bypass?
- Scaling by hope?
- Hidden coupling?
- Over-replication?

❌ Violations:
- Ignored anti-pattern → P1

# 9. Testing & Evidence Quality

## Checks

- Tests are reproducible?
- Conditions documented?
- Before/after comparison exists?

## Questions

- Could another engineer reproduce this result?
- Are results environment-specific?

❌ Violations:
- Non-reproducible evidence → P1
- Missing comparison → P1

# 10. Regression Risk

## Checks

- CPU cost increased?
- Bandwidth increased?
- Complexity increased?

## Required

- Justification provided?
- Mitigation plan included?

❌ Violations:
- Unjustified regression → P1

# 11. Final Gate Questions

Reviewer must explicitly answer:

- Is this safe at scale?
- Is this deterministic (if required)?
- Is this within budget?
- Does this preserve architecture integrity?

If any answer is uncertain → **FAIL**

# Failure Rules

- Any P0 → automatic rejection
- Multiple P1s → reject or require fixes before merge
- Unknowns without justification → treated as P1

# Reviewer Principles

- Evidence > opinion
- Clarity > assumption
- Rejection is cheaper than rollback
- Enforce systems, not intent

# Quick Pass Criteria

A change may pass ONLY if:

- No P0 issues
- All P1 issues resolved or justified
- Evidence exists for:
  - Determinism (if applicable)
  - Performance
  - Replication correctness

# References

- `docs/09-replication-model.md`
- `docs/10-perf-targets.md`
- `docs/07-anti-patterns.md`