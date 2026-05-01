---
name: notatlas locked architecture decisions (v0)
description: All 10 architectural decisions ratified by user 2026-04-27. The full technical front. Reference these directly when designing systems — don't relitigate.
type: project
originSessionId: cb0aa047-d395-4803-bc6b-7df96341b031
---
Ratified 2026-04-27 by user ("looks good"). Treat as locked unless explicitly revisited.

## 1. Authoritative tick rate
- **60Hz** for player movement + ship-sim
- **20Hz** for AI (NPC crew, wildlife, SotD-equivalents)
- **5Hz** for environment (weather, wind field updates, time of day)
- Tick budget per ship-sim: ~10μs/ship (per naval-combat memo) → 100 active ships = 6% of one core

## 2. Determinism stance — HYBRID
- **Deterministic given `(time, seed)`:** wave height query, projectile arcs (cannons, mortars, ballistas, muskets), wind field
- **Authoritative + interpolation:** ship rigid body, player movement, character state, AI decisions
- Wave system API contract: `wave_height(x, z, t, seed) -> (height, normal)` — same answer client and server

## 3. Rigid body solver
- **Jolt Physics** via Zig FFI
- Used for ship hulls, character capsules, structure collision
- Custom layer on top: per-hull-point buoyancy sampling, Archimedes force application
- Don't roll our own; this is solved

## 4. Spatial index topology
- **Single service** to start
- **Sharded-by-region keys baked into design from day 1** — splitting to N processes is config change, not rewrite
- Owns `idx.spatial.cell.<x>_<y>.delta` stream and `idx.spatial.query` request/reply
- Consumes all entity state firehose, maintains spatial structure (likely uniform grid or hash; quadtree later if density warrants)

## 5. Persistence cadence + storage shape — MIXED
| State type | Storage | Cadence |
|---|---|---|
| Pose / fast-changing sim state | Never persisted | — |
| Player inventory | JSONB blob per player | On change, batched |
| Market / tradeable items | Relational table | On change |
| World structures + claims | Relational table | On change |
| Damage/event log | JetStream KV with TTL → wipe | Per event |
| Account / cosmetics / veteran tier | Relational, account-scope | On change, persists across wipes |
| Discipline progress | Relational, character-scope | On level event |
| Fog-of-war map state | JSONB blob per character | On chunk-discover event |

**persistence-writer service** is sole consumer of change streams; batches PG writes; never on hot path.

## 6. Hibernation rules — MIXED
- Ship at sea = always raidable (always-on PvP)
- Short grace timer (~5 min) when last crewmember disconnects mid-voyage
- Anchored at **owned anchorage** = protected during defined raid windows (data-driven schedule per cycle)
- Outside owned anchorage = exposed
- Forces "park ship safe" decision; doesn't trivialize PvP

## 7. Pose compression — ~16 B/pose
- Position: quantized to 1cm relative to last keyframe (6B for 3 axes within cell range)
- Rotation: smallest-three quaternion (4B)
- Velocity delta from keyframe (4B)
- Cell id when crossing keyframe boundary (2B optional)
- Bake into protocol layer; reusable for ships, characters, projectile observation

## 8. JetStream usage map (architectural API)
| Subject pattern | Transport | Why |
|---|---|---|
| `sim.entity.<id>.state` (pose firehose) | Core NATS | High-rate lossy, latest-value |
| `sim.entity.<id>.event.*` (damage, fire, sink, etc.) | JetStream | Reliable, replay |
| `idx.spatial.cell.<x>_<y>.delta` | JetStream | Reliable, ordered |
| `env.cell.<x>_<y>.*` (weather, wind, terrain) | JetStream KV | Latest-value durable |
| `chat.*` | Core NATS | Tolerant to loss; voice on separate transport |
| Voice | Separate WebRTC SFU | Off the gameplay path entirely |

## 9. Replication tier system
- **4 tiers:** 0 (always), 1 (visual ~500m), 2 (close-combat ~150m), 3 (boarded same ship)
- Mechanism in code; thresholds in `data/tier_distances.toml`
- Each replicated component declares its tier; replication system honors per-subscriber distance
- First-pass thresholds; **tune from milestone-1.5 stress test**

## 10. Voice transport
- **WebRTC SFU**, leaning **LiveKit** (open source, self-hostable, mature)
- Spatial filter at SFU layer — players subscribed to nearby crew + own ship
- P2P fallback for same-ship voice on small crews
- Off the NATS path entirely; never competes with gameplay BW

---

## Service decomposition (derived from above)

8 services:
1. **gateway** (existing in fallen-runes) — client-facing, routes to services, owns per-client interest
2. **auth** (existing in fallen-runes) — login, JWT, account
3. **ship-sim** — per-ship physics, hull/sail/cannon/damage state, 60Hz
4. **cell-mgr** — interest manager per region, subscribes to entities in range
5. **spatial-index** — single source of truth for entity → cell membership
6. **env** — wind, weather, time of day, wave seed, per-region 5Hz
7. **persistence-writer** — sole PG writer, consumes change streams, batches
8. **voice-sfu** — separate process (LiveKit), spatial-filtered voice

## Reference reading order for future sessions
1. `MEMORY.md` (index)
2. `project_notatlas.md` (project goal)
3. This file (architecture)
4. `pillar_naval_combat_at_scale.md` (the why for most of #1-9)
5. `pillar_harbor_raid_client_perf.md` (renderer pillar)
6. `principle_data_driven.md` (engineering directive)
7. `locked_design_caps.md` (content caps v0)
