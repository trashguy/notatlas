---
name: No audit mirror streams — PG is the audit boundary
description: Audit mirrors were over-engineered; PG row IS the durable audit record. Real-time analytics consume core NATS, not replay streams. Don't re-add audit mirrors without a load-bearing reason.
type: feedback
originSessionId: 9faac8f3-1919-4d81-aa68-07970ec6fc44
---
We do NOT declare `audit_*` mirror streams alongside the workqueue
event streams. Removed in `??????`.

**Why:**

The audit-mirror pattern (workqueue source → mirror with limits
retention) was meant to preserve event history after workqueue
ack-removal. In practice it's redundant infrastructure.

For every stream pwriter consumes, **the PG row IS the audit**:
- `events_market_trade` → `market_trades` row, indexed, queryable
- `events_handoff_cell` → `cell_handoffs` row, indexed, queryable
- `events_inventory_change` → `inventories` row (latest blob —
  intermediate snapshots have no replay value)
- `events_session` → `sessions` row (incoming with the SLA work)

A SQL query on these tables gives every property "audit replay"
would: ordering by cycle/timestamp, per-entity filtering, stable
sequence ids (with `stream_seq` dedup once that lands).

**Real-time analytics still works** without mirrors. New consumers
subscribe to core NATS (`sim.entity.*.damage`,
`events.market.trade`, etc.) — best-effort delivery is correct for
fraud/anomaly detection because the signal repeats. Replay-from-NATS
isn't the right tool for this.

**Disk impact when restored:**

The audit mirrors at 30-day retention would have hit ~8–28 TB at
production scale, dominated by inventory at ~1.5–2 KB/msg × 5k/sec
× 30 d. Math is in the conversation history that drove the removal.

**Don't re-add unless:**

A real consumer arrives that genuinely needs replay-of-event-stream
semantics that PG SQL can't provide. Examples that *don't* qualify:
"future analytics service" (use SQL), "compliance archive" (back up
PG), "kill feed UI" (gateway state or short-window NATS sub).
Examples that *might* qualify: a tournament dispute system that
requires byte-for-byte event replay with original NATS ordering.
Even then, it's better implemented as the optional capture pattern
in `architecture_damage_not_in_pg.md` — one stream, bounded
retention, off by default.

**Files removed in this cleanup:**
- `ensureAuditMirror`, `audit_stream_prefix`, `audit_max_age_ns`
  from `src/services/persistence_writer/main.zig`
- `scripts/persistence_audit_smoke.sh`
