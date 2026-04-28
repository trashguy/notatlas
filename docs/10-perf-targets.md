# Performance Targets & Budgets

This document defines **non-negotiable performance and bandwidth budgets** for Notatlas.

All systems must operate within these constraints to pass milestone gates.

Any deviation requires an ADR.

# Core Principles

- Performance is a **feature**, not a later optimization
- Budgets are **hard limits**, not guidelines
- All claims must be backed by **measured evidence**
- Scaling must be validated via **synthetic stress**, not assumption

# Server Simulation Budgets

## Tick Rates (LOCKED)

| System        | Tick Rate |
|---------------|----------|
| Player/Ship   | 60 Hz    |
| AI            | 20 Hz    |
| Environment   | 5 Hz     |

Violations → **P0**

## Frame Time Budget (Server)

Target per-tick execution time:

| System        | Budget per Tick |
|---------------|-----------------|
| 60Hz loop     | ≤ 16.6 ms total |
| 20Hz loop     | ≤ 5 ms avg      |
| 5Hz loop      | ≤ 2 ms avg      |

### Rules

- 60Hz loop must NEVER exceed 16.6ms sustained
- Spikes > 25ms must be rare and explained
- Headroom of at least 20% required under stress

Violations:
- Sustained over-budget → **P0**
- No headroom → **P1**

## Entity Scaling Targets

Baseline target:

- 1,000+ active entities per server instance

Stretch target:

- 5,000+ entities under stress conditions

### Requirements

- O(N) or better scaling per system
- No hidden quadratic behaviors

Violations:
- Unbounded scaling cost → **P0**
- No stress validation → **P1**

# Network Bandwidth Budgets

## Per-Client Budget

| Tier | Budget (avg) |
|------|--------------|
| T0   | ≤ 2 KB/s     |
| T1   | ≤ 5 KB/s     |
| T2   | ≤ 10 KB/s    |
| T3   | ≤ 5 KB/s     |
| TOTAL| ≤ 20 KB/s    |

## Burst Limits

- Short bursts allowed up to 2× budget
- Sustained overages > 3 seconds → violation

## Server Aggregate Budget

- Must scale linearly with player count
- No per-client hidden amplification

## Requirements

Every networked system must provide:

- Tier classification (T0–T3)
- Bytes/sec per entity or event
- Worst-case scenario estimate
- Before/after comparison (for changes)

Violations:
- Missing bandwidth accounting → **P1**
- Budget overrun → **P1 (P0 if severe)**

# Client Performance Targets

## Frame Rate

| Scenario              | Target |
|----------------------|--------|
| Typical gameplay     | 60 FPS |
| Heavy scene stress   | ≥ 30 FPS |

## Frame Time Budget

- Target: ≤ 16.6 ms
- Absolute max (spike): 33 ms

## CPU/GPU Split

- No single system > 30% of frame time
- Rendering must degrade gracefully under load

## Draw/Scene Complexity Targets

- Must support dense scenes (1000+ entities visible)
- Must include LOD or culling strategy

Violations:
- No stress test evidence → **P1**
- Frame collapse under load → **P1**

# Memory Budgets

## Server Memory

- Must remain bounded per entity
- Target: ≤ 2 KB per entity (baseline)

## Client Memory

- No unbounded growth over session
- Must survive 1+ hour soak without leak

## Requirements

- Memory usage must be measured
- Allocations per tick must be minimized
- No per-frame unbounded allocations

Violations:
- Memory leak → **P0**
- Unbounded growth → **P1**

# Determinism & Stability Targets

## Requirements

- No NaN or undefined values under stress
- Simulation must remain stable over long runs

## Soak Test Targets

- 1+ hour continuous simulation
- No divergence or crash
- Stable performance over time

Violations:
- NaN propagation → **P0**
- Instability under soak → **P1**

# Load & Stress Testing

## Mandatory Scenarios

All systems must be validated under:

- High entity counts (1000–5000)
- Network packet loss (1–5%)
- Latency simulation (50–200ms)
- Join/leave churn

## Evidence Requirements

- Profiling captures
- Metrics logs
- Before/after comparisons

Claims without evidence → **P1**

# Measurement Standards

## Acceptable Tools

- Built-in profilers
- Instrumented metrics
- Replay-based benchmarks

## Requirements

- Measurements must be reproducible
- Test conditions must be documented
- Results must include hardware context

# Regression Policy

Any change that:

- Increases CPU cost
- Increases bandwidth
- Reduces stability

Must include:

- Justification
- Mitigation plan
- Measured impact

Unjustified regression → **P1**

# Anti-Patterns (Performance)

## 1. Scaling by Hope

Assuming performance without stress validation

→ **P1**

## 2. Hidden O(N²)

Nested loops or implicit quadratic scaling

→ **P0**

## 3. Burst Masking

Short spikes ignored despite user impact

→ **P1**

## 4. Over-Replication

Sending excessive or redundant data

→ **P1**

## 5. Late Optimization

Deferring performance work past design phase

→ **P1**

# Validation Checklist

Every performance-sensitive change must answer:

- What is the CPU cost per tick?
- What is the bandwidth impact?
- How does it scale with entity count?
- Has it been tested under stress?
- Does it stay within defined budgets?

Missing answers → **P1**

# Enforcement Summary

| Violation Type                     | Severity |
|----------------------------------|----------|
| Tick rate violation               | P0       |
| Sustained frame budget breach     | P0       |
| NaN / simulation instability      | P0       |
| Memory leak                       | P0       |
| Quadratic scaling                 | P0       |
| Missing measurement evidence      | P1       |
| Budget overrun                    | P1       |
| No stress validation              | P1       |

# References

- `docs/09-replication-model.md`
- `docs/07-anti-patterns.md`
- `references/review-checklist.md`