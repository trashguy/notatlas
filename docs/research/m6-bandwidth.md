# M6.5 — cell-mgr fanout bandwidth measurement

**Date:** 2026-04-29
**Source:** `src/services/cell_mgr/fanout.zig` test `M6.5 BW: idle / mid / hot scenarios + distance sweep`. Reproduce with `zig build test`.

## Why

Per docs/08 §6 M6.5: confirm per-subscriber payload sizes are within the per-client BW budget under the M6.4 synthetic load, and that they scale predictably with distance (= tier escalation). Numbers are placeholder — M7 swaps the 20 B record for the 16 B compressed pose codec — but the relative scaling stays valid and the absolute peak gives us a comfortable headroom estimate today.

## Budget

- **Per-client downstream cap:** ≤1 Mbps = **125 000 B/s** (per docs/01 §1, docs/02 §9).
- **Tier rates** (from docs/02 §9 / docs/08 §3.2):
  | Tier | Range | Rate |
  |---|---|---|
  | 0 always | any | 30 Hz |
  | 0.5 fleet aggregate | <2000 m | 5 Hz, per-cluster |
  | 1 visual | <500 m | 60 Hz pose |
  | 2 close combat | <150 m | on-change |
  | 3 boarded | same ship | on-change |
- **M6 simplification:** fanout is uniform 30 Hz for all tiers. Per-tier rate gating is M7 work — these numbers undercount tier 1 (60 Hz post-M7) and overcount fleet aggregate (5 Hz post-M7).
- **Layer scope:** all numbers are application-layer payload bytes. NATS framing (`PUB <subj> <len>\r\n` ≈ 20–30 B/msg) and TCP/IP headers are below the measurement; they don't change the relative scaling.

## Wire shape

**As of slow-lane cleanup** (post-cleanup):

```
PayloadHeader      = { u32 entity_count, u32 cluster_count }     ( 8 B)
ClusterRecord[cc]  = { f32 centroid_x, f32 centroid_z,           (16 B)
                       f32 radius_m, u16 heading_deg,
                       u8 count, u8 silhouette_mask }
```

The slow-lane is now **clusters-only**: `entity_count` is always 0.
Visual+ entity updates flow via the fast-lane callback path (cell-
mgr's `sim.entity.*.state` subscription → `Fanout.relayState`),
emitting a `PayloadHeader { entity_count = 1, cluster_count = 0 } +
1 EntityRecord` per state-msg per visual+ subscriber.

The wire shape keeps `entity_count` as a non-zero field so tier-0
content that doesn't naturally fit into a cluster summary (e.g.
named landmarks, instanced beacons) can be reintroduced later
without a wire-version flip.

**Cluster pathway** (unchanged from previous milestone except the
centroid filter):

- Cell-mgr runs the M6.1 `buildClusters` pass at 5 Hz over the
  current entity table (using a per-cell arena that retains capacity
  between passes — no steady-state allocs).
- Per-subscriber, each cluster is filtered by centroid distance:
  include any cluster whose centroid is at **tier ≤ fleet_aggregate**
  from the sub. Pre-cleanup the filter was `tier ≥ fleet_aggregate`,
  which was inverted — it skipped distant clusters at "always" tier
  (sub couldn't see them) and included clusters whose centroid was
  in visual range (sub was close enough that fast-lane individuals
  would be cleaner).
- No per-sub exclusion needed (slow-lane no longer emits individual
  records, so there's nothing to pin out of the cluster aggregate).
- spatial-index will eventually own the cluster build per docs/08
  §3.2a; cell-mgr plays both roles for now.

**Fast-lane** (new): subscribers receive a single-EntityRecord
payload per inbound `sim.entity.<id>.state` msg, only if the
subscriber is at tier ≥ visual from the entity. EntityRecord is the
20 B `{ u32 id, u16 generation, pose_codec.encodePose delta-mode (14
B) }` shape. Encoded into a fixed `relay_buf: [64]u8` on Fanout —
no per-callback allocation.

**Original M6.4 placeholder** (pre-codec, kept for the diff):

```
EntityRecord[N] = { u32 id, u16 generation, u8 tier, u8 _pad,    (20 B)
                    [3]f32 pos }
```

Max per-subscriber payload at the design cap of 200 entities/cell where every entity is in tier ≥ visual = `4 + 200 × 20 = 4004 B/tick = 120 KB/s = 960 kbps` — i.e., 96% of budget. M7's 16 B/pose codec (~12-14 B/record) brings that to ~75% before tier rate gating, ~50% with rate gating applied.

## Scenarios + measurements (slow-lane)

Each scenario seeds a fresh `State + Fanout`, applies entity + subscriber positions, runs **one tick**, and measures captured slow-lane payload size per subscriber. Positions seeded deterministically (`std.Random.DefaultPrng init 0xBADC0DE`) so the numbers are reproducible. **Fast-lane traffic is not in these numbers** — it scales with the per-entity state-msg rate the producer chooses (60 Hz for tier 1 per docs/02 §9), measured separately under live load.

| Scenario | subs | ents | mean clusters/sub | payload bytes (min/mean/max) | mean B/s | max B/s | max % of budget |
|---|---:|---:|---:|---|---:|---:|---:|
| idle (uniform 4 km box) | 50 | 100 | 50.80 | 792 / 820.8 / 856 | 24 624 | 25 680 | **20.54 %** |
| mid (30 ents, ~1 km cluster) | 50 | 30 | 1.74 | 8 / 35.8 / 56 | 1 075 | 1 680 | **1.34 %** |
| hot (100 ents, 200 m fight) | 50 | 100 | 0.00 | 8 / 8.0 / 8 | 240 | 240 | **0.19 %** |

### Distance sweep — single subscriber, 100 entities at origin

| sub distance | clusters | payload bytes | bytes/sec @ 30 Hz |
|---:|---:|---:|---:|
| 5000 m | **1** | **24** | **720** |
| 2500 m | **1** | **24** | **720** |
| 1000 m | **1** | **24** | **720** |
|  600 m | **1** | **24** | **720** |
|  500 m | 0 | 8 | 240 |
|  400 m | 0 | 8 | 240 |
|  200 m | 0 | 8 | 240 |
|  150 m | 0 | 8 | 240 |
|  100 m | 0 | 8 | 240 |
|    0 m | 0 | 8 | 240 |

Now the sweep shows the slow-lane's natural binary cutover:

- **Beyond 500 m (cluster centroid not in visual range):** subscriber receives a 16 B cluster summary regardless of distance, including the very-distant 5 km case the previous centroid filter wrongly rejected.
- **Inside 500 m:** cluster centroid is in the sub's visual range; cluster is filtered out (sub is close enough that the fast-lane carries the entities individually). Slow-lane drops to header-only.

For comparison, the **previous milestone** (cluster pathway emitting *and* slow-lane individual records for visual+ entities) saw the hot scenario at 48 % of budget and a sharp spike inside 500 m as 100 individual records replaced the cluster summary. Post-cleanup that spike moves to the fast-lane, which sees it as N × M × (sub's tier-1 rate) — independent of the slow-lane budget.

## Conclusions

1. **Slow-lane is now properly slow.** Hot scenario uses 0.19 % of budget; mid uses 1.34 %; idle 20.5 %. Slow-lane is firmly a low-bandwidth lane; fast-lane carries the per-entity heavy lifting.
2. **Architectural alignment with docs/08 §2.3.** The slow-lane is "tier ≤ 0.5 cadence" content (cluster summaries, eventual tier-0 fields). The fast-lane is "tier 1+ via callback-to-publish" — already shipped (`Fanout.relayState` + `sim.entity.*.state` subscription).
3. **Cluster centroid filter inverted in the cleanup.** Pre-cleanup it skipped distant clusters at "always" tier (sub couldn't see them) and included clusters whose centroid was in visual range (sub was close enough that fast-lane individuals would be cleaner). Post-cleanup is the right way around: include any cluster at fleet_aggregate or further from the sub.
4. **Idle BW slightly up** (17.4 % → 20.5 %) — the cleanup added clusters at "always" tier (the very-distant 5 km case in the sweep) that the old filter wrongly skipped. Better awareness, ~3 pp BW cost, well within budget.
5. **Hot scenario fast-lane projection.** With 100 entities at 60 Hz tier-1 cadence and 50 subs all in close_combat range, the fast-lane is 100 × 60 × 50 × 28 B = 8.4 MB/s aggregate, or 168 KB/s per subscriber — **134 % of budget per sub**. Two paths to bring this in: (a) sub-cell partition the 50 subs across multiple cell-mgr workers (docs/08 §2.4a), (b) actually rate-limit per-tier on the fast-lane producer (current model assumes producer chose to publish at 60 Hz). Both are post-M6 work.

## Known limitations to revisit

- **Fast-lane carries no per-tier rate gating** — the producer's publish cadence sets the wire rate. ship-sim will need to honour tier rates from `data/tier_distances.yaml`; for the M-stack harness the cadence is set via `--rate`.
- **NATS protocol overhead** (~20-30 B per message for the wire-level `PUB` header) is below the measurement. At 30 publishes/sec/sub on the slow-lane that's another ~900 B/s per subscriber regardless of payload; on the fast-lane it scales with state-msg rate.
- **Cluster centroid distance is the filter, not per-cluster bounding box.** A cluster whose centroid sits on the wrong side of the visual boundary from a subscriber gets dropped or included wholesale, even if some of its entities are "off the centroid" enough to land in a different band. Acceptable for the M-stack scale; revisit if it becomes visible during the milestone-1.5 stress test.
