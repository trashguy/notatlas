# Replication Model (4-Tier)

This document defines the **authoritative 4-tier replication architecture** for Notatlas.

This model is **LOCKED**. Any deviation requires an ADR (Architecture Decision Record).

# Goals

- Maintain scalability under high entity counts
- Bound bandwidth and CPU costs deterministically
- Preserve simulation correctness where required
- Prevent cross-system coupling and hidden state paths

# Overview

All replicated data MUST belong to exactly one of four tiers:

| Tier | Name                  | Purpose                          | Reliability | Frequency |
|------|----------------------|----------------------------------|-------------|-----------|
| T0   | Authority            | Ground truth state               | Reliable    | Fixed tick |
| T1   | Simulation Delta     | Deterministic inputs/deltas      | Unreliable  | Fixed tick |
| T2   | State Snapshot       | Client correction / recovery     | Reliable    | Low rate  |
| T3   | Presentation         | Visual-only, non-gameplay data   | Unreliable  | Variable  |

No data may exist outside this model.

# T0 — Authority Tier

## Definition

Authoritative state required to resolve gameplay.

## Examples

- Player inputs (validated)
- Ship authoritative transforms
- Combat results (damage, hits)
- Ownership state

## Rules

- Server authoritative ONLY
- Must be deterministic or reconciled
- Must never depend on T3 data
- Must not be derived from client visuals

## Frequency

- 60Hz for player/ship systems
- 20Hz for AI
- 5Hz for environment (if applicable)

## Violations

- Client authority → **P0**
- Visual-derived logic → **P0**

# T1 — Simulation Delta Tier

## Definition

Minimal data required to advance deterministic simulation.

## Examples

- Wave parameters
- Wind vectors
- Projectile initial states
- AI decision outputs (if deterministic)

## Rules

- Must be sufficient for deterministic replay
- Must NOT include redundant state
- Must NOT include presentation data
- Must be bandwidth-minimized

## Determinism Requirement

- Given identical T1 input stream → identical results

## Violations

- Missing inputs causing divergence → **P0**
- Redundant state inflation → **P1**

# T2 — Snapshot Tier

## Definition

Periodic correction layer for clients.

## Purpose

- Correct drift
- Late join synchronization
- Recovery from packet loss

## Examples

- Entity transforms
- Health/state snapshots
- World state checkpoints

## Rules

- Must be derived from T0 state
- Must NOT introduce new gameplay data
- Must be compressible and bounded in size
- Must be rate-limited

## Frequency

- Low frequency (e.g., 1–5 Hz depending on system)

## Violations

- Snapshot used as primary state → **P0**
- Unbounded size growth → **P1**

# T3 — Presentation Tier

## Definition

Non-gameplay, visual-only data.

## Examples

- Particle effects
- Audio triggers
- Cosmetic animations
- UI state

## Rules

- Must NOT affect gameplay outcomes
- Must tolerate loss
- Must NOT feed back into simulation
- Can be client-generated where possible

## Violations

- Gameplay dependency on T3 → **P0**

# Cross-Tier Rules

## Strict Separation

- T3 → T0/T1/T2 dependency is forbidden
- T2 must not introduce new state not present in T0
- T1 must not duplicate T2 snapshots
- T0 must not depend on T3 signals

## Allowed Flow

Reverse or lateral flows are violations.

# Bandwidth Budgeting

All tiers must operate within limits defined in:

- `docs/perf-targets.md`

## Requirements

- Each system must declare:
  - Tier assignment
  - Expected bandwidth usage
- Changes must include before/after comparison

## Violations

- No bandwidth accounting → **P1**
- Budget overrun without mitigation → **P1**

# Interest Management (Cells)

## Role of Cells

Cells (`env.cell.<x>_<y>`) act as:

- Subscription filters
- Relevance boundaries

## Rules

- Cells MUST NOT own gameplay state
- Cells MUST NOT store authoritative data
- Cells ONLY control visibility/replication scope

## Violations

- State stored in cells → **P0**

# Late Join & Recovery

## Requirements

- T2 snapshots must fully reconstruct visible state
- T1 stream must resume deterministically after snapshot
- No hidden dependencies on historical data

## Violations

- Incomplete reconstruction → **P1**
- Hidden state dependencies → **P1**

# Determinism Contract

For deterministic systems:

- T1 inputs define full simulation
- T2 only corrects drift, not logic
- No randomness without seeded control
- No frame-rate dependent logic

## Testing Requirements

- Replay validation
- State hash comparison
- Soak test stability

# Anti-Patterns (Replication)

The following are explicitly forbidden:

## 1. Snapshot-as-Truth

Using T2 as primary state instead of correction layer.

→ Leads to bandwidth explosion and desync risk

## 2. Hidden State Channels

State passed outside defined tiers (e.g., RPC shortcuts)

→ Breaks determinism and observability

## 3. Tier Bleed

Mixing responsibilities across tiers

→ Causes scaling and debugging failures

## 4. Over-Replication

Sending full state where deltas suffice

→ Violates bandwidth constraints

## 5. Client-Side Authority Drift

Letting client state influence T0 decisions

→ Immediate correctness failure

# Validation Checklist

Every replication change MUST answer:

- What tier does this belong to?
- Why is this tier correct?
- What is the bandwidth cost?
- Is it deterministic (if required)?
- How is it tested under loss/latency?

Missing answers → **P1**

# Enforcement Summary

| Violation Type                      | Severity |
|-----------------------------------|----------|
| Architecture deviation (no ADR)    | P0       |
| Cross-tier violation               | P0       |
| Determinism break                  | P0       |
| Snapshot misuse                    | P0       |
| Missing bandwidth accounting       | P1       |
| Unbounded growth                   | P1       |
| Test coverage gaps                 | P1       |

# References

- `docs/10-perf-targets.md`
- `docs/07-anti-patterns.md`
- `references/review-checklist.md`