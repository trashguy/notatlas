# M1.5 stress gate

**Date:** 2026-05-01
**Status:** PASS
**Headline:** 50 conns × 30 ships at **321.4 kbps per conn** = **32.1%** of the 1 Mbps/client budget. Per-conn variance ≈ 0%.

## Gate (per docs/04 §M1.5)

> 30 boxes/cell × 50 simulated clients × actual gateway/NATS path × ≤ 1 Mbps/client.

The phase 1 → 2 milestone gate. Earlier soft-cap framing (M6.5, 2026-04-29) verified the same bandwidth invariants synthetically inside the cell-mgr fanout test; this is the live verification through real Jolt physics, real NATS, real TCP gateway forwarding.

## Architecture under test

```
ship-sim (--ships 30 --grid --spacing 30, 6×5 grid centered at origin)
    ↓ sim.entity.<i>.state @ 60 Hz × 30 ships = 1800 state msgs/s
NATS
    ↓
cell-mgr (--cell 0_0)
    ↓ slow-lane @ 30 Hz: 50 cluster-summary publishes (header-only, all ships in visual)
    ↓ fast-lane @ 60 Hz: 50 batched per-sub publishes
NATS
    ↓ gw.client.{256..305}.cmd
50 × gateway (--client-id 256+i --listen-port 9000+i, single-client per process)
    ↓ length-prefixed TCP frames on 127.0.0.1:{9000..9049}
50 × python orchestrator readers (scripts/m1_5_drive.py)
```

Per-process-per-client gateway is the workaround until JWT + multi-client gateway (gateway sub-steps 4+5) lands. cell-mgr is single-process, ship-sim is single-process; the per-sub fanout is the load-bearing scaling axis being measured.

## Worst-case framing

Subscribers are placed at exactly the origin (`bench --sub-spread 0`) and ships are spawned in a 6×5 grid at 30 m spacing centered at origin (max half-extent ≈ 75 m). All 30 ships are inside the 500 m visual tier from every subscriber — no slow-lane cluster compaction kicks in, no per-sub geometry filter trims the entity set. Every sub receives every entity in every fast-lane window. If the gate passes here, it passes anywhere.

## Numbers

### Per-conn TCP outbound (24 s measurement window)

| stat | bytes/sec | kbps | % of 1 Mbps |
|---|---:|---:|---:|
| min | 40 169 | 321.4 | 32.1% |
| median | 40 169 | 321.4 | 32.1% |
| mean | 40 169 | 321.4 | 32.1% |
| p95 | 40 169 | 321.4 | 32.1% |
| max | 40 169 | 321.4 | 32.1% |

Min == max == median to byte resolution. The fast-lane batching's "publishes flat in N" property holds exactly: each sub sees the same payload because each sub has the same visibility set.

### Frame and entity rates

| metric | observed | expected | source of expected |
|---|---:|---:|---|
| frames/s per sub | 97.6 | 90 | 60 Hz fast + 30 Hz slow |
| ents/s per sub | 1 949.9 | 1 800 | 30 ships × 60 Hz |
| state msgs/s into cell-mgr | 1 800 | 1 800 | 30 ships × 60 Hz |
| pushed per slow-tick (cell-mgr) | 1 850–4 150 | ≤ 30 × 50 × 2 = 3 000 | window jitter shifts ent assignment per sub|

Frame-rate overage (~8%) and ent-rate overage (~8%) come from accumulator-tick jitter — occasionally a fast-lane window contains 2 state msgs from one ship instead of 1 (when the window edge straddles two of ship-sim's 60 Hz ticks). The headline bandwidth still passes.

cell-mgr's "pushed" count varies cycle-to-cycle (2263 → 3000 in adjacent ticks); aggregate over time is ~3000 × 30 = 90 000 record-appends/s, matching the architectural expectation (1800 state msgs × 50 subs = 90 000 push events).

### Where the bytes go

Per-sub per-second budget breakdown (327 250 bits/s = ~40 905 B/s observed):

```
fast-lane @ 60 Hz × (8 B PayloadHeader + 30 ships × 20 B EntityRecord)
                = 60 × 608 = 36 480 B/s payload
slow-lane @ 30 Hz × 8 B header (no clusters; all in visual range)
                = 30 × 8 = 240 B/s payload
TCP framing: 4 B prefix × 90 frames = 360 B/s overhead
expected total: 37 080 B/s
observed:       40 169 B/s (~8% over from window-jitter, see above)
```

## What this proves

1. **Fast-lane batching's flat-rate-in-N property is real on the wire.** The 2026-04-30 1.5×-stress unit test asserted "per-sub publishes/sec POST-batch flat at 60 regardless of ent count" against an in-process synthetic load. This live run confirms it through real NATS publish/subscribe paths and the gateway forwarding hop, with all 50 subs sharing the cell-mgr fanout simultaneously.
2. **Per-process gateway scales to N=50 on the dev box** without socket exhaustion, NATS subscription pressure, or visible cell-mgr backpressure.
3. **There is ~3× headroom** over the 1 Mbps/client budget at 30 ships. Doubling the ship count to ~60 (or roughly 5× the entity work) would still fit. Past ~90 ships the per-sub payload would hit the budget and force one of: M7-style binary delta encoding (already in place — M7 codec running today), per-tier rate gating (the `tier_distances.yaml` rates exist but are unused beyond fast/slow distinction), sub-cell partitioning per docs/08 §2.4a.

## What this does NOT prove

- **Single-gateway-multi-client throughput.** This run uses 50 gateway processes; the per-process resource cost (RSS, TCP/NATS connections, accept queues) is paid once per client. A real production gateway (sub-steps 4+5) would multiplex N clients on one process — the per-conn payload work is the same but the framing and accept paths share a single CPU. Likely fine given 32% headroom, but not measured here.
- **Cell-mgr CPU at higher densities.** The 8% bandwidth jitter is window-edge effect at 60 Hz — moderate density. At 200 ships/cell or 200 subs/cell the per-tick walk cost grows linearly; soft-cap framing per `design_soft_caps_subcell.md` says sub-cell partitioning is the answer past 200/cell, not larger ent counts in a single cell-mgr.
- **Network egress reality.** All traffic stays on loopback; the dev box's interface MTU and queue depths don't apply. WAN testing (gateway co-located with NATS, clients across a real network) is post-Phase-2 and would reveal jitter / loss-recovery characteristics this measurement skips.
- **Player input return path under load.** This run only exercises NATS → TCP outbound. The TCP → NATS input path was verified at sub-step 3 with a single client; concurrent input from 50 clients is a separate measurement (low-priority — input is sparse and small).

## Reproduce

```sh
./scripts/m1_5_run.sh 30 50
# args: duration_s, n_subs (defaults: 30, 50)
```

The launcher starts NATS (if not up), `cell-mgr`, `ship-sim --ships 30 --grid --spacing 30`, `bench` harness with N subs, then 50 gateway processes on ports 9000..9049, then the python orchestrator. Logs land in `/tmp/notatlas-m15/`. Cleanup on exit kills all spawned PIDs.

## Phase 1 → Phase 2

This is the gate. Phase 1 architecture passes its scaling test under conservative worst-case framing. Phase 2 content work (real ship hulls, biomes, anchorages, structures, market) can begin against the verified-scalable substrate.
