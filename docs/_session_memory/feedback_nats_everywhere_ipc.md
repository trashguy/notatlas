---
name: NATS-everywhere IPC, separate processes over monolith
description: Preferred IPC strategy for notatlas. Locked 2026-04-29 after explicit pushback discussion on whether NATS was over-engineered for control/auth/persistence channels.
type: feedback
originSessionId: 2c054c14-15da-491e-a774-d272fe6bab4d
---
**Rule:** Default all inter-service communication to NATS, even where direct
gRPC / HTTP / shared-memory would be lower latency. Default to separate
service processes, even where in-process function calls would be cheaper.

**Why:** User considered the alternatives explicitly when reviewing the
Phase 1 architecture doc (`docs/08-phase1-architecture.md`). The conclusion:

- A second IPC mechanism (gRPC for sync, NATS for pub/sub) doubles the
  operational surface — two error-handling stories, two health models,
  two sets of auth/TLS config, two debugging paths. The marginal latency
  win on auth/persistence calls isn't worth the complexity tax.
- Running "big NATS" is easier than running a bunch of custom IPC + RPC
  stacks. The fallen-runes infra (resilience trio, NATS connect/sub
  patterns, observability) is already wired for NATS-as-universal-bus,
  and notatlas inherits that.
- Going the other direction — a single fat binary like Atlas — is
  rejected harder. Atlas's per-cell UE4 process owning physics + AI +
  replication + persistence is the explicit anti-pattern this project
  exists to avoid.

**How to apply:**

- When proposing service-to-service communication, default to a NATS
  subject pattern (req/reply, pub/sub, or JetStream consumer group as
  appropriate). Don't introduce gRPC, HTTP REST, raw TCP, shared memory,
  or in-process function calls between services without a load-bearing
  reason.
- When tempted to collapse two services into one process for "simplicity"
  (e.g. gateway-embedded cell-mgr), the answer is no. Service boundaries
  are kept as separate processes by default; collapsing requires explicit
  justification with measured profiling data.
- The 8-service decomposition in `02-architecture.md §service mesh` is
  the floor — services may be added if needed, not removed for tidiness.
- Acceptable exceptions to NATS-as-IPC: third-party tools that don't
  speak NATS natively (Postgres uses libpq; Prometheus scrapes HTTP;
  LiveKit uses WebRTC). Don't fight the ecosystem, but don't introduce
  new in-house IPC stacks either.

**Trade-off accepted:** NATS becomes a single-cluster bottleneck. If
the cluster dies, everything stops. Mitigation is operational
(3-node prod cluster with failover, NATS health treated as P0
monitoring), not architectural.
