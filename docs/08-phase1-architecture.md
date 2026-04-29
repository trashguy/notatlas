# 08 — Phase 1 Architecture

How notatlas's networking layer (Phase 1, M6 → M9 + integration + combat
slice) is built on top of fallen-runes' service substrate, and where it
diverges. Companion to [02-architecture.md](02-architecture.md), which
locks the *what*; this doc covers the *how* for the first networked
milestone.

Status: **ratified 2026-04-29**. All 11 decisions + 4 previously-open
questions resolved; M6.1 cleared to start. Treat as locked unless
explicitly revisited (same rule as `02-architecture.md`'s 10 locked
decisions).

## 1. Reuse map

fallen-runes' server stack carries about 60% of what Phase 1 needs. The
remaining 40% is the cell-grid + 4-tier interest layer fallen-runes
doesn't have, because fallen-runes is single-zone-per-server while
notatlas is one logical world split across cells.

Classification below is based on a code survey of
`~/Projects/fallen-runes` against the locked decisions in
[02-architecture.md](02-architecture.md).

### 1.1 Lift as-is (vendor or reference unchanged)

| File / dir in fallen-runes | What it does | Notes |
|---|---|---|
| `src/shared/nats/nats.zig` | NATS client wrapper around `nats-zig` | Connection lifecycle, subscribe/publish, JetStream surface |
| `src/shared/nats/messages.zig` | Wire-message envelopes (LoginResponse, ZoneAssignResponse, ZoneHeartbeat, etc.) | Add `CellId` variants; keep PlayerId / Status / timestamp shapes |
| `src/shared/resilience/circuit_breaker.zig` | Three-state breaker (closed/open/half-open) with configurable threshold + open-duration | Battle-tested, no changes needed |
| `src/shared/resilience/health.zig` | Health reports + status aggregation | Plug into Prometheus the same way |
| `src/shared/resilience/request_context.zig` | Correlation IDs + timeout budgets across NATS req/reply | Critical for cross-service trace; reuse |
| `src/shared/net/bandwidth.zig` | Per-client sliding window (64 samples × 1s) + quality levels + priority drops | Framework lifts; plug in notatlas's tier priorities (own → visual → combat → boarded) |
| `src/shared/net/compression.zig` | Generic byte-stream compression | Reuse for chat / event streams; pose has its own codec (M7) |
| `Makefile` + `infra/compose.yml` + `infra/mmo-up.sh` | Local NATS + PG + Prometheus + service launch | Adapt service list; container set is fine |

### 1.2 Lift with reshape

| File / dir | What changes for notatlas |
|---|---|
| `src/services/gateway/service.zig` (~500 lines) | Stateless TCP→NATS relay, JWT, session lifecycle. Reshape: instead of subscribing to `fr.zone.<id>.broadcast`, subscribe per-client to the four tier subjects (`sim.entity.<id>.{self,visual,combat,boarded}`) the interest filter has selected for that client. Outbound input goes to `sim.entity.<player_id>.input`. |
| `src/services/zone_server/service.zig` tick loop (lines ~205-246) | Fixed-timestep loop pattern is exactly what `ship-sim` needs. Reshape: bump tick to 60 Hz (see §2.3), and replace the `broadcastZoneState` call with per-tier publish driven by the interest filter (§3). Input handling (relay_sub) stays. |
| `src/services/zone_server/zone_game_state.zig` | ECS host pattern for "the thing the tick mutates." For ship-sim, the equivalent is per-ship Jolt body + buoyancy + sail/cannon component state. Lift the structure (init / tick / get-state / metrics), not the contents (NPC AI + party combat is fallen-runes-specific). |
| `src/shared/spatial_hash.zig` | fallen-runes uses it for collision + 30-unit aggro queries. Reshape: use the same uniform-grid primitive as the foundation for the spatial-index service (§4 of [02](02-architecture.md)) and for cell membership checks. Don't try to reuse it as the cell manager itself. |
| `src/shared/net/protocol/entity_state.zig` | float32-throughout state packet (~28 B). Doesn't fit notatlas's locked 16 B/pose. Replace with the M7 pose codec; keep the protocol module layout. |
| `src/shared/nats/subjects.zig` | Convention is sound (`<prefix>.<domain>.<id>.<action>`). Reshape: rename prefix `fr.` → `sim.` / `env.` / `idx.` per the locked subject map in [02-architecture.md §NATS subject scheme](02-architecture.md#nats-subject-scheme). |

### 1.3 Build new (no fallen-runes precedent)

- **`cell-mgr` service** — fallen-runes is single-zone-per-server. notatlas
  is one ocean split into cells, dynamic membership. See §2.
- **`spatial-index` service** — exists as a per-zone hash inside
  `zone_server` in fallen-runes; notatlas extracts it into its own
  process. See [02 §1.4](02-architecture.md).
- **4-tier interest filter** — fallen-runes broadcasts zone-wide
  (1 tier). See §3.
- **Pose codec** (M7) — see [03 §7](03-engine-subsystems.md).
- **Deterministic projectile** (M8) — see [03 §8](03-engine-subsystems.md).
- **Lag-comp + rollback** (M9) — see [03 §9](03-engine-subsystems.md).
- **Ship-as-vehicle network state** — passenger-relative pose, board /
  disembark transitions. New for notatlas.
- **`env` service** — fallen-runes has no analog. Trivial to stand up
  (5 Hz tick, publishes wind / weather to `env.cell.<x>_<y>.*`).
- **`persistence-writer` service** — fallen-runes' `src/shared/db/` has
  models + a synchronous-write code path. Phase 1 only needs the
  framework; the dedicated writer service stands up alongside cell-mgr
  in Phase 2 when there's actual cross-cell state to persist.

### 1.4 Reference, do not import

The fallen-runes renderer (`src/client/renderer/`) and 2D path are read
for patterns only. Restated from [03 §reuse table](03-engine-subsystems.md).

## 2. cell-mgr service

The first new service this phase introduces. Owns the dynamic
"who-is-in-this-cell" set and publishes per-cell aggregate updates.
Pairs with the `spatial-index` service ([02 §1.4](02-architecture.md));
spatial-index is the global membership oracle, cell-mgr is the per-region
aggregator and gatekeeper for tier-1 broadcasts.

### 2.1 Responsibilities

- Subscribe to `idx.spatial.cell.<x>_<y>.delta` for its assigned cell(s).
- Maintain in-memory `entities_in_cell : HashMap(EntityId, EntityPose)`.
- Publish aggregate cell snapshots (entity list + tier-0 poses) at the
  tick rate of its slowest subscriber tier (Tier 0 is 30 Hz per
  [02 §9](02-architecture.md)).
- Track per-client interest sets ("client C wants tiers ≤ T from
  cell <x>_<y>") and forward filtered updates.
- Hold static cell state (anchorages, terrain features) in
  `env.cell.<x>_<y>.*` — read-only from cell-mgr's POV; written by
  the `env` service / persistence-writer.

### 2.2 Boundary with spatial-index

| Concern | Owner |
|---|---|
| Entity → cell membership | spatial-index |
| Membership change events | spatial-index publishes to `idx.spatial.cell.<x>_<y>.delta` |
| Per-cell entity *state aggregation* | cell-mgr |
| Tier filtering for per-client outbound | cell-mgr |
| Radius queries (e.g. "what's within 150m of point P?") | spatial-index (request/reply on `idx.spatial.query`) |

cell-mgr never recomputes membership. It trusts spatial-index's deltas.

### 2.3 Tick rate

cell-mgr does not run a physics tick. It runs a **fanout tick** at
30 Hz, matching tier-0 cadence. Tier-1 (60 Hz visual) traffic is not
gated by this loop — entity state messages are relayed as they arrive
on NATS. The fanout tick exists to drive the per-tier composition pass
at the slowest cadence cell-mgr is responsible for.

**State model:** NATS callbacks fire continuously as messages arrive on
subscribed subjects, keeping an in-memory `entities_in_cell : HashMap`
up to date. Membership deltas (`idx.spatial.cell.<x>_<y>.delta`) and
entity state updates (`sim.entity.<id>.state`) all mutate this table
directly via callback.

**Tick action (every 33 ms):**

1. Walk current subscribers; for each, run the interest filter (§3) over
   `entities_in_cell` to compute the per-subscriber tier set.
2. Compose per-subscriber payload at tier ≤ 0.5 cadence from latest
   state.
3. Publish on per-client subjects (gateway forwards).

Higher-rate streams (tier-1 visual @ 60 Hz, tier-2 close-combat
on-change) flow callback-to-publish without waiting for the fanout
tick — the tick only owns the slow lane.

Cells with zero entities and zero subscribers do nothing — no
subscriptions, no callbacks, no fanout work. Idle ocean is free.

### 2.4 Process model

Single binary, configured at runtime with the set of cells (or sub-cell
quadrants) it owns. The same binary supports three deployment shapes,
selected dynamically based on load:

| Shape | When | Mechanism |
|---|---|---|
| **1:1** — one process per cell | Phase 1 default; production hot regions | Process configured with a single cell id |
| **Packed** — N cells per process | Low-pop regions; idle ocean | Process configured with a list of cell ids; each cell's subscriptions, entity tables, and fanout loops run independently inside the same process |
| **Sub-cell** — M workers per cell | Extreme single-cell density (200+ players in one fight) | Multiple processes share a cell; each subscribes to the full cell's entity firehose, but splits the *subscriber set* — e.g. one process handles NW-quadrant subscribers, another handles SE-quadrant. No state coordination between them |

**No inter-cell-mgr coordination required for the steady state** — every
process subscribes to its own NATS subjects, builds its own state from
the firehose, fans out to its own subscribers. Identical entity-state
tables on multiple processes are not "duplication to keep in sync";
they're parallel materializations of the same NATS-delivered stream
(same property §7.1 uses for spatial-index HA).

**Re-sharding is a sub/unsub operation, not a state migration.** When a
cell moves between processes:

1. New process subscribes to the cell's entity firehose; warms the
   in-memory table from a few seconds of inbound state.
2. Coordinator (or NATS leader-lock on `cell.<x>_<y>.fanout_owner` KV
   key) tells the old process to drain — stop publishing per-client
   payloads.
3. New process acquires the lease and starts publishing.
4. Old process unsubscribes.

Overlap window ≈ 1-3 sec. Subscribers see at most a few duplicated
frames (gateway dedupes by sequence number); never a gap.

### 2.4a Sub-cell partitioning mechanism

For the high-density case (200 subscribers in one cell):

```
                       ┌──────────────────────────────┐
                       │ cell [4,5] entity firehose   │
                       │ sim.entity.<id>.state       │
                       └──┬────────────────────────┬──┘
                          │ both subscribe         │
                          ▼                        ▼
                   cell-mgr-NW [4,5]        cell-mgr-SE [4,5]
                   ├ owns subscribers       ├ owns subscribers
                   │  whose pos.x < cx        whose pos.x ≥ cx
                   ├ runs full filter       ├ runs full filter
                   │  over all entities       over all entities
                   │  in the cell             in the cell
                   └ publishes to its       └ publishes to its
                     subscribers' streams    subscribers' streams
```

Each sub-cell-mgr subscribes to the **whole cell**'s entity firehose —
not a sub-region. Splitting is purely a fanout-work distribution; the
filter still needs every entity for tier-0/0.5 decisions. The 2×
firehose ingest cost (~12 MB/sec at 50 ships/cell vs. 6 MB/sec single)
is acceptable; the win is halving the per-subscriber filter pass cost.

Subscriber assignment is by position quadrant (or octant if M=4). When
a subscriber's position crosses the internal split, they're handed off
between sub-cell-mgrs the same way cells hand off between processes —
brief overlap, lease swap, drain.

**Phase 1 doesn't ship sub-cell partitioning.** It's the architectural
escape hatch for when the Milestone 1.5 stress gate reveals that single-
process per-cell can't sustain 200/cell subscribers cleanly. Documented
here so we don't make any decision that closes the door.

### 2.4b Predictive scaling (Phase 2+)

The architecture supports **anticipatory scaling**: spin up a hot
cell-mgr ahead of arriving players based on movement vectors.

Mechanism:
- Coordinator service subscribes to `idx.spatial.cell.<x>_<y>.delta` and
  computes per-boundary crossing rates + average velocity vectors per
  cell.
- "Cell [4,6] crossing rate from [4,5] is 12 entities/min, avg velocity
  +3 m/s east" → in 30s the cell will need a hot cell-mgr.
- Scheduler pre-warms a process: it subscribes, builds its entity table,
  is ready to acquire the fanout lease the moment density crosses the
  promotion threshold.

Symmetric demote: when cell density drops below the pack threshold for
N seconds, coordinator merges the cell into a packed neighbor process
and shuts down the dedicated process.

This is operationally complex and adds a coordinator service. **Phase 1
ships static config**; the architecture supports the dynamic case so we
can layer it on without rework. Coordinator design = open issue for
Phase 2.

### 2.5 What does NOT live in cell-mgr

- **Ship physics.** That's `ship-sim`. cell-mgr only consumes ship state
  via `sim.entity.<ship_id>.state`.
- **Player input.** Goes from gateway directly to the entity-owning
  service via `sim.entity.<player_id>.input`. cell-mgr is fanout-only.
- **Persistence.** cell-mgr is RAM-only. Anything durable goes through
  `persistence-writer` via JetStream.

## 2A. ship-sim scope: ships AND free-agent players

`ship-sim` is the locked service name from [02 §service mesh](02-architecture.md),
but its scope is **all 60Hz rigid-body authority** — not just ships. The
name is historical; the responsibility is "every entity whose physics
needs a 60Hz auth tick + Jolt body + buoyancy / character control."

### 2A.1 Two states a player can be in

| State | Physics | Pose subject | Pose frame |
|---|---|---|---|
| Aboard ship (M5.3 SoT pattern) | none of their own — part of ship's passenger list | `sim.entity.<ship_id>.state` carries it as ship-local pose at tier-3 boarded; tier ≤ 2 only sees the ship hull | ship-local |
| Free-agent (swim, walk, fall) | Jolt body owned by ship-sim | `sim.entity.<player_id>.state` @ 60Hz | world |

The `Player.attached_ship: ?u32` field set up in M5.3 is exactly this
distinction extended across the network boundary. A player is
`attached_ship == null ⇔ free-agent`.

### 2A.2 Board / disembark = one-shot transition at ship-sim

**Disembark** (player falls off, jumps off, ship sinks under them):
1. ship-sim computes world pose: `world_pose = ship_pose ⊗ player.local_pose` at the current physics tick.
2. ship-sim creates a free-agent Jolt body for the player at `world_pose`, with linear velocity inherited from `ship.lin_vel + ship.ang_vel × lever`.
3. ship-sim removes the player from the ship's passenger list.
4. New `sim.entity.<player_id>.state` subject starts publishing world-frame poses.
5. spatial-index sees a new entity at `world_pose`, emits `idx.spatial.cell.<x>_<y>.delta` (enter).
6. The cell-mgr in that cell subscribes to the player's state subject; tier filter starts running on the new entity.

**Board** (climb a ladder, grab a rope):
1. ship-sim destroys the free-agent Jolt body.
2. Computes ship-local pose: `local_pose = inverse(ship_pose) ⊗ player.world_pose`.
3. Adds player to ship's passenger list with that local pose.
4. The free-agent state subject stops publishing; player's pose now flows through the ship's tier-3 boarded stream.
5. spatial-index emits `idx.spatial.cell.<x>_<y>.delta` (exit) for the player's free-agent entity. cell-mgr unsubscribes.

Both transitions are one-shot — no continuous reconciliation between the
two frames. Same pattern that made M5.3's local-frame walk jitter-free,
extended across the net.

### 2A.3 Cell crossings are irrelevant to player ownership

The whole point of [02 §headline innovation](02-architecture.md) — owning
process is decoupled from spatial location — applies symmetrically to
free-agent players. A player swimming across the boundary between [8,5]
and [8,6] triggers:

- spatial-index emits exit + enter deltas
- map-server[8,5] unsubscribes from `sim.entity.<player_id>.state`, map-server[8,6] subscribes
- ship-sim is untouched — the player's Jolt body keeps integrating in the same process

No state migration. No "node line lag" for a swimmer crossing a boundary
mid-fight. Same property ships have.

The "fall off ship between cells" worst case decomposes to: a ship cell
crossing (sub/unsub on ship subject) + a disembark transition (ship-sim
internal) + a player free-agent enter (sub on player subject). Three
cheap NATS operations, none requiring state to leave ship-sim.

### 2A.4 Player lifecycle transitions table

| Transition | What ship-sim does |
|---|---|
| Login, last logout was free-agent | Create free-agent Jolt body at last-known world pose |
| Login, last logout was aboard ship X | Append to ship X's passenger list at last-known local pose; no body created |
| Logout while aboard | Passenger entry persists with grace timer (~30 s); body never created |
| Logout while free-agent | Free-agent body destroyed (or held with grace if combat-tagged — TBD per hibernation rules) |
| Death | Free-agent body → corpse-loot-container (separate entity type, lower tick rate); state subject stops |
| Swim ↔ walk | Same body; ship-sim selects gravity / water-sample params per surface contact |

### 2A.5 Why not a separate `player-sim` service?

Tempting (clean separation of concerns), but rejected because:

1. **Service count is locked at 8** in [02 §service mesh](02-architecture.md). Adding a 9th re-opens that decision.
2. **The transition is the hard part**, not the steady state. Board / disembark crosses a frame (world ↔ ship-local) plus a body-creation event. Splitting that across two services means a NATS round-trip in the middle of a ladder grab — exactly the kind of two-integrators-chasing-each-other failure mode the M5.3 pattern was designed to avoid.
3. **Co-location is cheap.** Free-agent player physics is a capsule controller with water sampling — order-of-magnitude cheaper per entity than ship physics. ship-sim's per-tick CPU budget tolerates them trivially.
4. **Sharding is symmetric.** When ship-sim grows beyond one process, the sharding key is "entity ID range" or "load balance" — applies to ships and free-agent players identically. No reason to shard them on different axes.

Net: ship-sim is the rigid-body authority; "ship" in the name is
historical. Doc updates to [02 §service mesh](02-architecture.md) row
will reflect this.

## 3. 4-tier interest filter

The replication mechanism specced in [03 §6](03-engine-subsystems.md),
realized as a module shared between cell-mgr and ship-sim.

### 3.1 Module shape

`src/shared/replication/` (new). Surface:

```zig
pub const Tier = enum(u8) { always, fleet_aggregate, visual, close_combat, boarded };

pub const Subscriber = struct {
    client_id: ClientId,
    pos_world: [3]f32,
    aboard_ship: ?EntityId,  // for tier-3 boarded
};

pub fn effectiveTier(
    subscriber: Subscriber,
    entity_pos: [3]f32,
    entity_ship: ?EntityId,  // ship the entity is aboard, if any
    thresholds: TierThresholds,
) Tier;

pub fn shouldReplicate(field_tier: Tier, subscriber_tier: Tier) bool;
```

### 3.2 Threshold source

`data/tier_distances.yaml`, hot-reloadable, as called out in
[02 §9](02-architecture.md). First-pass values:

```yaml
tiers:
  always:          { range_m: inf,  rate_hz: 30 }
  fleet_aggregate: { range_m: 2000, rate_hz: 5  }   # cluster summary, not per-entity
  visual:          { range_m: 500,  rate_hz: 60 }
  close_combat:    { range_m: 150,  rate_hz: on_change }
  boarded:         { range_m: 0,    rate_hz: on_change }  # gate: same ship_id
```

Tune from the Milestone 1.5 stress test, not from synthetic M6.

### 3.2a Tier 0.5 — fleet aggregate (horizon LOD)

**Problem this solves.** Without it, a player who can see a fleet of 20 ships
on the horizon pays for 20 individual 60 Hz pose streams (≈19 KB/s) for
silhouettes they can't visually distinguish. Long-range observation —
"there's a fleet to the east, sail toward it" — is foundational pirate-MMO
gameplay, so the cost has to be near-zero.

**The mechanism.** Beyond the visual range threshold (500 m), distant
entities are not replicated individually. They're clustered into per-cell
aggregates and summarized once per cluster.

**Message shape (sketch):**

```zig
pub const FleetAggregate = struct {
    centroid: [2]f32,        // x,z world position
    radius_m: f32,           // bounding radius of cluster
    count: u8,               // number of entities in cluster
    heading_deg: u16,        // mean heading (q14.2)
    silhouette_mask: u8,     // sloops/schooners/brigantines bits set
    // optional: outer convex hull as ~4-6 quantized points
};                           // ~16-24 B per cluster
```

**Cost comparison at 20 distant ships in one cluster:**

| Mode | BW per observer |
|---|---|
| Individual at tier-1 | 20 × 60 × 16 B = 19.2 KB/s |
| Fleet aggregate at tier 0.5 | 1 × 5 × 24 B = 120 B/s |

**~160× reduction.**

**Producer.** `spatial-index` is the natural owner — it already knows
entity positions per cell. A cheap O(N) clustering pass per cell at 5 Hz
(bucket entities by sub-cell + average) produces aggregates and publishes
on `idx.spatial.cell.<x>_<y>.fleet_aggregate`. cell-mgr forwards the
relevant aggregates to subscribers as part of the per-client tier ≤ 0.5
set.

**Promotion / demotion.** When an entity in an aggregate crosses into a
subscriber's tier-1 visual range, the aggregate's `count` decrements by
one and the subscriber starts receiving that entity's individual pose
stream from that tick. Symmetric on demotion. Continuity is preserved:
the cluster centroid never includes an entity already being individually
streamed to that subscriber.

**Client-side.** Renders distant ships as silhouettes / sail markers
spread procedurally within the cluster radius — looks like a fleet on the
horizon. When the cluster is "approached," individual ships fade in
naturally as they promote to tier-1.

**What this enables.** Sailing across an ocean and spotting a fleet at
2 km does not blow the per-client BW budget. Combined with tier-1
shrinking from 500 m → ~300 m once we have aggregate, the close-combat
fanout cost drops further. This is the lever that makes "seamless
seamless world with horizon-visible fleets" affordable per [02 §9
locked decision](02-architecture.md).

### 3.3 Where the filter runs

Two consumers in v1:

1. **cell-mgr fanout** — when assembling per-subscriber payloads at the
   30 Hz fanout tick.
2. **ship-sim direct publish** — for tier-2/3 events (e.g. plank
   damage), ship-sim publishes to a per-tier subject and the filter
   on the consumer (cell-mgr) decides what each client gets.

Filter is *pure* — no I/O, no state. Trivially testable.

## 4. NATS subject namespace decision

fallen-runes uses `fr.*`. notatlas locked `sim.*` / `env.*` / `idx.*` /
`gw.*` / `admin.*` / `chat.*` per [02-architecture.md §NATS subject scheme](02-architecture.md#nats-subject-scheme).

**Decision:** the prefix split is intentional and enforced. notatlas
runs against its **own** dev NATS cluster (separate `infra/compose.yml`
service). Sharing a NATS cluster between fallen-runes and notatlas dev
is forbidden — the wildcard subscriptions in `chat.*` / `sim.*` /
`env.*` will collide with `fr.chat.*` / `fr.zone.*` in opaque ways.

Tools that read from both projects (e.g. cross-project debug viewer)
filter at the consumer, never at the cluster.

## 5. Land mines surfaced by the survey

These are concrete fallen-runes patterns that look reusable but
conflict with locked notatlas decisions. Document so we don't accidentally
port them.

### 5.1 `WORLD_ZONE_ASSIGN` is not the cell lookup pattern

fallen-runes' world-controller treats zone membership as **permanent +
HTTP-discoverable** (`fr.world.zone.assign`, `fr.world.zone.lookup`).
Notatlas cell membership is **dynamic** (you sail across boundaries
mid-session, no rezone). Build a NATS-only cell lookup driven by
spatial-index deltas. Do not port world-controller's machinery.

### 5.2 Tick rate is config-overridable but not free

`zone_server/config.zig:22` and `zone_game_state.zig:67` default
`tick_rate = 20`. Bumping to 60 in config is one line, but the
buffer-sizing / interpolation / rollback windows around it all assume
50 ms ticks. Audit before flipping:

- `zone_server/service.zig:205` — `tick_interval_ns` derives from config, fine.
- Any constants of the form `N_TICKS` (5-tick input buffer, 10-tick
  rollback ring) — recheck against 16.7 ms ticks.
- Bandwidth budgets (`bandwidth.zig` quality tiers) are KB/s, not
  per-tick — fine.

### 5.3 JWT lifetime tuned for PvE-coop, not PvP-MMO

fallen-runes issues self-verifying JWTs with a long lifetime
(check `src/services/auth/service.zig` for `exp` claim). PvP context
wants short-lived tokens + activity-tied refresh — a 24-hour token is
24 hours of grief surface from a stolen credential. **Action:** add a
heartbeat-bound refresh in the auth handoff before scaling Phase 1.
Not blocking for M6 synthetic, blocking before integration milestone.

### 5.4 Entity-ID generation tags

fallen-runes increments NPC IDs forever (`0x1_0000+`). Ships in
notatlas destroy / respawn frequently; without a generation tag,
clients with stale subscriptions can attach to a recycled ID.
**Action:** ship/entity IDs in notatlas are `(u32 id, u16 generation)`
from day one. Encode the generation into the pose stream key so stale
subscribers are evicted on mismatch.

### 5.5 Bandwidth framework was never load-tested at our scale

`bandwidth.zig` has the throttling primitive but fallen-runes has not
exercised it at notatlas's target (200 players × 30 ships ×
~1000 projectiles, ≤1 Mbps/client). The Milestone 1.5 stress gate
(see [04-roadmap.md](04-roadmap.md)) is the actual load test. Don't
mistake "the code exists" for "the budget holds."

## 6. M6 sub-milestone breakdown

Same shape as M3/M4/M5 in `current_work.md` — small, gated, with a
runnable artifact at each step. M6 is "tier-replication mechanism
proven in synthetic test" — it does not require ship-sim, gateway, or
network packets to be in place; just the filter + cell-mgr fanout
under controlled inputs.

| Step | Deliverable | Gate |
|---|---|---|
| **M6.1** | `src/shared/replication/` module: `Tier` (5 variants including `fleet_aggregate`), `Subscriber`, `effectiveTier`, `shouldReplicate`, plus the cluster-builder primitive used by spatial-index for tier 0.5 (O(N) bucket-and-average per cell at 5 Hz). Pure functions, no I/O. `data/tier_distances.yaml` + ymlz loader. | 100% unit test coverage on tier transitions including (a) boarded special case, (b) fleet aggregate promotion when an entity crosses into tier-1 visual range, (c) symmetric demotion when it sails back out, (d) `count` decrement / increment correctness so a subscriber never sees an entity in both their aggregate and their individual stream simultaneously. Filter latency <500 ns per (subscriber × entity) call; clustering pass <100 µs per cell at N=50. |
| **M6.2** | `replicated(T, tier)` field wrapper from [03 §6](03-engine-subsystems.md). Change detection (dirty bit + last-published value). Minimal ECS-side glue so a struct of `replicated` fields can be iterated. | Roundtrip test: mutate fields at varied tiers, observe correct dirty-set per tier. |
| **M6.3** | Stand up `cell-mgr` skeleton: NATS connect, subscribe to `idx.spatial.cell.0_0.delta`, in-memory entity table, 30 Hz fanout tick. No real spatial-index yet — drive deltas from a test harness. | Process runs against local NATS, prints per-tick "I have N entities, F subscribers." |
| **M6.4** | Wire the filter into cell-mgr's fanout. Per-subscriber payload assembly. Publish to `gw.client.<id>.cmd` (gateway forward stub). | Synthetic test from [03 §6](03-engine-subsystems.md) gate: 100 entities, 50 subscribers at varied positions; assert each subscriber receives correct tier set + nothing extra. Run for 60 s, no allocations on the hot path (verify with allocator counters). |
| **M6.5** | Bandwidth measurement under M6.4 synthetic load. Confirm payload sizes are within budget (the actual 16 B/pose comes in M7; for M6 a fixed-size placeholder pose is fine). | Per-subscriber BW ≤ Tier 0 budget at idle, scales with tier escalation as expected. Numbers logged to `docs/research/m6-bandwidth.md` for reference. |

**M6 phase gate** (= [03 §6 milestone gate](03-engine-subsystems.md)):
synthetic test green + bandwidth measured matches expected.

**Out of scope for M6** (queued for M7+):
- Real pose compression (M7).
- Real spatial-index service — M6 fakes the delta stream.
- gateway integration — M6 publishes to a stub subject, gateway forwarding wires up at integration milestone.
- ship-sim — M6 entity sources can be a fake "synthetic ship pose generator."

## 7. High availability

Single-process services are availability holes. Phase 1 must run with
hot standbys for the failure modes we can address; the ones we can't
yet (ship-sim) are flagged as Phase 2+ work.

### 7.1 spatial-index — active/standby N=3

**Pattern.** Three spatial-index processes run continuously. Only one
is "leader" — the role of publishing deltas, fleet aggregates, and
serving radius queries. The other two are state-current standbys.

**Key insight: standbys don't replicate from the leader.** They each
subscribe independently to the `sim.entity.*.state` firehose and build
identical in-memory tables from the same source data. There's no
leader→follower replication lag; all three see entity state at
approximately the same NATS callback time.

```
sim.entity.*.state ──┬──► spatial-index-A (LEADER — owns publish + query roles)
                     ├──► spatial-index-B (standby — state-current, role-idle)
                     └──► spatial-index-C (standby — state-current, role-idle)

   Leader election: NATS KV optimistic lock on `idx.spatial.leader`,
   leased lock with TTL. Heartbeat-renewed every 1 sec. TTL 3 sec.
```

**Failover budget: ~3-5 seconds.**

| t | Event |
|---|---|
| 0 | Leader process dies (crash, OOM, network partition) |
| 0–3 s | KV lease expires; no heartbeat renewal |
| 3 s | Standbys detect lease expiry; race to acquire; winner wins |
| 3–5 s | New leader's first delta tick fires; catch-up deltas computed by diffing current state vs. last-published state |

**Why deltas survive cleanly:** `idx.spatial.cell.<x>_<y>.delta` is
JetStream per [02 §8](02-architecture.md#8-jetstream-usage-map-treat-as-architectural-api).
Durability + ordered replay is automatic. cell-mgrs are JetStream
consumers; new leader's catch-up deltas slot in via JetStream cursors.
No lost or duplicated events from any consumer's view.

**Why radius queries survive:** they're NATS req/reply on
`idx.spatial.query`. During the failover gap, in-flight queries time
out — callers retry. Caller-side retry budget is the operational
control here (deterministic projectile hit res in M8 needs a hard
deadline; document the retry policy in M8 spec).

### 7.2 Standbys are HA-only, not load-bearing for queries

Tempting to use standbys as read-replicas for radius queries
(distribute query load across all three). Rejected for Phase 1
because:

- Standby state is eventually-consistent at NATS-callback granularity
  (~ms behind leader).
- Deterministic projectile hit detection (M8) is sensitive to that lag
  — a query against a stale standby can miss a hit the leader would
  have caught.
- Single-leader serves all queries; CPU budget is comfortable
  (~1% of one core at Phase 4 estimate).

Revisit only if profiling at 10× target load shows query throughput as
a bottleneck.

### 7.3 Failover coverage for other singletons

Same NATS-everywhere pattern applied across the service mesh:

| Service | Failover criticality | Approach | Phase |
|---|---|---|---|
| spatial-index | Critical (touches everything) | Active/standby N=3 with NATS KV leader-elect | Phase 1 |
| env | Low (5 Hz weather, can survive 30s gap) | Active/passive N=2, simple restart | Phase 1 |
| persistence-writer | Medium | JetStream consumer-group (auto-failover built in); run N=2 as one consumer group | Phase 1 |
| auth | Medium | Stateless behind NATS req/reply; run N=2 with shared NATS subject | Phase 1 |
| gateway | Low per-process (clients reconnect to next gateway) | Run N≥2 with health-check-driven client routing | Phase 1 |
| **ship-sim** | **High but harder problem** | Ship physics state lives in-process. Crash = state lost. Needs periodic checkpoint to JetStream + new ship-sim takes over from last checkpoint, with a small replay window. | **Phase 2+ open question** |
| cell-mgr | Medium (subscribers see ~1s of stale fanout) | Lease-based fanout ownership (§2.4); standbys can take over the lease | Phase 1 |
| voice-sfu | External (LiveKit cluster handles its own HA) | — | — |

### 7.4 ship-sim HA — the dragon, deferred

Ship-sim owns authoritative physics state for ships and free-agent
players. If a ship-sim process dies, the ships it owned have no
authoritative pose source; their state subjects go silent; cell-mgr
subscribers see them frozen at last-known pose; eventually the entities
appear "stuck" in the world.

The hard part: physics state is not idempotent. You can't just re-run
the last 1 second of a Jolt simulation from scratch and get the same
result — floating-point drift, integrator state, contact persistence.
You need actual checkpoints.

**Phase 2 design space (not for Phase 1):**

- Periodic checkpoint to JetStream KV (`sim.entity.<id>.checkpoint`,
  every ~1 sec). Includes Jolt body state, buoyancy params, sail
  state, passenger list.
- On ship-sim crash detection (subject heartbeat gap or external
  health check), another ship-sim process loads the checkpoints for
  the dead one's ships and resumes simulation.
- Brief replay window (~1-2 sec of input replay) to catch up from
  checkpoint to current.
- Players see ~2 sec of slightly-jittered ship motion at failover.
  Acceptable for ships; harder to hide for free-agent player physics
  (hit-detection windows need to be wider).

**Phase 1 mitigation:** run ship-sim under a process supervisor with
fast restart (<5 sec), accept that a crash loses up to ~5 sec of
ship state (positions snap to last-published pose, some momentum
lost). For a single combat slice with 2 ships in the dev box, this is
acceptable. **Production deployment must solve this before scaling
content.**

### 7.5 Cost summary

Active/standby across the singleton services:

| Service | Replicas | Marginal RAM | Marginal CPU |
|---|---|---|---|
| spatial-index | 3 | ~100 MB | ~0.6 cores (firehose ingest on standbys) |
| env | 2 | ~10 MB | trivial |
| persistence-writer | 2 | ~50 MB | trivial idle |
| auth | 2 | ~20 MB | trivial idle |

Total HA cost: well under 1 GB RAM, under 1 core CPU. Cheap insurance.

## 8. Resolved decisions (formerly open questions)

All four resolved 2026-04-29 during the Phase 1 architecture
walkthrough. Recorded here for archival.

1. **ECS host for ship-sim — thinner, not a `zone_game_state.zig` fork.**
   fallen-runes' ECS carries party / shop / NPC-AI / loot-table state
   we don't need. ship-sim lifts only the tick-loop *shape* (file
   structure + accumulator + metrics + NATS heartbeat), not the
   contents. Ground-up state owner is cleaner than gutting a 1000-line
   file.

2. **Per-cell NATS account / permissions — single account for Phase 1.**
   NATS account isolation is a security feature; the operational tax
   isn't worth it on a single-host dev deployment. Post-Phase-2 when we
   deploy across multiple machines, split into per-service accounts as
   a deployment task, not an architecture change.

3. **Subscriber list ownership — cell-mgr owns the interest set.**
   - Co-located with the data (entity positions + tier mappings live in
     cell-mgr's in-memory table; gateway-owned interest forces every
     fanout decision across a NATS hop).
   - Gateway stays stateless (thin TCP↔NATS proxy, no payload decode,
     no filter logic). N gateway replicas trivially.
   - Sub-cell partitioning (§2.4a) requires interest at cell-mgr by
     construction.
   - Auth flows unaffected: gateway mediates JWT/session, cell-mgr sees
     opaque `client_id` keys.

4. **JetStream vs core NATS for `sim.entity.<id>.state` — core NATS,
   confirmed.** State is lossy + latest-value semantics: a missed 60 Hz
   pose update is fine, the next one arrives in 16 ms. JetStream's
   durability + replay would force every pose through disk persistence
   and grow unbounded if a consumer falls behind. JetStream is for
   *events* where missing one matters (damage, sink, fire); state
   firehose stays on core NATS.

## 9. What this gives you

- A reuse map that classifies every fallen-runes file before any
  Phase 1 code is written, so no surprise rewrites mid-milestone.
- The cell-mgr / spatial-index boundary defined before either is
  written.
- The 4-tier filter as a pure module — testable in isolation, no
  service mock required.
- A subject-namespace policy that prevents accidental dev-cluster
  collisions with fallen-runes.
- An M6 sub-milestone breakdown that gates on synthetic correctness
  before any service integration, matching the Phase 0 cadence.

Phase gate before code: ratify §1 (reuse map), §2 (cell-mgr
responsibilities + deployment shapes), §3 (filter shape), §4
(namespace policy), §7 (HA pattern for spatial-index + others). Open
questions in §8 must have answers before the milestones they're called
out in.
