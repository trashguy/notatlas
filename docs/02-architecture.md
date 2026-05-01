# 02 — Architecture

The ten architectural decisions that define notatlas's technical front, plus
the service mesh and NATS subject scheme they imply.

All decisions ratified 2026-04-27. Treat as locked unless explicitly
revisited.

## The headline innovation: cells as interest managers, not state owners

Atlas ran one UE4 dedicated server process per grid cell. Each process
owned the simulation of everything in its cell — physics, AI, inventory,
replication. Cross-cell ship transitions serialized actor state and
re-spawned on the destination process, coordinated through Redis. Result:
~2-second stutter at every boundary, ship-eating handoff bugs, no graceful
scale-down for idle ocean.

notatlas inverts ownership:

```
ship-sim service  ──pub──▶  sim.entity.<id>.state @ 60Hz
                                │
                ┌───────────────┴───────────────┐
                ▼                               ▼
       cell-mgr(8,5)                    cell-mgr(8,6)
       (subscribes to whatever          (subscribes to whatever
        is in its 1×1 region)            is in its 1×1 region)
                │                               │
                └────────────┬──────────────────┘
                             ▼
                    gateway / per-client interest
                    (player aboard ship X subscribes to ship X +
                     neighbor cells)
```

Crossing the grid boundary becomes: source cell-mgr unsubscribes from
`sim.entity.123.state`, destination cell-mgr subscribes. **The ship
process is unaffected.** No serialize-and-teleport. No stutter. Idle cells
with no entities subscribe to nothing and cost approximately zero CPU.
Adding a new cell is booting a process that subscribes to its spatial
subjects.

The HFT analog: per-symbol market-data streams + a thin reference-data
service that routes "what symbols are in my watchlist?" That model has
scaled to millions of symbols at microsecond latency in production for
decades. Same shape applies here, with `entity_id` substituted for
`symbol`.

## The 10 locked decisions

### 1. Authoritative tick rate

- **60 Hz** for player movement and ship-sim
- **20 Hz** for AI (NPC crew, wildlife, hostile NPC ships)
- **5 Hz** for environment (weather, wind field updates, time of day)

Tick budget per ship-sim: ~10 μs/ship. 100 active ships in one process =
6% of one core. CPU is not the binding constraint; bandwidth fanout is.

### 2. Determinism stance — hybrid

**Deterministic given `(time, seed)`:**
- Wave height query
- Projectile arcs (cannons, mortars, ballistas, muskets)
- Wind field

**Authoritative + interpolation:**
- Ship rigid body
- Player movement
- Character state
- AI decisions

Wave system API contract: `wave_height(x, z, t, seed) -> (height, normal)`.
Same answer client and server. Critical for client-side projectile
prediction matching server hit resolution.

### 3. Rigid body solver — Jolt

[Jolt Physics](https://github.com/jrouwe/JoltPhysics) via Zig FFI. MIT,
modern, fastest in class, used in Horizon Forbidden West. Used for:

- Ship hulls (rigid bodies with constraints)
- Character capsules
- Structure collision
- Raycasts for hit registration

Custom layer on top: per-hull-point buoyancy sampling, Archimedes force
application, integrated with the wave-query API.

### 4. Spatial index topology — single service, sharded-ready

Single process owning the global spatial index, with sharded-by-region
keys baked into the design from day one. Splitting to N processes is a
config change, not a rewrite.

Owns:
- `idx.spatial.cell.<x>_<y>.delta` (entity entered/exited cell events)
- `idx.spatial.query` (request/reply for radius queries, polygon queries,
  line-of-sight checks)

Consumes the entity state firehose. Maintains a uniform-grid spatial hash
internally; quadtree later if density warrants.

### 5. Persistence — mixed storage shape

| State type | Storage | Cadence |
|---|---|---|
| Pose / fast-changing sim state | Never persisted | — |
| Player inventory | JSONB blob per player | On change, batched |
| Market / tradeable items | Relational table | On change |
| World structures + claims | Relational table | On change |
| Damage / event log | JetStream KV with TTL → wipe | Per event |
| Account / cosmetics / veteran tier | Relational, account scope | On change, persists across wipes |
| Discipline progress | Relational, character scope | On level event |
| Fog-of-war map state | JSONB blob per character | On chunk-discover event |

`persistence-writer` service is the sole PG writer. Consumes change
streams from JetStream; batches PG writes; never on the hot path.

**Stream shape (NATS 2.14+):** ack-once event streams (damage events,
market trades, cross-cell handoffs) use **workqueue** retention with
`persistence-writer` as the exactly-once consumer; audit/replay
consumers attach via **mirror** streams (sourcing from workqueue
streams was unblocked in 2.14, ADR-60). Producer writes once; the
broker handles fanout. Disable redundant dedup on the audit mirror
when the source's dedup window is authoritative.

### 6. Hibernation rules — mixed

- Ship at sea = always raidable (always-on PvP)
- Short grace timer (~5 min) when last crewmember disconnects mid-voyage
- Anchored at **owned anchorage** = protected during defined raid windows
  (data-driven schedule per cycle)
- Outside owned anchorage = exposed

Forces meaningful "park your ship safe" gameplay; doesn't trivialize PvP.

### 7. Pose compression — ~16 B/pose

- Position: quantized to 1 cm relative to last keyframe (6 B for 3 axes
  within cell range)
- Rotation: smallest-three quaternion (4 B)
- Velocity delta from keyframe (4 B)
- Cell ID when crossing keyframe boundary (2 B optional)

Baked into the protocol layer. Reusable for ships, characters, and
projectile observation.

### 8. JetStream usage map (treat as architectural API)

| Subject pattern | Transport | Why |
|---|---|---|
| `sim.entity.<id>.state` | Core NATS | High-rate lossy, latest-value |
| `sim.entity.<id>.event.*` | JetStream | Reliable, replay |
| `idx.spatial.cell.<x>_<y>.delta` | JetStream | Reliable, ordered |
| `env.cell.<x>_<y>.*` | JetStream KV | Latest-value durable |
| `chat.*` | Core NATS | Tolerant to loss |
| Voice | Separate WebRTC SFU | Off the gameplay path entirely |

### 9. Replication tier system — 5 tiers

| Tier | Range | Rate | What's replicated |
|---|---|---|---|
| 0 (always) | any | 30 Hz | Hull pose, gross silhouette flags (own ship + radar contacts) |
| 0.5 (fleet aggregate) | horizon (~2 km) | 5 Hz, per-cluster | Cluster centroid + count + heading + silhouette mask. Distant entities replicated as group summaries, not individually. See [08 §3.2a](08-phase1-architecture.md#32a-tier-05--fleet-aggregate-horizon-lod). |
| 1 (visual) | <500 m | 60 Hz pose; on-change rest | Per-sail state, cannon-port armed flags, sail force |
| 2 (close combat) | <150 m | On change | Per-plank damage, cannon orientations, visible crew |
| 3 (boarded) | aboard same ship | On change | Below-deck contents, individual crew animations, aboard-player local poses |

Mechanism in code; thresholds in `data/tier_distances.yaml`. First-pass
thresholds — tune from milestone-1.5 stress test.

Tier 0.5 was added 2026-04-29 after the §1 BW math at 50 ships/cell
showed individual-pose replication beyond 500 m breaks the ≤1 Mbps/client
budget. See [08-phase1-architecture.md §3.2a](08-phase1-architecture.md#32a-tier-05--fleet-aggregate-horizon-lod)
for mechanism, message shape, and promotion/demotion rules.

### 10. Voice transport — LiveKit SFU

[LiveKit](https://livekit.io/) — open source, self-hostable, mature
WebRTC SFU. Spatial-filter at SFU layer; players subscribe to nearby
crew + own ship. P2P fallback for same-ship voice on small crews. Off
the NATS path entirely; never competes with gameplay BW budget.

## Service mesh

Eight services. Two existing in fallen-runes; six new for notatlas.

| Service | Source | Tick / cadence | Owns |
|---|---|---|---|
| **gateway** | fallen-runes | per-client | Client connections, auth handoff, per-client interest set |
| **auth** | fallen-runes | login event | Account, JWT, hardware-2FA for admins |
| **ship-sim** | new | 60 Hz | All 60Hz rigid-body authority: per-ship physics (hull/sail/cannon/damage state) + free-agent player physics (Jolt body when not aboard a ship). Aboard-ship players live as ship-local passenger entries on the ship they're attached to. Board / disembark = one-shot transition at this service. See [08 §2A](08-phase1-architecture.md#2a-ship-sim-scope-ships-and-free-agent-players). |
| **cell-mgr** | new | 10-30 Hz aggregation | Spatial interest within one cell region |
| **spatial-index** | new | continuous | Entity → cell membership, radius queries |
| **env** | new | 5 Hz, persisted | Wind field, weather, wave seed, time of day |
| **persistence-writer** | new | seconds-scale, batched | Sole PG writer, consumes change streams |
| **voice-sfu** | new (LiveKit) | per-client audio | Spatial-filtered voice |

Future services to be added as needed: `ai-sim` (NPC crew, hostile ships,
wildlife), `market` (trade matching), `match` (raid window scheduling).

## NATS subject scheme

Identity-keyed for mobile entities, cell-keyed for static/environmental
state.

```
# Mobile entities (Option B from subject-scheme analysis)
sim.entity.<id>.state              # core NATS, 60Hz pose firehose
sim.entity.<id>.event.<kind>       # JetStream, damage/fire/sink/etc.
sim.entity.<id>.input              # client → entity-owning service

# Cell-bound environmental state (Option D)
env.cell.<x>_<y>.weather           # JetStream KV
env.cell.<x>_<y>.wind              # JetStream KV
env.cell.<x>_<y>.terrain.delta     # JetStream

# Spatial index
idx.spatial.cell.<x>_<y>.delta     # JetStream, entity in/out events
idx.spatial.query                  # request/reply

# Cross-service control
gw.client.<connection_id>.cmd      # gateway-internal
admin.audit.<event>                # JetStream, all admin actions

# Chat
chat.global
chat.company.<company_id>
chat.proximity.<cell_x>_<cell_y>
```

## What this gives you

- **No serialize/teleport stutter at boundaries.** The entity's subject
  doesn't change; only subscribers' interest sets do.
- **No "ship eaten by handoff."** The ship process is unaffected by cell
  boundaries.
- **Idle cells cost ~zero.** No entities means no subscriptions means no
  fanout.
- **Cells can be added without coordinating with neighbors.** New cell
  process subscribes to its spatial subjects; no neighbor IP-list to
  reconfigure.
- **Ship-sim hosts can be moved orthogonally to cell topology.** A ship-
  sim process can hold ships from any region; load-balance independently.
- **Wipe-time schema migrations.** Every 10 weeks the world resets;
  schema can change too.
