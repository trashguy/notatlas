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

**Fast-lane** (batched): inbound `sim.entity.<id>.state` msgs are
appended into per-subscriber pending buffers via `Fanout.relayState`;
once per 60 Hz window `Fanout.flushBatches` emits **one** batched
payload per sub with `cluster_count = 0` and one EntityRecord per
visible-entity update collected during the window. Wire shape is
identical to the slow-lane (same `PayloadHeader + records` layout) so
receivers parse one type regardless of which lane produced it.

EntityRecord is 20 B: `{ u32 id, u16 generation, pose_codec.encodePose
delta-mode (14 B) }`. Per-sub `pending` buffer is pre-grown at
`ensureSubscriber` time and reused with `clearRetainingCapacity` per
flush — no per-callback allocation.

**Why batch.** Pre-batch each state msg triggered one publish per
visible sub. At hot density (50 subs × 100 ents × 60 Hz fast-lane
cadence) that's **6 000 publishes/sec/sub**, each carrying its own
NATS PUB framing (`PUB <subj> <len>\r\n<payload>\r\n` ≈ 50 B for the
gw.client subject). Post-batch each sub gets **60 publishes/sec** —
exactly one per fast-lane window — carrying the concatenated records
for everything visible in that window. Payload bytes are the same
(same N records, same 20 B each); the **NATS framing collapses from
2 400 kbps/sub down to 24 kbps/sub** — 100× saving on the per-msg
overhead. See "Fast-lane batched (hot scenario)" measurement below.

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

## Fast-lane batched: 200-soft-target vs 1.5×-stress

Both scenarios run one 60 Hz fast-lane window. Every entity emits a
state msg → `relayState` appends to per-sub pending → `flushBatches`
emits one batched payload per sub.

| Metric | target (200-soft) | stress (1.5×) | ratio |
|---|---:|---:|---:|
| Entities | 100 | 300 | 3.00× |
| Subscribers | 50 | 50 | — |
| Pushes (record appends) per window | 5 000 | 15 000 | 3.00× |
| Batched publishes per window | 50 (one per sub) | 50 (one per sub) | **flat** |
| Per-sub batched payload max | 2 008 B | 6 008 B | **2.99×** |
| Per-sub payload @ 60 Hz | 120 480 B/s = **96.38 % of budget** | 360 480 B/s = **288.38 % of budget** | linear |
| Per-sub publishes/sec — PRE-batch | 6 000 | 18 000 | 3.00× |
| Per-sub publishes/sec — POST-batch | 60 | 60 | **flat** |
| Reduction in NATS messages | 100× | 300× | — |

**The headline soft-cap-degrades-gracefully property** is the **flat**
post-batch publishes/sec line. Per-sub NATS message rate does NOT
scale with entity count. Adding entities adds payload bytes (linearly,
~3× for 3× ents — header amortization makes it slightly less than 3×),
but does not multiply the per-sub publish overhead. That's the
no-cliff property the soft-cap framing requires.

**The 288 % of budget at 1.5× stress is intentional and documented,
not a failure.** Per memory `design_soft_caps_subcell.md` the system
should degrade gracefully above the soft target — and "graceful" here
means "linear in entity count," not "stays inside budget." Above the
soft cap the architectural lever is **sub-cell partitioning** per
docs/08 §2.4a (ports / harbor anchorages route subscribers across
multiple cell-mgr workers, halving per-sub fanout work), not a
tighter producer-side rate.

**Test gates encode the property:**

- target ≤ 100% of budget (verified)
- stress > 100% of budget (intentional, confirms we're past the soft cap)
- stress / target payload ratio ∈ [2.5×, 3.5×] (linear scaling — >3.5× would imply per-sub overhead growing super-linearly, the cliff failure mode batching prevents)
- both: exactly one batched publish per sub per window (no per-msg fanout)

## Conclusions

1. **Slow-lane is properly slow.** Hot scenario uses 0.19 % of budget; mid uses 1.34 %; idle 20.5 %. Slow-lane is firmly a low-bandwidth lane; fast-lane carries the per-entity heavy lifting.
2. **Fast-lane is now batched.** Per-sub publishes/sec dropped from up to 6 000 (one per inbound state msg per visible sub) to 60 (one per 60 Hz window). NATS PUB framing overhead drops 100×. Payload bytes are unchanged.
3. **Wire shape is identical between lanes.** Both use `PayloadHeader + records`. Receivers parse one type. Slow-lane uses `cluster_count`; fast-lane uses `entity_count`; the other field is 0.
4. **Architectural alignment with docs/08 §2.3.** Slow-lane = "tier ≤ 0.5 cadence" content (cluster summaries, eventual tier-0 fields). Fast-lane = "tier 1+ via callback-to-publish" — buffered then flushed at the tier-1 rate.
5. **200 ents × 50 subs is over the soft target by design.** Per memory `design_soft_caps_subcell.md` — 200/cell is the design point not a hard cap. Beyond 100 entities in close-quarters, sub-cell partitioning is the architectural lever, not a tighter producer-side rate gate.

## Known limitations to revisit

- **Producer-side per-tier rate gating still missing.** Fast-lane window is 60 Hz on the consumer, but the *producer* (ship-sim, harness) sets the inbound msg rate. ship-sim should honour tier rates from `data/tier_distances.yaml`; tier-2/3 fields should be on-change, not 60 Hz. Without that, hot-scenario inbound rate is the source of pressure, batching only fixes the per-sub fanout cost.
- **Cluster centroid distance is the filter, not per-cluster bounding box.** A cluster whose centroid sits on the wrong side of the visual boundary from a subscriber gets dropped or included wholesale, even if some of its entities are "off the centroid" enough to land in a different band. Acceptable for the M-stack scale; revisit if it becomes visible during the milestone-1.5 stress test.
- **Window jitter under load.** The 60 Hz fast-lane tick fires from cell-mgr's main loop; if state-msg drain takes longer than the window we'll batch >16.67 ms of records into one publish. Bounded by the tight-loop floor (currently ~5 ms processIncoming budget), not load-bearing for M-stack but the milestone-1.5 stress gate should eyeball flush cadence under live load.
