# 09 — ai-sim Service Design

The decisions service for AI ships and (eventually) wildlife / NPC crew.
Companion to [02-architecture.md](02-architecture.md) §services and the
"ai-sim is decisions only" architecture lock. This doc specs the BT
runtime, the leaf dispatch API, the perception surface, and the service
boundary.

Status: **ratified 2026-04-30**. Treat as locked unless explicitly
revisited (same rule as `02-architecture.md`'s ten locked decisions and
`08-phase1-architecture.md`). Open questions in §13 are deliberately
deferred to implementation time, not design-front blockers.

## 1. Scope

✓ All §1 scope is ratified.

### 1.1 What ai-sim does

- Picks a subset of ships in `ship-sim` by entity id and drives their
  inputs.
- Runs one behavior tree per AI-controlled ship at 20 Hz.
- Publishes `sim.entity.<id>.input` messages whose wire shape is
  identical to a player's gateway input.

### 1.2 What ai-sim does not do

- Physics. AI ships live in `ship-sim`'s 60 Hz Jolt body table like any
  other ship. ✓ locked, see memory `architecture_ai_sim_decisions_only.md`
  and [02 §services](02-architecture.md).
- Spawning. Same path as player-controlled ships; ship-sim's existing
  spawn flow is the only spawn flow.
- Damage / hull state. Owned by ship-sim per [02 §service mesh](02-architecture.md).
  ai-sim only *reads* an AI's hp through the perception API.
- Wildlife or NPC crew. v1 is hostile ships only. Wildlife is a Phase 2
  extension; NPC crew is Phase 3.

### 1.3 First deliverable

The M1 combat-slice gate: one AI sloop that sails toward the player,
opens fire when in range, and disengages when below 30% hp. Single
archetype, single tree, no multi-ship coordination.

## 2. Service shape

✓ Ratified.

| Property | Value |
|---|---|
| Tick rate | 20 Hz (50 ms budget) ✓ locked, [02 §1.1](02-architecture.md) |
| Process | Single binary, multi-threaded inside (one thread per AI cohort) |
| Inputs | `sim.entity.*.state` (subset, filtered by perception); `idx.spatial.query.radius` (req/reply); `env.cell.*.wind` |
| Outputs | `sim.entity.<id>.input` per AI ship, per tick |
| State | In-memory only. Per-AI Lua tables. Lost on restart; AI re-acquires targets on warm-up. No persistence. |
| Hot reload | YAML trees and Lua leaf files are file-watched; per-AI state survives reload |
| Failure mode | If ai-sim is offline, AI ships drift (no input arrives, ship-sim's last-input-wins keeps them on whatever heading they last had). See §12. |

## 3. Tick loop

✓ Ratified. Per 20 Hz tick:

```
for cohort in cohorts:                     # cohort = one thread's slice
    perception = build_ctx(cohort)         # batch spatial + state queries
    for ai in cohort:
        status = bt_step(ai.tree, ai.self, perception[ai.id])
        if ai.pending_input is not None:
            publish(sim.entity.<ai.id>.input, ai.pending_input)
            ai.pending_input = nil
```

Two design choices worth naming:

**Batch perception, not per-AI fetch.** A naive loop would call
`spatial.query.radius` per AI per tick — 30 AI × 20 Hz = 600 NATS
req/reply per second, all blocking. Instead, the cohort builds one
batched perception update at the top of the tick (one radius query per
AI, fired in parallel, awaited together) and the BTs read from the
prebuilt context. This collapses to 30 in-flight queries per tick with
fan-out/fan-in concurrency, not 30 sequential round-trips.

**Pending-input pattern.** Action leaves don't publish directly; they
write into `ai.pending_input` and return a `Status`. The tick dispatcher
publishes once per AI at the bottom. This guarantees one input message
per tick per AI even if the tree visits multiple action leaves
(decorator failures, sequence rewinds).

## 4. BT runtime

✓ Decided 2026-04-30. Six node types in Zig, tree shape in YAML, leaves
in Lua.

### 4.1 Status enum

```zig
pub const Status = enum { success, failure, running };
```

Standard BT semantics: `running` propagates upward; `success` /
`failure` flow into composite logic.

### 4.2 Node types

| Type | Children | Semantics |
|---|---|---|
| `selector` | N | Run children in order; first `success` or `running` wins; if all return `failure`, the selector returns `failure`. "Try these in priority order." |
| `sequence` | N | Run children in order; stop on first `failure` or `running`; if all `success`, return `success`. "Do these in order." |
| `parallel` | N | Run all children every tick; configurable success/failure policy (`all`, `any`, `n_of`). Used for "steer while firing." |
| `inverter` | 1 | `success ↔ failure`; `running` passes through. Cheap negation. |
| `cooldown` | 1 | Returns `failure` for `cooldown_ms` after the child last returned `success`. Anti-spam for fire / ability leaves. |
| `repeat` | 1 | Re-runs the child N times or until failure (configurable). Used for multi-shot bursts, patrol cycles. |

That's the full vocabulary. If a seventh node type is needed it's a
schema bump and a Zig PR; not designer-authorable.

### 4.3 Leaves

Two leaf types:

- **`cond`** — calls a Lua function, returns `success` or `failure`
  based on the boolean result. Used in sequences as gates
  (`enemy_in_range`, `low_hp`, `wind_favorable`).
- **`action`** — calls a Lua function, can return any of the three
  statuses, may write into `ai.pending_input`. Used as the leaves of a
  sequence/selector that actually do something
  (`broadside_attack`, `flee`, `patrol`).

Leaves are the only place Lua runs. Composite traversal stays in Zig.

### 4.4 Traversal cost

Tick budget at 200 AI ships (well past v1 needs):
- 200 AI × 20 Hz × ~10 nodes traversed/tick = 40k node visits/sec
- ~20k of those reach a leaf and cross into Lua

In Zig: a few hundred microseconds per tick for traversal. Lua dispatch
dominates. The whole 20 Hz budget is 50 ms, so 5 ms of AI work leaves a
huge margin. The reason composites are in Zig isn't that 40k Lua calls
would melt the VM — LuaJIT can do millions — it's that putting the
finite, stable composite vocabulary in the fast language costs nothing
and reserves the Lua VM's headroom for the part that actually grows.

## 5. Tree shape (YAML)

✓ Ratified. Schema-validated on load. Same loader pattern as the
wave-query loader (M1b).

```yaml
# data/ai/pirate_sloop.yaml
archetype: pirate_sloop
description: Hostile sloop, opens fire when in range, flees below 30% hp.
perception_radius: 600

root:
  type: selector
  children:
    # Highest priority: flee when wounded
    - type: sequence
      children:
        - { type: cond,   fn: low_hp }
        - { type: action, fn: flee_to_open_water }

    # Engage if there's a target in cannon range
    - type: sequence
      children:
        - { type: cond, fn: enemy_in_range }
        - type: parallel
          policy: any_failure
          children:
            - { type: action, fn: aim_broadside }
            - type: cooldown
              cooldown_ms: 4000
              child: { type: action, fn: fire_broadside }

    # Pursue if there's a target at all
    - type: sequence
      children:
        - { type: cond,   fn: enemy_spotted }
        - { type: action, fn: intercept }

    # Default: patrol
    - { type: action, fn: patrol_waypoints }
```

Trees can `include:` other trees by path, so shared subtrees
(`combat_subtree.yaml`, `flee_subtree.yaml`) deduplicate across
archetypes. Resolved at load time, not at runtime.

## 6. Leaf dispatch (Lua side)

✓ Ratified. One Lua file per archetype, sibling to the YAML. Functions are
top-level; the loader registers them in a per-archetype dispatch table.

```lua
-- data/ai/pirate_sloop.lua

-- Conditions return boolean
function low_hp(self, ctx)
    return self.hp < 0.30
end

function enemy_in_range(self, ctx)
    return ctx.nearest_enemy ~= nil
       and ctx.nearest_enemy.dist < 200
end

function enemy_spotted(self, ctx)
    return ctx.nearest_enemy ~= nil
end

-- Actions return Status, may write ctx.input
function aim_broadside(self, ctx)
    local e = ctx.nearest_enemy
    if e == nil then return "failure" end
    local desired_heading = bearing_for_broadside(self, e)
    ctx.input.steer = clamp_heading(self.heading, desired_heading)
    ctx.input.thrust = 0.6
    return "running"   -- never finishes; sequence parent moves on via parallel sibling
end

function fire_broadside(self, ctx)
    ctx.input.fire = true
    return "success"   -- one-shot; cooldown decorator gates the next attempt
end

function flee_to_open_water(self, ctx)
    -- ... compute heading away from threats and toward deep water
    ctx.input.steer = ...
    ctx.input.thrust = 1.0
    return "running"
end

function intercept(self, ctx)         ... end
function patrol_waypoints(self, ctx)  ... end
```

`self` is the per-AI state table (§8). `ctx` is the perception context
(§7). `ctx.input` is the pending input the dispatcher will publish.

Status values are returned as strings (`"success"`, `"failure"`,
`"running"`) and converted to the Zig enum at the FFI boundary. Strings
chosen over integers because they survive copy-paste from logs and
diff-review better than `0/1/2`.

## 7. Perception API

✓ v1 surface ratified; extensions are deliberate Zig PRs.

The `ctx` table the engine fills before each AI's tick. Designers add
fields by submitting Zig PRs — the surface is intentionally narrow.

### 7.1 v1 fields

```
ctx.tick           -- monotonic 20 Hz tick counter (for cooldowns, timers)
ctx.dt             -- seconds since last tick (~0.05)

ctx.own_pose       -- { x, y, z, qx, qy, qz, qw }
ctx.own_vel        -- { lin = {x,y,z}, ang = {x,y,z} }
ctx.own_hp         -- 0.0 .. 1.0

ctx.wind           -- { dir = radians, speed = m/s } at own_pose
ctx.cell           -- { x, y } current cell coords

ctx.nearest_enemy  -- nil or { id, pose, vel, dist, hp }
ctx.threats        -- array of nearby hostiles within perception_radius
                   --   (sorted by dist; capped at 8 to keep ctx small)

ctx.input          -- { thrust, steer, fire, ... }  -- mutated by leaves
```

Bounded; no `world` handle, no global query API. If a leaf needs
something not in `ctx`, it's a perception-API extension, which is a
deliberate code change with review.

### 7.2 Why bounded

Two reasons.

**Cost.** An AI with the whole world in scope makes the perception
build dominate the tick. Bounding `threats` to 8 + `nearest_enemy`
means perception is O(spatial query result) per AI, not O(world).

**Determinism for designers.** A leaf that can reach into any subsystem
becomes impossible to reason about. A leaf with a fixed input shape and
a fixed output shape is testable in isolation — you can write a Lua
unit test that hands a leaf a synthetic `ctx` and asserts on the input
or status. Worth keeping.

## 8. Per-AI state

✓ Ratified. Each AI has a Lua table threaded in as `self`. Survives across ticks
and across hot reload. Owned by ai-sim, indexed by entity id.

```lua
-- after spawn, ai-sim writes:
self.id            -- entity id (matches ship-sim's EntityId)
self.archetype     -- "pirate_sloop"
self.hp            -- mirrored from ctx.own_hp for convenience
self.heading       -- mirrored from ctx.own_pose

-- script-owned (any leaf can write):
self.target_id     -- chosen target entity id
self.last_fire_ms  -- timestamp of last broadside
self.waypoint_idx  -- patrol cursor
self.mood          -- e.g. "hunting" / "fleeing" / "patrolling"
```

The convention is: anything the engine writes is reset every tick;
anything a leaf writes persists. No formal split — just a discipline.

On hot reload, the table itself is preserved (it's keyed by entity id
in the ai-sim service's Zig-side registry). The Lua chunk that defines
the leaves is replaced; the data tables are not touched.

## 9. Hot reload

✓ Ratified. The data-driven principle ([05 §115](05-data-model.md))
applies: designer saves a tree YAML or a leaf Lua file, ai-sim picks it
up.

- File watcher on `data/ai/`.
- YAML reload: re-parse, schema-validate, swap the tree atomically. If
  validation fails, log and keep the previous tree. (Same pattern as
  every other YAML loader in the project.)
- Lua reload: re-execute the chunk, replace the dispatch table. Per-AI
  state tables are not touched — they survive code changes.
- AIs in the middle of a `running` leaf when reload happens: the next
  tick they re-enter from the root. BT semantics make this safe;
  there's no implicit cross-tick state inside the runtime, only inside
  `self`.

## 10. Determinism

✓ Ratified. ai-sim is **not** in the deterministic-projectile path ([02 decision 2](02-architecture.md)).
Cannonball arcs are deterministic; AI decisions are not.

This means:
- AI scripts may use `math.random()` freely.
- Two ai-sim instances (e.g. for HA) will diverge in what their AIs
  decide. That's fine — only one is leader at a time, and a leader
  switch incurs target-reacquisition, not state divergence.
- AI is *not* replayable from inputs. If we ever need replay, that's a
  separate seeded-RNG pass; not in scope.

## 11. NATS interfaces

✓ Ratified.

### 11.1 Subscriptions

| Subject | Purpose |
|---|---|
| `sim.entity.*.state` | Pose / velocity / hp of all ships ai-sim cares about. Filtered by spatial proximity, not blanket-subscribed. |
| `env.cell.<x>_<y>.wind` | Wind sample for cells that contain an AI ship. |
| `idx.spatial.query.radius` (req/reply) | Per-tick perception query. ✓ shipped; ai-sim is the first real consumer per memory. |

### 11.2 Publications

| Subject | Shape | Rate |
|---|---|---|
| `sim.entity.<ai_ship_id>.input` | `InputMsg` (same as gateway → ship-sim) | 20 Hz per AI |
| `ai.health` | Service health report | 1 Hz |
| `ai.metrics.*` | Prometheus-style counters | scrape |

ship-sim cannot tell the difference between an AI's input and a
player's input. That's the design invariant; it's why this whole
service is "decisions only."

## 12. Failure modes and degradation

✓ Ratified. Per the graceful-degradation rule (memory `feedback_graceful_degradation.md`):
every cross-service interaction needs a defined reduced-state behavior.

| Dependency offline | ai-sim behavior |
|---|---|
| `spatial-index` down | Circuit breaker opens after N failed radius queries; AIs fall back to "drift on last heading" until breaker recovers. No crashes, no input messages. |
| `env` (wind) down | Stale-but-acceptable: continue using last known wind sample for that cell. Wind changes slowly (5 Hz tick on `env`). |
| `ship-sim` down | ai-sim has nothing to drive. Pause the tick loop, keep file watchers running, resume when state messages start flowing again. |
| **ai-sim itself down** | ship-sim sees no input messages on those entities; last input persists (existing player-disconnect behavior). AI ships drift on last heading. Combat slice still functions; AI just isn't fighting back. |

The "ai-sim down" row is the important one. AI-driven ships go from
"adversary" to "drifting hulk," which is a degraded but coherent world
state. No cascading failures into ship-sim or the player experience.

## 13. Open questions

1. **Cohort scheduling.** One thread per cohort, but how are AIs
   assigned? Round-robin by id? By cell? Cell affinity matters for
   cache locality on the perception build, but breaks if an AI crosses
   a cell boundary mid-cohort. Probably: by cell, with reassignment on
   cell change. Decide when ai-sim is being implemented.

2. **Multi-AI coordination.** Two pirate sloops attacking a player
   should ideally split flanks, not both ram the same side. Out of v1
   scope; on the table for Phase 2. Likely shape: a "squad" entity
   that owns shared state and individual AIs read its assignments via
   `self.squad.*`.

3. **Lua VM choice.** ✓ Resolved 2026-04-30: **PUC Lua 5.4** vendored
   under `vendor/lua/`, with a hand-rolled thin C binding in
   `src/shared/lua_c.zig` (NOT ziglua / zig-gamedev wrappers, per
   `feedback_thin_c_bindings.md`). LuaJIT rejected: frozen at 5.1
   semantics for the project's lifetime, and FiveM-RP devs (the Phase
   2/3 audience per `project_asset_pipeline_fivem_team.md`) expect
   modern Lua. Perf headroom LuaJIT would buy is unused at our call
   rates (§4.4). See memory `architecture_lua_54_thin_c_binding.md`
   for full reasoning. If a future hot path actually needs LuaJIT, the
   migration is contained — see §13 *was* q3 follow-up below.

4. **Tree visualization.** Designers will want to see the live tree
   state (which node is `running` for AI X right now). Probably a
   debug HUD in the sandbox client that subscribes to a tracing
   subject. Out of v1 scope; don't bake assumptions into the runtime
   that prevent it later.

5. **Save / load.** Should `self` survive process restart? v1 says no
   (re-acquire targets on warm-up). Phase 2 may want some persistence
   for long-lived AI like patrolling fleets — TBD.

## 14. Implementation order

When ai-sim's turn comes (after combat slice scaffolding closes — see
[04 roadmap](04-roadmap.md)):

1. `lua_bind.zig` lift from fallen-runes — comptime-bound, basic
   number/string/table marshaling, function dispatch by name.
2. BT runtime: six node types, traversal, status enum, tree-shape
   typed structs.
3. Tree YAML loader: schema validate, resolve `include:`, build
   typed-tree-of-nodes. Reuse wave-query loader pattern.
4. ai-sim service skeleton: tick loop, NATS subscriptions, cohort
   threads, file watcher.
5. Perception API v1: §7.1 fields, batched `idx.spatial.query.radius`
   per cohort.
6. First archetype: `pirate_sloop.yaml` + `pirate_sloop.lua`.
7. Combat-slice gate: M1 deliverable per [04 roadmap](04-roadmap.md).

## 15. References

- [02 §services](02-architecture.md), [02 §1.1](02-architecture.md) — locked decisions on tick rates and service mesh.
- [03 §reuse table](03-engine-subsystems.md) — `lua_bind.zig` lift.
- [05 §16](05-data-model.md), [05 §50](05-data-model.md) — data-driven principle, YAML+Lua split.
- [08 §2A](08-phase1-architecture.md) — ship-sim authoritative tick (same input subject AI publishes to).
- Memory `architecture_ai_sim_decisions_only.md` — the architecture lock that motivates this doc.
- Memory `feedback_graceful_degradation.md` — drives §12.
- Memory `feedback_engineering_over_gamedev_framing.md` — drives the BT-in-Zig / leaves-in-Lua split rationale (§4.4).
