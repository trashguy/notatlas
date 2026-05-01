---
name: Damage events deliberately NOT in PG
description: damage_log was over-engineered. Live damage stays on core NATS; aggregates roll up via stats-sim. Optional forensic JetStream capture is broker-level config, default off. Don't re-add a row-per-event PG table.
type: feedback
originSessionId: 9faac8f3-1919-4d81-aa68-07970ec6fc44
---
We do NOT persist damage events to PG. They flow on
`sim.entity.*.damage` core NATS, ephemeral. Removed in `??????` along
with the audit mirror infrastructure.

**Why:**

1. **Volume.** ~5,000 events/sec/world peak × 70-day cycle = ~30B
   rows. PG would need partitioning + archival just to hold one wipe.
2. **No row-level read use case.** Live HP comes from the 60 Hz
   `sim.entity.*.state` firehose. Kill-feed UI is gateway-level.
   Cross-cycle queries don't matter (wipes invalidate). The only
   useful queries are aggregates (kill counts, leaderboards).
3. **Architecture decision 5 says JetStream KV, not PG.** Quote from
   `docs/02-architecture.md` §5: "Damage / event log | JetStream KV
   with TTL → wipe | Per event". The `damage_log` table I'd added
   was drift from that spec.
4. **Anomaly detection wants real-time, not replay.** A future
   `anomaly-sim` subscribes to the live subject and flags exploits
   as they happen — best-effort delivery is correct (you'll catch
   the next exploit if you miss this one).

**The right shape going forward:**

- `ship-sim` publishes `sim.entity.*.damage` (already does)
- Future `stats-sim`: subscribes core NATS, maintains JetStream KV
  bucket with per-player cycle stats (total damage, kills, deaths),
  rolls up periodically into a small `damage_aggregates` PG table
  (one row per player per cycle, kilobytes total)
- Future `anomaly-sim`: subscribes core NATS, flags impossible
  damage values, writes findings to a separate `damage_anomalies`
  table

**Optional forensic capture:**

For one-off needs (tournament audit, exploit investigation, dispute
resolution), enable a broker-level JetStream stream that captures
`sim.entity.*.damage` with bounded retention. Config lives in
`data/jetstream.yaml` (entry: `damage_forensic`, default disabled).
Apply with `./scripts/apply_jetstream.sh`. Caps default to 24 h /
10 GB so accidentally leaving it on can't fill the disk.

**How to apply (don't reinvent):**

- Don't add an `events_damage` workqueue stream to pwriter.
- Don't add a `damage_log` table to `infra/db/init.sql`.
- If "we need damage in PG" comes up: the answer is "build the
  aggregates table in stats-sim" or "enable the forensic capture
  YAML toggle for the duration of the question."
- The architecture is intentional, not an oversight. Don't relitigate
  without surfacing the math from this memory.
