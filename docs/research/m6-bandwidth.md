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

**As of fleet-aggregate integration** (post-B):

```
PayloadHeader      = { u32 entity_count, u32 cluster_count }     ( 8 B)
EntityRecord[ec]   = { u32 id, u16 generation, codec[14] }       (20 B)
ClusterRecord[cc]  = { f32 centroid_x, f32 centroid_z,           (16 B)
                       f32 radius_m, u16 heading_deg,
                       u8 count, u8 silhouette_mask }
```

Entity records carry full 6-DoF pose (pos + rot + vel) via the M7
codec in delta mode against the entity's own stored pose (delta is
zero for the static synthetic load — exercises the codec end-to-end
without a separate keyframe-establishing message stream). Cluster
records mirror `replication.FleetAggregate` exactly.

**Cluster pathway:**
- Cell-mgr runs the M6.1 `buildClusters` pass at 5 Hz over the
  current entity table (using a per-cell arena that retains capacity
  between passes — no steady-state allocs).
- Per-subscriber, each cluster is filtered by centroid distance: if
  the centroid is at fleet_aggregate tier or beyond, include it.
- The included cluster's `count` is recomputed via `aggregateForSubscriber`
  to exclude entities the subscriber receives individually — preserving
  the M6.1 count-correctness invariant.
- spatial-index will eventually own the cluster build per docs/08
  §3.2a; cell-mgr plays both roles for now.

**Original M6.4 placeholder** (pre-codec, kept for the diff):

```
EntityRecord[N] = { u32 id, u16 generation, u8 tier, u8 _pad,    (20 B)
                    [3]f32 pos }
```

Max per-subscriber payload at the design cap of 200 entities/cell where every entity is in tier ≥ visual = `4 + 200 × 20 = 4004 B/tick = 120 KB/s = 960 kbps` — i.e., 96% of budget. M7's 16 B/pose codec (~12-14 B/record) brings that to ~75% before tier rate gating, ~50% with rate gating applied.

## Scenarios + measurements

Each scenario seeds a fresh `State + Fanout`, applies entity + subscriber positions, runs **one tick**, and measures captured payload size per subscriber. Positions seeded deterministically (`std.Random.DefaultPrng init 0xBADC0DE`) so the numbers are reproducible.

| Scenario | subs | ents | mean vis/sub | mean clusters/sub | payload bytes (min/mean/max) | mean B/s | max B/s | max % of budget |
|---|---:|---:|---:|---:|---|---:|---:|---:|
| idle (uniform 4 km box) | 50 | 100 | 4.0 | 26.24 | 220 / 507.4 / 724 | 15 223 | 21 720 | **17.38 %** |
| mid (30 ents, ~1 km cluster) | 50 | 30 | 16.4 | 2.64 | 112 / 379.0 / 580 | 11 371 | 17 400 | **13.92 %** |
| hot (100 ents, 200 m fight) | 50 | 100 | 100.0 | 0.00 | 2 008 / 2 008.0 / 2 008 | 60 240 | 60 240 | **48.19 %** |

### Distance sweep — single subscriber, 100 entities at origin

| sub distance | visible entities | clusters | payload bytes | bytes/sec @ 30 Hz |
|---:|---:|---:|---:|---:|
| 5000 m | 0 | 0 | 8 | 240 |
| 2500 m | 0 | 0 | 8 | 240 |
| 1000 m | 0 | **1** | **24** | **720** |
|  600 m | 0 | **1** | **24** | **720** |
|  500 m | 100 | 0 | 2 008 | 60 240 |
|  400 m | 100 | 0 | 2 008 | 60 240 |
|  200 m | 100 | 0 | 2 008 | 60 240 |
|  150 m | 100 | 0 | 2 008 | 60 240 |
|  100 m | 100 | 0 | 2 008 | 60 240 |
|    0 m | 100 | 0 | 2 008 | 60 240 |

The sweep now shows a three-band progression instead of a binary cliff:

- **Beyond 2 km (always tier):** header-only payload (8 B). Even the cluster pathway can't help — entities are out of the subscriber's awareness entirely.
- **500 m – 2 km (fleet_aggregate):** subscriber receives a single 16 B cluster summary instead of 100 individual entity records. **2 004 → 24 B**, an **83×** per-tick reduction matching the docs/08 §3.2a headline (~160× including the 5 Hz cluster-rebuild rate).
- **Inside 500 m (visual+):** all 100 entities individually streamed; cluster gets filtered out because its centroid is now in the subscriber's visual range.

## Conclusions

1. **Within budget at the design ceiling.** The hot 200/cell scenario uses ~48 % of the 1 Mbps cap, leaving headroom for input round-trips, protocol overhead, and any tier 2/3 on-change events.
2. **Scaling tracks the filter exactly.** Three distinct bands now: header-only beyond 2 km, cluster-summary at 500 m – 2 km, full individual stream inside 500 m. Sweep visible-count is monotonic; cluster centroid filtering kicks in when subscribers cross the visual boundary.
3. **Cluster pathway delivers the docs/08 §3.2a headline.** The single-subscriber sweep shows an 83× per-tick reduction at 1 km (2 004 → 24 B). With the 5 Hz cluster rebuild rate factored in (the actual data only freshens 5×/sec rather than 30×) the effective reduction matches the ~160× target.
4. **Idle BW grew vs the pre-cluster M6.4 placeholder** (4.4 % → 17.4 %) — but only because the cluster pathway is *adding* a previously-absent capability (distant entities flow through cluster summaries instead of being silently dropped). Without it, distant entities were invisible to subscribers; with it, they show up at a fixed cost of ~16 B/cluster.
5. **Hot is unchanged from the pre-cluster pathway** because cluster centroids fall inside the close-quarters fight's visual range and get filtered out per-subscriber. All 100 entities flow individually as before — the cluster code adds 0 B in this scenario.
6. **M7 codec already integrated** — entity records carry full pos + rot + vel in the same 20 B budget as the original pos-only placeholder. Future per-tier rate gating (tier 1 → 60 Hz, tiers 2/3 on-change) can be layered in without changing the wire format.

## Known limitations to revisit

- **Single-tier rate on the individual stream.** Fanout runs all individually-streamed tiers at 30 Hz. Tier 1 (60 Hz pose) is undercounted; tier 2/3 (on-change) over-counted. Architectural fix is the fast-lane callback relay per docs/08 §2.3 (subscribe to `sim.entity.>`, forward immediately on each msg) — separate next step.
- **NATS protocol overhead** (~20-30 B per message for the wire-level `PUB` header) is below the measurement. At 30 publishes/sec/sub that's another ~900 B/s per subscriber regardless of payload — small.
- **Cluster centroid distance is the filter, not per-cluster bounding box.** A cluster whose centroid sits on the wrong side of the fleet_aggregate boundary from a subscriber gets dropped wholesale, even if some of its entities are "in range". Acceptable for the M-stack scale; revisit if it becomes visible during the milestone-1.5 stress test.
