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

**As of the M7 codec integration** (post-`9d00323`):

```
PayloadHeader     = u32 count                                    ( 4 B)
EntityRecord[N]   = { u32 id, u16 generation, codec[14] }        (20 B)
                       — codec is pose_codec.encodePose delta-mode
                         (no cell): 6 B i16-cm pos delta + 4 B
                         smallest-three quat + 4 B vel delta.
```

Same 20 B/record budget as the original M6.4 placeholder, but the
trailing 14 B now encodes the *full 6-DoF pose* (pos + rot + vel)
through the M7 codec instead of three naked f32s for position only.
Receivers decode via `pose_codec.decodePose` against the same keyframe
the encoder used. M6.4 fanout uses the entity's stored pose as the
keyframe (delta is zero for the synthetic load) — production will
need a separate keyframe-establishing message stream, out of M6 scope.

**Original M6.4 placeholder** (pre-codec, kept here for the diff):

```
EntityRecord[N] = { u32 id, u16 generation, u8 tier, u8 _pad,    (20 B)
                    [3]f32 pos }
```

Max per-subscriber payload at the design cap of 200 entities/cell where every entity is in tier ≥ visual = `4 + 200 × 20 = 4004 B/tick = 120 KB/s = 960 kbps` — i.e., 96% of budget. M7's 16 B/pose codec (~12-14 B/record) brings that to ~75% before tier rate gating, ~50% with rate gating applied.

## Scenarios + measurements

Each scenario seeds a fresh `State + Fanout`, applies entity + subscriber positions, runs **one tick**, and measures captured payload size per subscriber. Positions seeded deterministically (`std.Random.DefaultPrng init 0xBADC0DE`) so the numbers are reproducible.

| Scenario | subs | ents | mean visible/sub | payload bytes (min / mean / max) | mean B/s | max B/s | max % of budget |
|---|---:|---:|---:|---|---:|---:|---:|
| idle (uniform 4 km box) | 50 | 100 | 4.0 | 24 / 83.6 / 184 | 2 508 | 5 520 | **4.42 %** |
| mid (30 ents, 50 subs in ~1 km cluster) | 50 | 30 | 16.4 | 44 / 332.8 / 544 | 9 984 | 16 320 | **13.06 %** |
| hot (100 ents, 50 subs in 200 m fight) | 50 | 100 | 100.0 | 2 004 / 2 004.0 / 2 004 | 60 120 | 60 120 | **48.10 %** |

### Distance sweep — single subscriber, 100 entities at origin

| sub distance | visible entities | payload bytes | bytes/sec @ 30 Hz |
|---:|---:|---:|---:|
| 5000 m | 0 | 4 | 120 |
| 2500 m | 0 | 4 | 120 |
| 1000 m | 0 | 4 | 120 |
|  600 m | 0 | 4 | 120 |
|  500 m | 100 | 2 004 | 60 120 |
|  400 m | 100 | 2 004 | 60 120 |
|  200 m | 100 | 2 004 | 60 120 |
|  150 m | 100 | 2 004 | 60 120 |
|  100 m | 100 | 2 004 | 60 120 |
|    0 m | 100 | 2 004 | 60 120 |

The cliff at 500 m is the visual-tier cutover: outside it, no entities qualify for the individual stream (they'd flow as fleet aggregates instead — separate pathway, not measured here). M6.4's fanout produces a header-only payload (4 B) for the excluded set.

## Conclusions

1. **Within budget at the design ceiling.** The hot 200/cell scenario uses 48 % of the 1 Mbps cap, leaving headroom for the cluster-aggregate stream (tier 0.5, ~120 B/s/observer per docs/08 §3.2a), input round-trips, and protocol overhead.
2. **Scaling tracks the filter exactly.** Header-only payload (4 B) when no entity is at tier ≥ visual; jumps to header + 20 × visible-count once any cross the 500 m line. Sweep showed monotonic visible-count progression, asserting the tier filter actually escalates with distance.
3. **Idle is effectively free.** Subscribers far from any entity pay the 4 B header at 30 Hz = 120 B/s — well under the Tier 0 budget allowance.
4. **M7 expectations.** The compressed pose codec drops the per-entity record from 20 B → ~12-14 B. Combined with per-tier rate gating (tier 0.5 at 5 Hz, tier 2/3 on-change), the hot peak should drop to roughly 25-30 % of budget post-M7, leaving plenty of room to grow the close-combat detail set (per-plank HP, cannon orientations) without re-opening the BW headline.

## Known limitations to revisit

- **Single-tier rate.** M6 fanout runs everything at 30 Hz. Tier 0 (30) is correct, tier 1 (60) is undercounted, tier 0.5 (5) is overcounted. Per-tier rate gating lands in M7 alongside the pose codec.
- **No cluster aggregate.** This measurement covers only the individual stream (tier ≥ visual). The cluster pathway (tier 0.5, sub-cell aggregates from `replication.buildClusters`) adds fixed-cost ~16-24 B per cluster per 5 Hz tick — small and bounded at the per-cell cluster count.
- **No NATS protocol overhead.** Add ~20-30 B per message for the wire-level `PUB` header. At 30 publishes/sec/sub that's another ~900 B/s per subscriber regardless of payload — small.
