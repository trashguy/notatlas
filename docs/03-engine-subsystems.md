# 03 — Engine Subsystems

What notatlas adds to the Zig engine, in dependency order. Each subsystem
has an API surface, the data it consumes, the NATS contract it follows,
and a milestone gate that proves it works in isolation before being
composed with anything else.

The substrate is `~/Projects/fallen-runes` plus `~/Projects/nats-zig`.
Subsystems below the line "REUSE FROM FALLEN-RUNES" are inherited and
need integration, not greenfield work.

---

## REUSE FROM FALLEN-RUNES (no new engine work, just integration)

| Subsystem | Source | Notes |
|---|---|---|
| ECS world / components / systems | `src/shared/ecs/` | Entity management |
| TCP framing + packet protocol | `src/shared/net/` | Extend protocol set; reuse framing |
| Lua scripting (comptime bindings) | `src/shared/lua_bind.zig` | Recipe and AI scripts |
| Authoritative server pattern | `src/server/` | Tick loop and command stream |
| PG persistence | `src/shared/db/` | Models, migrations |
| NATS infrastructure | `src/shared/nats/`, `~/Projects/nats-zig` | Subjects, messages, JetStream |
| Gateway service | `src/services/gateway/` | Stateless client-facing |
| Auth service | `src/services/auth/` | Login, JWT |
| Resilience primitives | `src/shared/resilience/` | Circuit breaker, request context |

> **Renderer is reference, not reuse.** fallen-runes'
> `src/client/renderer/` is read for patterns and reimplemented in
> notatlas, not imported as a build dependency. fallen-runes is a
> different game (top-down sprites, tilemap, glTF asset pipeline) and
> its renderer carries features notatlas doesn't need. See
> [m2-ocean-render.md §2](m2-ocean-render.md) for the rationale and
> the per-component reference map.

---

## NEW ENGINE SUBSYSTEMS (in dependency order)

### 1. wave-query (foundation)

Deterministic wave-height function. Same answer client and server given
`(time, seed)`. Used by both the ocean renderer (vertex displacement) and
the buoyancy system (force application).

**API surface (Zig):**
```zig
pub const WaveParams = struct {
    seed: u64,
    components: []const GerstnerComponent,  // amplitude, freq, dir, phase
};

pub fn waveHeight(params: WaveParams, x: f32, z: f32, t: f32) f32;
pub fn waveNormal(params: WaveParams, x: f32, z: f32, t: f32) Vec3;
pub fn waveDisplacement(params: WaveParams, x: f32, z: f32, t: f32) Vec3;
```

**Data:** `data/waves/<biome>.yaml` — Gerstner component sets per biome
(calm, choppy, storm).

**NATS:** none directly. Consumed by ocean-render (client) and buoyancy
(server). Wave seed broadcast via `env.cell.<x>_<y>.wind` includes the
active wave-params id.

**Milestone gate (M1):** unit tests prove client and server compute
identical heights to within float epsilon for 10k random `(x, z, t)`
samples across all biome configs.

---

### 2. ocean-render (client-only, depends on wave-query)

Visual ocean surface. Vertex shader Gerstner displacement, foam, water
shading, underwater fog. v1 is Gerstner; v2 upgrades to Tessendorf FFT
later.

**API surface:**
- `ocean.init(params, mesh_resolution) !*Ocean`
- `ocean.render(cmd_buffer, camera, time) void`
- `ocean.params_set(params) void` (hot-reload from data file)

**Data:** `data/ocean.yaml` — mesh resolution, foam thresholds, water
albedo, scatter parameters.

**Milestone gate (M2):** beautiful raymarched ocean visible in the
sandbox at ≥ 150 fps on the dev-box GPU (RX 9070 XT, 1280×720) — proxy
for ≥ 60 fps on a 4060-class card; rationale + cross-vendor caveat in
[m2-ocean-render.md §10](m2-ocean-render.md). Camera flies over; no
z-fighting; foam at wave crests; underwater fog when camera submerges.

---

### 3. buoyancy (server, depends on wave-query + Jolt)

Per-hull-point Archimedes force application. Integrates with Jolt rigid
bodies. The math:

```
For each hull sample point:
    submerged_depth = wave_height(point.x, point.z, t) - point.world_y
    if submerged_depth > 0:
        force = (water_density * g * submerged_depth * sample_volume) up
        apply_force_at_point(rigid_body, force, point.world_pos)
        apply_drag(rigid_body, point.velocity)
```

**API surface:**
```zig
pub fn registerHull(jolt_body: JoltBodyId, samples: []const Vec3) BuoyancyId;
pub fn step(dt: f32, t: f32, wave_params: WaveParams) void;
```

**Data:** `data/ships/<hull>.yaml` — hull sample point list per ship type.

**Milestone gate (M3):** a box (no rendering of ship, just a Jolt body)
floats correctly on the wave surface in the sandbox. Pitches and rolls
when waves pass. Doesn't sink, doesn't fly. Stable for 5 minutes.

---

### 4. wind-field (server, env service)

2D vector field over world coordinates. Owned by the env service.
Published via JetStream KV. Sails consume it to compute force.

**API surface:**
```zig
pub fn windAt(world_x: f32, world_z: f32, t: f32) Vec2;
```

Implementation: low-resolution global wind direction (per-cell or per-
region) with smooth interpolation, plus storm cells as perturbations
that travel across the world.

**Data:** `data/wind.yaml` — global rotation period, gust frequency,
storm cell spawn parameters.

**NATS:** env service publishes `env.cell.<x>_<y>.wind` JetStream KV
on change (~1 Hz).

**Milestone gate (M4):** wind direction visible via debug arrows; client
samples match server; storm cells travel across the world over hours.

---

### 5. ship-as-vehicle (server + client, depends on buoyancy + Jolt)

Ship is a rigid body. Players are passengers in ship-local coordinate
frame. Ship pose replicated server-authoritative; player local pose
replicated separately. World-space player pose computed client-side as
`ship_pose ⊗ player_local_pose`.

**API surface:**
```zig
// Server
pub fn boardShip(player: EntityId, ship: EntityId, local_pos: Vec3) void;
pub fn disembark(player: EntityId) void;
pub fn shipLocalPose(player: EntityId) ?Pose;

// Client
pub fn renderEmbarkedPlayer(player: EntityId) void;  // resolves ship_pose ⊗ local
```

**Critical detail:** sub-tick interpolation of ship pose so player
animation doesn't show jitter when the ship pitches.

**Milestone gate (M5):** player walks around on a buoyant box in sandbox.
Box pitches and rolls; player stays attached without z-fighting,
clipping, or visible jitter. Multiple players supported.

---

### 6. tier-replication (engine + server, mechanism)

Each replicated component declares its tier. The replication system
honors per-subscriber distance. Tiers 0-3 as defined in
[02-architecture.md](02-architecture.md).

**API surface (Zig):**
```zig
pub fn replicated(comptime T: type, comptime tier: ReplicationTier) type {
    return struct {
        value: T,
        // ... bookkeeping for change detection, tier
    };
}

// Component declaration example
const ShipState = struct {
    hull_pose: replicated(Pose, .always),         // Tier 0
    sail_state: replicated(SailState, .visual),   // Tier 1
    plank_hp: replicated([]u16, .close_combat),   // Tier 2
    below_deck: replicated(InventoryRef, .boarded), // Tier 3
};
```

**Mechanism:** replication system iterates subscribers per tick; for each
subscriber, computes effective tier based on distance to entity; emits
deltas for fields at that tier or below.

**Data:** `data/tier_distances.yaml` — distance thresholds per tier.

**Milestone gate (M6):** synthetic test — 100 entities, 50 subscribers at
varied distances. Verify each subscriber receives the correct tier set.
Bandwidth measured matches expected.

---

### 7. pose-compression (protocol layer)

Encode/decode pose to/from ~16 B wire format. Used by ship pose, character
pose, projectile observation streams.

**API surface:**
```zig
pub fn encodePose(pose: Pose, keyframe: ?Pose, cell: ?CellId, buf: []u8) usize;
pub fn decodePose(buf: []const u8, keyframe: ?Pose) Pose;
```

Format: position quantized to 1cm relative to keyframe (6 B), smallest-
three quaternion (4 B), velocity delta (4 B), optional cell-id (2 B).

**Milestone gate (M7):** roundtrip test — encode then decode 1M random
poses; verify max error <1 cm position, <0.1° rotation. Wire size
average ≤16 B.

---

### 8. deterministic-projectile (engine + server)

Projectiles are not replicated entities. A fire event broadcasts
`{cannon_id, fire_time, muzzle_pose, charge, ammo_type}`. Both client
and server compute the same trajectory deterministically. Server
resolves hits authoritatively; client predicts and renders.

**API surface:**
```zig
pub const FireEvent = struct {
    weapon: EntityId,
    fire_time: f64,
    muzzle: Pose,
    charge: f32,
    ammo: AmmoType,
};

pub fn predict(event: FireEvent, t: f64) Vec3;       // client
pub fn resolveHit(event: FireEvent) ?HitInfo;         // server
```

Reuses the wave-query for splash effects and the spatial index for
hit-target search.

**Data:** `data/ammo/<type>.yaml` — mass, drag, splash damage profile.

**Milestone gate (M8):** synthetic test — fire 1000 cannons; verify
client predicted trajectory matches server resolved trajectory within
visual tolerance. Hit registration accurate to the pixel.

---

### 9. lag-comp-rollback (server)

For player-vs-player hit registration: server rewinds N ticks based on
each client's reported latency, validates the hit at the client's view
of the world, applies damage in current tick. Cap at ~250 ms to limit
"shot around corners" feel.

**API surface:**
```zig
pub fn validateHit(
    shooter_view_time: f64,
    shooter: EntityId,
    target: EntityId,
    weapon: WeaponType,
) ?HitInfo;
```

Implementation: ring buffer of past N tick snapshots per replicated
hitbox entity. On hit query, sample the snapshot nearest to
`shooter_view_time`, run hit detection there, return result.

**Milestone gate (M9):** integration test — two clients with simulated
50ms / 200ms ping; both shoot moving targets; hit reg accurate to
client view; no "shot through wall" cases.

---

### 10. gpu-driven-instancing (client renderer extension)

Bindless texture arrays + indirect draws + GPU compute culling +
palette-instanced structures. Replaces per-piece draw calls with
per-piece-type indirect draws.

**API surface (Zig):**
```zig
pub fn registerPalette(pieces: []const PieceMesh) PaletteId;
pub fn registerInstance(palette: PaletteId, piece_id: u32, transform: Mat4) InstanceId;
pub fn updateTransform(instance: InstanceId, transform: Mat4) void;
pub fn destroy(instance: InstanceId) void;
pub fn drawAll(cmd: CommandBuffer, view_proj: Mat4) void;
```

**Pipeline:** compute shader does frustum + occlusion culling against
per-instance bounds, writes a draw count, GPU issues
`vkCmdDrawIndexedIndirectCount`.

**Milestone gate (M10):** synthetic test — 5000 instances of 20 piece
types; render at 60fps on RTX 4060; profile shows ≤20 draw calls
issued.

---

### 11. structure-lod-merge (client renderer extension)

For static structures attached to the same anchorage, auto-merge into
a single mesh per anchorage cluster at idle. Distant anchorages render
as one merged mesh instead of N instanced pieces.

**API surface:**
```zig
pub fn beginCluster(anchorage_id: u64) ClusterBuilder;
pub fn addPiece(cluster: *ClusterBuilder, piece: PieceMesh, transform: Mat4) void;
pub fn finishMerge(cluster: ClusterBuilder) MergedMeshId;  // off-thread
pub fn invalidate(merged: MergedMeshId) void;  // on damage / placement
```

Merge happens off main thread; double-buffered swap when ready.

**Milestone gate (M11):** synthetic — 500-piece anchorage; merge
completes <100ms; far-LOD render uses merged mesh, ~1 draw call.

---

### 12. animation-lod (client renderer extension)

- <30 m: full rig + IK
- 30-100 m: 5 fps tick + reduced rig
- >100 m: vertex-shader anim atlas, no CPU work

**API surface:**
```zig
pub fn animLodSelect(distance: f32) AnimLodTier;
pub fn tickAnimations(entities: []EntityId, camera_pos: Vec3, dt: f32) void;
```

**Milestone gate (M12):** synthetic — 200 animated characters at
varied distances; CPU animation cost ≤2 ms per frame.

---

## Subsystem dependency graph

```
wave-query (M1)
   ├── ocean-render (M2)
   └── buoyancy (M3)
         └── ship-as-vehicle (M5)
                ├── tier-replication (M6)
                │     └── pose-compression (M7)
                │           └── deterministic-projectile (M8)
                │                 └── lag-comp-rollback (M9)
                └── (uses wind-field via sails)

wind-field (M4) — independent

gpu-driven-instancing (M10)
   └── structure-lod-merge (M11)

animation-lod (M12) — independent
```

## Phase 0 work (solo, ~2-4 months)

In order: M1 → M2 → M3 → M4 → M5. End-of-phase deliverable: video of
yourself walking around a pitching box in waves with wind blowing.

## Phase 1 work (solo, ~2-3 months)

In order: M6 → M7 → M8 → M9. The networking layer over the engine. End-
of-phase deliverable: 4 friends + you on one ship, fighting an AI ship,
sinking it.

## Phase 2 work (solo or +1 dev, ~3-4 months)

M10 → M11 → M12, plus the cell-mgr + spatial-index services. End-of-
phase: the demo that justifies the project — seamless cross-cell ship
sailing with no stutter.

See [04-roadmap.md](04-roadmap.md) for the full phased plan.
