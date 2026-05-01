---
name: notatlas current work pointer
description: What's actively being worked on right now. Update or remove when the milestone changes. Read this first in any new session.
type: project
originSessionId: 9014770d-bef4-482b-9b2d-e54d460b2ec1
---
## TOMORROW PICKUP — start here in a fresh session

**End of day 2026-05-01.** User wrapped to catch a flight to London.
Phase 1 closed earlier; Phase 2 substantial progress today: env
service v0 (wind), AI broadside-aim, wave-pitch cannon compensation,
cross-cell transit, inheritance-aware hull config, **persistence-
writer full v0 shape (4 commits scope, 1 commit cleanup), and an
SLA-design conversation that scoped the next chunk of work.**
**~25 commits today (`33d4064` → `1f1d796`); all PUSHED to
origin/master.**

### SLA design conversation — landed in scope, not yet implemented

User pushed back on the persistence-writer's initial shape over a
few turns and we ended up with a sharper architecture. Three
decisions to remember:

  1. **Damage is NOT in PG.** Volume too high (~30B rows/cycle),
     useful queries are aggregates only. Future stats-sim subscribes
     core NATS, rolls up to a tiny `damage_aggregates` table.
     Optional forensic capture lives in `data/jetstream.yaml` with
     a YAML toggle (default false) + `scripts/apply_jetstream.sh`
     reconciler. Memory: `architecture_damage_not_in_pg.md`.

  2. **No audit mirror streams.** PG row IS the audit. The mirrors
     were over-engineered; would have hit 8-28 TB at production
     scale. Real-time analytics consume core NATS, not replay
     streams. Memory: `architecture_no_audit_mirrors.md`.

  3. **Tier 0 / Tier 1 SLA split.** Sessions (login/logout/disconnect)
     need sub-second p99 for game-mechanic correctness (hibernation
     grace timer can't start until pwriter has the disconnect row).
     Analytics streams (market, handoff, inventory) tolerate 10s
     p99. Implies a fast-lane drain in pwriter's main loop — not
     yet built.

### Next session: 4-commit SLA arc (NOT YET STARTED)

Concrete plan that was agreed before the wrap:

  | Commit | Scope |
  |---|---|
  | A | stream_seq idempotency on the 3 streams + ack_wait 30s→300s. New BIGINT UNIQUE column on market_trades, cell_handoffs (inventory already idempotent via UPSERT). Parse stream_seq from `$JS.ACK.<stream>.<consumer>.<delivery>.<stream_seq>...` reply_to subject. INSERT … ON CONFLICT (stream_seq) DO NOTHING. |
  | B | Tier 0 fast lane: new `sessions` table; `events_session` workqueue stream; pwriter loop checks fast streams first with 0ms timeout, drains to completion before touching tier 1. StreamSpec gains `tier: enum { fast, slow }` + `sla_p99_ms: u32` fields. |
  | C | Live metrics + `admin.pwriter.status` publish every 5s. Per-stream {committed, dedup_skipped, failed, lag_ms_p99, last_insert_ms_ago, pending}. Pending is from periodic JS consumer-info request. SLA breach detection: lag > sla_p99_ms for >30s, or no progress >5min while pending>0. Breach logged + published as separate event. |
  | D | Smokes: dedup-on-redelivery (kill pwriter mid-batch, restart, verify zero duplicate rows), fast-lane priority (mix tier 0 + tier 1 events, verify tier 0 drains first), SLA-under-load (drive 1000 events in 10s, assert lag_p99 < 1s and breach_count == 0). |

Open questions when picking up:
  - Status subject shape: single `admin.pwriter.status` (flat JSON
    snapshot of all streams) vs per-stream subjects. I leaned single,
    user didn't push back. Default to single unless reasoning has
    changed.
  - SLA threshold defaults: lag p99 < 10s for slow, < 200ms for fast,
    pending > 1000 = breach. Make CLI-overridable so tournaments can
    tighten.

### Persistence-writer state at end-of-session

`make services-up` brings up nats 2.14 + postgres 16.
`./zig-out/bin/persistence-writer` connects to both, declares 3
workqueue streams (market_trade / handoff_cell / inventory_change),
runs durable pull-fetch with auto-commit per-event INSERT, ack-on-
success. Cycle rollover via `admin.cycle.changed` works without a
restart. No audit mirrors, no damage stream.

Three smokes all PASS:
  - `scripts/persistence_smoke.sh` — 8 assertions (3-stream ingest +
    ack-once)
  - `scripts/persistence_cycle_rollover_smoke.sh` — 4 assertions
    (cycle bump using handoff as witness)
  - (audit smoke deleted)

`scripts/apply_jetstream.sh` toggles `damage_forensic` capture per
`data/jetstream.yaml`. Verified the lifecycle (false→true→false).

### Persistence-writer state (end-of-day 2026-05-01)

`make services-up` brings the dev stack up (nats 2.14 + postgres
16-alpine, both --network host). `./zig-out/bin/persistence-writer`
boots clean: nats connect → pg connect → current cycle probe (cycle
id=1, label "S0-dev") → stream/consumer attach → idle pull loop.

End-to-end smoke (manual): publish `sim.entity.<id>.damage` JSON
on core NATS → JetStream auto-captures via subject filter → pwriter
fetches in 256-msg batches → tx-batched INSERT INTO damage_log →
ack-on-commit. Restart-and-no-redelivery verified.

**Persistence-writer arc — COMPLETE 2026-05-01.**

All four carved-out items shipped. The service is full-shape v0:

  - ~~smoke harness~~ DONE `7160c63`
  - ~~multi-stream (4 workqueue streams + 3 new tables)~~ DONE `352afe5`
  - ~~cycle rollover via admin.cycle.changed~~ DONE `c68b59a`
  - ~~audit mirror streams~~ DONE `d8689cc`

Streams attached: events_damage / events_market_trade /
events_handoff_cell / events_inventory_change — each with a
parallel audit_* mirror under limits retention (30 d).

Three smoke harnesses, all PASS:
  - `scripts/persistence_smoke.sh` — multi-stream ingest + ack-once
  - `scripts/persistence_cycle_rollover_smoke.sh` — wipe-cycle bump
  - `scripts/persistence_audit_smoke.sh` — workqueue ack-remove vs
    mirror retention

Producers that don't exist yet (market service, inventory service,
handoff event publisher in cell-mgr) can publish to the existing
subjects with no pwriter changes — the consumer side is finished.

**Future work that's NOT pwriter-blocking:**
  - Producer-side wiring when those services land
  - Cold-storage export pipeline before audit mirror's 30-day
    age-out (ops concern, not pwriter)
  - Per-stream batching tuning if PG throughput becomes the bottleneck
    (currently 25 ms per-stream fetch × 4 streams = ~100 ms wrap;
    fine for analytics-grade rates)

### Watch out for (gotchas surfaced today)

  - **NATS 2.14 envelope drift.** `js.createConsumer` in nats-zig
    0.2.2 sends pre-2.14 JSON; broker rejects with err 10025. Worked
    around with hand-rolled `client.request()` in
    `persistence_writer/main.zig#ensureConsumer`. Memory:
    `feedback_nats_zig_2_14_consumer_envelope.md`. Probably affects
    other config-bearing JS API calls; check before adding more.
  - **pg.zig `Client.close()` self-destroys.** Don't follow with a
    manual `allocator.destroy(client)` — double-free. Just
    `defer client.close()`. Same as nats-zig pattern in env-sim.
  - **dev creds.** Postgres = notatlas/notatlas/notatlas. NOT for
    prod. Persistence-writer args default to these; override with
    `--pg-host/-port/-user/-pass/-db` for non-dev.

End-to-end demo path is live: env-sim → ship-sim sails under
real env wind → ai-sim sees ctx.wind in perception → ships hit/
sink/board/disembark/rotate-to-aim → cross cell boundaries
cleanly → broadside cannons hit moving targets through swell.
Hull configs derive from `data/hulls/_base.yaml` via `extends:`.

**Next milestone — start here:**

### 1. persistence-writer follow-ups

See "Persistence-writer state" section above for the live state +
remaining work checklist. Lowest-friction next step is the smoke
harness (#1 in the list). Below is the original Phase-2-kickoff
context kept for reference; specifics that landed are crossed in the
state section.

#### (Original kickoff notes — mostly historical now)

**Anchor:** `docs/02-architecture.md` §5 + line 197 (table row).
Sole PG writer per LOCKED architecture decision 5. Single
process; never on the hot path; subscribes to JetStream change
streams; batches Postgres writes.

**Mixed storage shape (from §5 table):**

| State type | Storage | Cadence |
|---|---|---|
| Pose / fast-changing sim state | NEVER persisted | — |
| Player inventory | JSONB blob per player | On change, batched |
| Market / tradeable items | Relational table | On change |
| World structures + claims | Relational table | On change |
| Damage / event log | JetStream KV with TTL → wipe | Per event |
| Account / cosmetics / veteran tier | Relational, account scope | On change, persists across wipes |
| Discipline progress | Relational, character scope | On level event |
| Fog-of-war map state | JSONB blob per character | On chunk-discover event |

**Stream shape (from §5 + NATS 2.14 ADR-60):**
ack-once event streams (damage, market trades, cross-cell handoffs)
use **workqueue** retention with persistence-writer as the
exactly-once consumer; audit/replay consumers attach via **mirror**
streams (sourcing from workqueue was unblocked in 2.14). Producer
writes once; broker fans out. Disable redundant dedup on the
audit mirror — source's dedup window is authoritative.

NATS dev broker is at 2.10 still (`make nats-up`); needs bump to
2.14+ for the workqueue+mirror pattern. Memory:
`feedback_nats_everywhere_ipc.md` and `dev_nats_podman_host_network.md`.

**State of the world — nothing exists yet:**
  - No `src/services/persistence_writer/` directory.
  - No PG client dep in `build.zig.zon`. Need to pick one (zpg,
    pg.zig, libpq via FFI, or hand-rolled — fallen-runes has an
    `infra/compose.yml` with a postgres service but no Zig client
    code wired up yet — `find` shows `infra/db/init.sql` exists
    in fallen-runes but `src/server/persistence/` is empty).
  - No schema.sql under notatlas. fallen-runes has a sketch
    (`/home/trashguy/Projects/fallen-runes/infra/db/init.sql` —
    accounts, characters, inventories) that's a starting reference
    but tuned for fantasy/RPG, not naval-MMO.

**Recommended approach (start of session):**

1. **Schema design first.** Don't write code until tables are
   sketched. Start with:
   - `accounts`, `characters`, `disciplines` (rel)
   - `inventories` (one JSONB blob per character, slot list)
   - `claims` (anchorages, structures — rel)
   - `market_orders`, `market_trades` (rel)
   - `wipe_cycles` (cycle_id, started_at, ends_at — to scope what
     persists across wipes vs what gets wiped)
   - Fog-of-war: JSONB blob per character (decision 5 table).
   Draft in `db/schema.sql` or `infra/db/init.sql` mirroring
   fallen-runes layout.

2. **Pick a PG client.** Survey:
   - Fastest path: hand-rolled libpq C-binding (notatlas already
     pattern: vendor/nats-zig and vendor/lua/lua_c.zig — same
     "thin C binding" memory `architecture_lua_54_thin_c_binding.md`).
   - zpg / pg.zig: pure-Zig, may not be 0.15 compatible (memory
     `zig_015_ecosystem_gap.md` — many libs HEAD on 0.16-dev).
     Check before depending.
   - Default to libpq thin-C-binding if no clean pure-Zig option.

3. **JetStream stream layout.** Each persistable event type gets
   its own stream:
   - `events.damage` (workqueue) → persistence-writer consumes,
     batches into `damage_log` PG table.
   - `events.market.trade` (workqueue) → `market_trades` table.
   - `events.handoff.cell` (workqueue) → log of who-crossed-where-when.
   - `events.inventory.change` (workqueue) → updates JSONB blob.
   `audit.*` mirror streams attach for replay (off the v0 path).

4. **Service skeleton.** New `src/services/persistence_writer/main.zig`.
   Connect NATS, declare streams + consumers, drain each, batch
   writes (e.g. 100 ms or 256 events whichever first), commit
   transaction, ack. Crash-safe via JetStream redelivery on
   un-acked.

5. **Smoke harness.** Like `scripts/transit_smoke.sh` — bring up
   compose stack (nats + pg), run a damage producer, verify rows
   land in PG, verify ack-once (no duplicates).

**Likely scope:** 4-6 commits over multiple sessions. Schema +
client + skeleton + first stream (damage) + smoke. Other streams
follow incrementally.

**Cross-references for fresh-session-me:**
  - `architecture_locked_decisions_v0` memory: locked decisions list.
  - `architecture_hull_extends_chain.md`: same-shape inheritance
    pattern works for ammo/biome configs too if persistence-writer
    needs configs.
  - `feedback_thin_c_bindings.md`: bind libpq directly, don't
    pull a wrapper.
  - `feedback_nats_everywhere_ipc.md`: persistence-writer over
    NATS streams, no direct service-to-service.
  - `feedback_graceful_degradation.md`: PG offline → producers
    keep writing to JetStream (durable); persistence-writer
    catches up on reconnect. Define this circuit-breaker shape
    explicitly.

---

### Other follow-ups (lower priority, all DEFERRED):

- **EVE-transversal hit model** — after `8e4a7ca` cannon hit-rate
  is healthy (8/60s static, 10/60s moving target, 1-2/90s line+wind).
  Cross-track motion is the residual ceiling. Phase 3+, only when
  sub-tier cannon variants ship. Memory `design_eve_transversal_hit_model.md`.

- **Per-cannon cooldown tracking** — multi-cannon support landed
  in `e4ce7e4`, but entity has single `next_fire_allowed_s` and
  `salvo_cooldown_s = max(cannons[].cooldown_s)` gates broadside
  on slowest gun. Mixed-cooldown batteries (bow chaser + broadside
  on a brig) would want per-cannon timestamps. Lift when a tier
  needs it.

- **Per-entity hull pointer** — v0 has single global hull;
  ship-sim threads it through tick / fireCannon / applyShipInputForces.
  When schooner spawns alongside sloop in the same world, entity
  needs `*const HullConfig`. Carved out in `architecture_hull_extends_chain.md`.

- **env service: weather, waves, ToD** — wind shipped (`d421cca`);
  the other three on the same `env.cell.<x>_<z>.*` surface still
  ▢. Probably blocks on persistence-writer (storm schedules
  persist across cycles).

- **M10/M11/M12** (gpu-driven instancing, structure LOD merge,
  animation LOD) — client-side; orthogonal to persistence work.

---

### Commit chain context (today, in order on origin/master pending push):
- Phase 1 close: `33d4064` `1bffaf0` `151fc55` `9dc5063` `9ec074b`
- Phase 2 start: `326a7c8` (layout/HP knobs) `d421cca` (env-sim)
  `f316654` (roadmap) `af9543c` (PD heading controller plumbing)
  `e959d8f` (PD sign fix + wrap hysteresis + duel layout)
  `8934526` (spatial-index cell hysteresis + ship-sim --init-vel-x)
  `051df59` (cross-cell transit smoke)
  `019b396` (transit-smoke single-cell sub registration)
  `8d61dcf` (aim_broadside slacks sails during rotation)
  `352a5b8` (yaw-only cannon basis + closed-form pitch compensation)
  `8e4a7ca` (pitch lead for moving targets)
  `e4ce7e4` (hull config inheritance + multi-cannon)

`e4ce7e4` is the head; `git log --oneline -10` shows the arc.

**Mid-day 2026-05-01:** TS-via-tstl decided as the planned dev
front-end for content authoring (memory
`project_typescript_dev_frontend.md`). Lua 5.4 stays as runtime;
designers will author in `.ts`, transpiled by TypeScriptToLua at
build time.

### 2026-04-30 commits (yesterday, oldest → newest, all on origin/master):

1. `b6ae0b6` — `feat(shared): entity_kind` — top-byte-tagged u32 EntityId space `(kind:u8 << 24) | seq:u24`. ships=0x01, players=0x02, projectiles=0x03. Memory: `architecture_entity_id_kind_tag.md`.
2. `4cb9fb0` — `feat(physics): jolt body velocity setters` — `set_linear_velocity` + `set_angular_velocity` C-API hooks (~30 min). Same hooks usable for future collision knock-off.
3. `3798f72` — `feat(ship-sim): board/disembark + free-agent player capsule` — InputMsg.board/.disembark verbs, `Passenger` table, free-agent capsule (placeholder box body), nearest-ship-within-8m board logic, lever-arm velocity inheritance on disembark, spatial-index `idx.spatial.attach.*` control + synthetic deltas, drive_ship B/G keys.
4. `85d6ae4` — `feat(spatial-index): radius queries — idx.spatial.query.radius req/reply` — RadiusQueryMsg + RadiusResultMsg, brute-force O(N) queryRadius primitive, NATS req/reply pattern. Smoke-tested 2-7 ms RTT local.
5. `af4f29f` — `feat(spatial-index): N=3 active/standby HA via NATS KV leader election` — bucket `idx_spatial_leader`, TTL=3s, heartbeat=1s, put-then-read-back claim. Three-node failover smoke-tested A→B→C with no state-rebuild gap. spatial-index v1 is now production-shape.

### 2026-05-01 commits (in order, all on origin/master pending push):

1. `77cc274` — `feat(ai-sim foundation): Lua 5.4 binding + BT runtime + YAML loader` — vendored PUC Lua 5.4.8 under `vendor/lua/`; thin C binding in `src/shared/lua/lua_c.zig`; comptime marshaling in `lua_bind.zig` (Vm, push/pull, registerFn, callFn). BT runtime in `src/shared/bt.zig` with all six node types and a `LeafDispatcher` interface (mock-backed in tests). Tree YAML loader in `src/shared/bt_loader.zig` — custom mini-parser since ymlz can't handle our heterogeneous-node schema cleanly. `data/ai/pirate_sloop.yaml` is the first archetype. Doc 09-ai-sim.md ratified; root `THIRD_PARTY_LICENSES.md` added.

2. `33d4064` — `feat(ai-sim): service skeleton — 20 Hz BT loop + Lua dispatch + mtime watcher` — `src/services/ai_sim/{main,state,dispatcher}.zig`; placeholder `data/ai/pirate_sloop.lua`; build.zig wires the exe + the two test modules. main.zig: parseArgs (--nats, --archetype, --leaves, --ai-ship repeatable), 20 Hz fixed-step accumulator (5-tick spiral cap, mirroring ship-sim M5.1 pattern), drains `sim.entity.*.state` + `env.cell.*.wind`, ticks each cohort AI's BT, publishes `sim.entity.<ai_id>.input` if a leaf set `pending_input`. dispatcher.zig: `LuaDispatcher` resolves leaf names as Lua globals via `lua.c.getglobal`, returns bool for cond and `bt.Status` parsed from the @tagName string for action. Missing globals + Lua errors fail closed. state.zig: cohort = `entities: AutoHashMapUnmanaged(u32, WorldEntity)` + `ais: ArrayListUnmanaged(AiShip)`. mtime-poll watcher reloads archetype + leaves on touch — independent reload paths, best-effort on failure. 9 tests (3 state + 6 dispatcher).

3. `1bffaf0` — `feat(ai-sim): perception ctx + set_input helpers + real pirate_sloop leaves` — `src/services/ai_sim/perception.zig` (new), `dispatcher.zig` extended, `pirate_sloop.lua` rewritten with real bodies. perception.PerceptionCtx per docs/09 §7.1 v1: own_pose (with yaw quat from heading_rad), own_vel, own_hp (stub 1.0), wind (stub 0/0), cell, nearest_enemy filtered by `kindOf == .ship` within `archetype.perception_radius`. dispatcher.LuaDispatcher.init() stashes self in Lua registry under `_notatlas_ai_dispatcher`, registers `set_thrust`/`set_steer`/`set_fire` as Lua-callable C fns that mutate `current_ai.pending_input`. `beginAi(ai, ctx)` pushes ctx as Lua global; `endAi()` clears it. main.zig threads `archetype.perception_radius` and `--cell-side` arg through, builds perception per AI per tick. `pirate_sloop.lua` now reads ctx and computes bearing/heading math: forward = (sin h, 0, -cos h); aim_broadside targets `desired = bearing - π/2` to hold enemy on starboard; fire_broadside is a single `set_fire(true)` (BT cooldown gates re-entry). 7 new tests.

4. `151fc55` — `docs(roadmap): combat slice — AI sloop opponent done` — ticked the AI-sloop line in the combat-slice row.

5. `9dc5063` — `feat(combat): plank/hull damage + ship sinking` — StateMsg.hp + DamageMsg wire types in cell_mgr/wire.zig (4 tests). Entity gains hp_current/hp_max/applyDamage/isSunk; State.projectiles ArrayList of in-flight cannonballs (ship_sim/state.zig, 2 tests). main.zig: sloop_max_hp=300 (6-hit sink), projectile_lifetime_s=6, fireCannon appends a ProjectileTrack, new resolveProjectileImpacts walks tracks and AABB-tests against ships using `notatlas.projectile.predict`, deducts HP, publishes `sim.entity.<id>.damage`, retires hits. destroySunkShips runs after state publish so the final hp=0 msg goes out before teardown; passengers ejected via existing applyDisembark. ai-sim: WorldEntity gains hp from StateMsg.hp; perception.nearestEnemy filters hp ≤ 0; own_hp is now real (replaces 1.0 stub) — low_hp flee branch becomes reachable. Smoke: AI ship#3 hit ship#4 six times over ~4 minutes, ship#4 SUNK at hp=0. Caveat: AI broadside-aim has stability issues at the ±π wrap; that's a separate AI-tuning pass.

6. `9ec074b` — `feat(combat): wind-driven sail force model (closes Phase 1 gate)` — ship-sim's placeholder thrust force model replaced with square-rig sail physics. `thrust` ∈ [0,1] is now sail trim; force comes from wind via `force = trim × max × sign(wind∥) × (wind∥/baseline)²` where wind∥ = wind_velocity · ship_forward. Wind from astern pushes the bow forward; beam wind gives no forward force; wind from ahead pushes the ship backward (square rig can't sail upwind). Negative thrust clamps to 0 (sails can't reverse-thrust). New constants `sail_force_max_n`, `wind_baseline_mps`, `default_wind_dir_rad`, `default_wind_speed_mps`. New CLI flags `--wind-dir <rad>` and `--wind-speed <mps>`. Wind hardcoded process-wide for v0; Phase 2's env service plumbs through. Smoke verified in 3 wind scenarios: downwind ship moves -Z, headwind ship moves +Z, no wind ship stationary. docs/04 row 45 flipped from ◐ to ✓ — Phase 1's combat-slice gate is now CLOSED.

7. `326a7c8` — `feat(ship-sim): --layout circle + --ship-max-hp knob` — `--layout {line,grid,circle}` replaces `--grid` bool (now back-compat alias). Circle places N ships at radius `spacing/(2·sin(π/N))` for chord-spacing semantics. `--ship-max-hp <hp>` overrides the spawn HP per ship (default 300 = 6 cannonball direct hits). Test-scenario primitives; defaults unchanged.

8. `d421cca` — `feat(env-sim): per-cell wind service @ 5 Hz; ship-sim + ai-sim consume` — first Phase 2 service. New `WindMsg {vx, vz}` (world-frame velocity m/s) on `env.cell.<x>_<z>.wind`. New `src/services/env_sim/main.zig` — 5 Hz tick, loads `data/wind.yaml`, samples `notatlas.wind_query.windAt` at each cell center, publishes per-cell. Default 3×3 around origin; `--cell` flag adds cells. ship-sim subscribes, caches per-cell, looks up wind by ship pose (CLI `--wind-dir`/`--wind-speed` are fallback when env-sim is offline). ai-sim's `drainWindSub` decodes into a per-cell cache; `perception.build` pulls (vx, vz) for AI's cell, converts to (dir, speed) for ctx.wind (replacing `{0,0}` stub). Wire convention: raw vector on the wire, ai-sim's perception ctx exposes (dir, speed) where dir=0 = blowing toward −Z. End-to-end smoke: env-sim 45 pubs/s; ship#3 visibly responds to env wind even with `--wind-speed 0`; ai-sim counts 45 wind-msgs/s. 4 new tests.

9. `f316654` — `docs(roadmap): env service partial — wind shipped` — env service row flipped from ▢ to ◐. Weather (extended storms), wave-seed publish, time-of-day still pending; same `env.cell.<x>_<z>.*` surface for each.

10. `af9543c` — `feat(ai-sim): PD heading controller — angvel_y in StateMsg → ctx.own_vel.ang.y` — plumbed Y-axis angular velocity from Jolt through the firehose so the AI's heading controller can damp on yaw rate. StateMsg.angvel_y default-zero (back-compat via `ignore_unknown_fields`); ship-sim populates from `phys.getAngularVelocity(body)[1]`; ai-sim WorldEntity carries it; perception.PerceptionCtx exposes via `own_vel.ang.y` (other ang axes still 0). pirate_sloop.lua steer_toward is now PD: `clamp(Kp*diff - Kd*ω, -1, 1)` with Kp=2/π, Kd=0.5. Stale `low_hp` "stubbed" comment deleted (hp went real in `9dc5063`). Tests: 2 wire roundtrips, cohort observe-angvel, perception ang.y plumb-through, dispatcher 3-case PD math pin (zero ω → saturate; mid ω → still demanding; overshoot ω → command brake-flips negative). Live tune of Kd deferred — needs an isolated near-π reproducer (the wind constraint dominates current circle-layout smokes).

11. `e959d8f` — `fix(ai-sim): broadside-aim sign, wrap hysteresis, --layout duel fixture` — the PD plumbing in `af9543c` was correct math but applied with the wrong sign. Torque calc on the lateral-force-at-bow model: forward = (-sin θ, 0, -cos θ) (Y-up R_y(θ) on local -Z); lateral = forward × (0,1,0) = (cos θ, 0, -sin θ); τ_y = (r×F)_y = -bow_offset × steer_max_n × steer. So +steer → NEGATIVE τ_y → heading decreases. Original `clamp(diff * (2/π), …)` was wrong-sign but invisible in line layout because every spawn pre-aimed cannon at neighbour (heading=0 → starboard=+X → ship#3 fires straight at ship#4 with no rotation needed). Fix: steer_toward emits `-(Kp*diff - Kd*ω)`; comment rewritten with the actual derivation. Symmetric-wrap hysteresis added: when |diff| > π−0.3, follow ω if |ω| > 0.3 rad/s (well above wave jitter ~±0.05 on stationary sloop in 8 m swell), else default to positive. New `--layout duel` ship-sim fixture (hard-codes N=2 regardless of --ships): ship#1 at origin facing -Z, ship#2 at -X by --spacing — forces ≈π rotation, exactly the wrap case. Smoke (`--wind-speed 0` to isolate from sails): ship rotates 0→±π in ~10s, locks in, lands hits. Caveat: line-layout WITH env-sim wind drops hit-rate vs no-wind because moving-while-aiming costs alignment — `aim_broadside` should drop thrust to ~0 while |diff| is large; carved out as follow-up #2 in the pickup section.

12. `8934526` — `feat(spatial-index): cell-transition hysteresis; ship-sim --init-vel-x` — running the cross-cell transit smoke surfaced a real bug: spatial-index thrashed exit/enter deltas every state msg for any ship parked near a cell boundary because wave-induced sub-mm drift on z=0 flipped `floor(z/side)` between 0 and -1. Fix: `State.cell_hysteresis_m` (default 1 m). When `posToCell` disagrees with the entity's current cell, only declare a transition once the entity is at least `cell_hysteresis_m` past the shared boundary into the new cell. Diagonals (both x and z change at once) require both axes to clear, so corner-grazes don't ping-pong between three cells. 4 new state-level tests cover wave jitter, single-axis release, negative-axis symmetry, diagonal corner-clip. Also adds `--init-vel-x` to ship-sim (`phys.setLinearVelocity(ship#1.body, .{vx, 0, 0})` post-spawn) so the smoke can move a ship across a boundary without an AI or interactive driver.

13. `051df59` — `test(transit): cross-cell ship-transit smoke harness` — `scripts/transit_smoke.sh` orchestrates spatial-index + cell-mgr 0_0 + cell-mgr 1_0 + ship-sim --init-vel-x 600, registers a synthetic subscriber, and dumps deltas + entity-table populations + fanout frame counts. Verifies the cross-cell milestone end-to-end: clean exit on 0_0 + enter on 1_0 at the boundary (no thrash). Initial commit registered the sub with both cells; that turned out to be a misuse — see `019b396`.

14. `019b396` — `fix(transit-smoke): register subscriber with primary cell only` — re-reading fanout.zig made it clear: cell-mgr's `relayState` is a pure-geometry filter BY DESIGN. Subscribers register with their PRIMARY cell only; the cell-mgr that owns the sub forwards every entity within visual tier of the sub's pose, regardless of which cell the entity is in. Cross-cell visibility is the geometry filter, not multi-cell registration. The original transit-smoke registered with both cells, double-counting forwards (689 frames vs the correct ~450). Fix is in the smoke: register with cell 1_0 only, sub at (300, 0, 0). Verified: cm 0_0 max subs = 0 (ship-in-cell-but-no-sub-here → 0 pushed), cm 1_0 max subs = 1 (pushes 2 state msgs/tick continuously, including while ship is in cell 0_0). 453 frames over 5 s. Cell-mgr code unchanged.

15. `8d61dcf` — `feat(ai-sim): aim_broadside slacks sails during large rotations` — the planned thrust-vs-aim follow-up to `e959d8f`. When |heading-error| > 0.3 rad (~17°), set_thrust(0.0); below that, set_thrust(0.4) to maintain orbit speed. Confirmed correct behavior in duel + no-wind: ship rotates 0→±π without sailing off the orbit, hit lands. BUT: line+wind smoke still gets 0 hits in 90 s. Root cause is NOT aim drift, it's the cannon's vacuum-ballistic arc starting 10-19 m above sea level when the ship rides 8 m swell — projectile lands well above/below sea-level targets. Wave-pitch compensation needed.

16. `352a5b8` — `feat(ship-sim): yaw-only cannon basis + closed-form pitch compensation` — fixes the wavy-water hit-rate problem head-on. Two changes inside `fireCannon`: (a) strip pitch/roll from the body's quat before computing muzzle position + firing direction, so the cannon is gimbal-mounted and stays at `ship.y + cannon_offset_y` aimed along ship-local +X regardless of how the deck is rocking; (b) find nearest enemy ship within `cannon_range_m` (200 m, exceeds AI's 180 m) and solve closed-form ballistic for tan(θ_p): `a·x² − R·x + (a − h) = 0` where `a = g·R²/(2v²)`, R = horizontal range, h = muzzle.y − target.y. Take low-arc root; D<0 or no target → horizontal fire. aim_quat = quatMul(yaw, pitch) where pitch is around local +Z. Determinism preserved (closed-form on inputs already in FireMsg). Smoke (90 s windows): duel no-wind 1→7 hits, duel+wind 0→1, line+wind 0→2. Player firing benefits identically (same `fireCannon` path).

17. `8e4a7ca` — `feat(ship-sim): pitch lead for moving targets in fireCannon` — extends the closed-form solver from `352a5b8` with target-velocity prediction. Iterative fixed-point: starting with target's current pose, compute pitch + flight time, advance aim point along target velocity, repeat 3 times. Converges fast for typical sloop ranges. Lead is PITCH-only — yaw stays starboard (broadside fixed-aim per docs/03 §8). Cross-track motion remains uncompensated; that's where the EVE-transversal model lands. Smoke vs +30 m/s moving target: 0→10 hits/60 s. No regression on stationary (7→8). Adds `--duel-target-vel-x <m/s>` to ship-sim — only honored in duel layout, sets ship#2's spawn velocity along +X so the lead solver has something to track.

18. `e4ce7e4` — `feat(hulls): inheritance-aware hull config (extends-chain) + multi-cannon` — migrates per-hull tuning out of Zig consts into `data/hulls/<tier>.yaml`. Schema: half_extents, mass_kg, hp_max, buoyancy (cell + samples), sail_force_max_n + sail_baseline_mps, steer_max_n, cannons[] (per-cannon offset_xyz + cooldown_s + range_m). New `_base.yaml` is the reference; `sloop.yaml` is `extends: _base.yaml` with no overrides. Hand-rolled flat-key parser in `src/hull_loader.zig` (ymlz can't handle missing fields, which kills extends — children deliberately leave most fields empty). Merge rule: child wins for any non-null scalar; arrays (sample_points, cannons) REPLACE wholesale when child sets them. `max_extends_depth=8` bounds cycles. 5 loader tests + ship-sim regression smoke (duel+moving target: 10 hits/60 s, matches pre-migration). `fireCannon` now iterates over `hull.cannons[]` for broadside-salvo support; `salvo_cooldown_s = max(c.cooldown_s)` gates on slowest gun. Future ship tiers (schooner, brig) author a YAML with `extends: _base.yaml` plus deltas — sail force, hp, cannon count, mass.

### Crisp status

**Phase 1 (combat foundation): ✅ CLOSED 2026-05-01**
- ✅ ship-sim 60Hz Jolt+buoyancy multi-ship
- ✅ Gateway JWT-validated multi-client TCP↔NATS
- ✅ M1.5 stress gate (32.1% of 1 Mbps budget)
- ✅ Cannon fire end-to-end (press F → cannonball flies)
- ✅ Board/disembark + free-agent player capsule
- ✅ Lever-arm velocity inheritance on disembark
- ✅ AI sloop opponent
- ✅ Plank/hull damage system + sinking
- ✅ Wind-driven sails (square-rig model, hardcoded wind for v0)

**Phase 2 (architectural payoff):**
- ✅ cell-mgr (multi-commit, all sub-steps)
- ✅ spatial-index v1 — entity→cell oracle, attach gating, radius queries, N=3 HA, cell hysteresis (`8934526`)
- ✅ AI broadside-aim — PD + hysteresis + sign correction + pitch lead (`af9543c` `e959d8f` `8d61dcf` `8e4a7ca`)
- ✅ Cross-cell ship transit (`8934526` + `051df59` + `019b396`) — clean handoff, continuous fanout, smoke harness. relayState's pure-geometry filter is intended design.
- ✅ Wave-pitch cannon compensation (`352a5b8` + `8e4a7ca`) — yaw-only basis + closed-form ballistic + target-velocity lead. Determinism preserved; player firing benefits identically.
- ✅ Hull config inheritance (`e4ce7e4`) — `data/hulls/<tier>.yaml` with `extends:` chain, hand-rolled loader, multi-cannon support. Ship-tier authoring is now data-only.
- ◐ env service — wind shipped 2026-05-01 (`d421cca`); weather/waves/ToD still ▢. Probably blocks on persistence-writer (storm schedules persist).
- ▢ **persistence-writer service** ← NEXT (see top of file)
- ▢ M10/M11/M12 (gpu-driven instancing, structure LOD merge, animation LOD) — client-side, orthogonal

---

## Reproduce baseline before building

```
./zig-out/bin/env-sim &                          # 5 Hz wind publisher
./zig-out/bin/ship-sim --shard a --ships 5 --players 0 &
./zig-out/bin/ai-sim &                            # default --ai-ship 3
```

After ~90 seconds: ai-sim ship#3 should land hits on ship#2 / ship#4
(observable in ship-sim log as `ship-sim: hit 0x01000002 ← ...`).
After ~4 minutes: a ship should be SUNK.

For the player loop (manual driving / firing):
```
./scripts/drive_ship.sh
```
- WASD walks, B boards nearest ship, G disembarks, F fires.
- Spawns 5 ships in a line at x=0..240 (default `--layout line`).
- New: `--layout circle --spacing 80` for the ring formation
  test scenario; `--ship-max-hp 1500` for long damage soaks
  without ships sinking out.

```
./scripts/m1_5_run.sh 30 50 single
```
- Phase 1.5 stress gate. Run periodically — should still pass at
  ~32 % of 1 Mbps budget (32.1 % was the multi-gateway baseline
  before sails/damage/env. Regression here would indicate the new
  per-tick wind lookups or impact resolver are eating CPU.)

## Architectural invariants to honor

- **Top-byte entity-id tagging** is load-bearing everywhere now —
  `notatlas.entity_kind` for kindOf/seqOf/pack. See
  `architecture_entity_id_kind_tag.md`.
- **ai-sim is decisions-only.** Its only output is
  `sim.entity.<ai_id>.input` indistinguishable from gateway's
  player input. ship-sim has no AI-specific code path. See
  `architecture_ai_sim_decisions_only.md`.
- **NATS-everywhere IPC.** Don't propose gRPC/REST/in-process
  collapses without load-bearing reason. See
  `feedback_nats_everywhere_ipc.md`.
- **Graceful degradation.** Every cross-service interaction must
  define reduced-state behavior. ship-sim falls back to CLI wind
  when env-sim is offline; ai-sim's leaves fail closed on Lua
  errors; spatial-index standbys keep state current. See
  `feedback_graceful_degradation.md`.
- **Lua 5.4 + thin C binding** (NOT LuaJIT, NOT ziglua wrapper).
  TS-via-tstl is the planned authoring layer. See
  `architecture_lua_54_thin_c_binding.md` and
  `project_typescript_dev_frontend.md`.

## Memory hygiene reminder for tomorrow-me

- All 18 commits from 2026-05-01 (`33d4064` → `e4ce7e4`) are
  **pushed to origin/master**. Confirmed `77cc274..e4ce7e4`.
- Dev nats broker is left running (`make nats-up` was called).
  Stop with `make nats-down` if a fresh start is wanted.
- nats-box CLI: `podman run --rm --network host docker.io/natsio/nats-box:latest nats <cmd>`.
  NATS broker uses `--network host` per `dev_nats_podman_host_network.md`.
- Step 6c (batched `idx.spatial.query.radius` per AI per tick)
  is still deferred — lift when AI count > ~30. v0 still uses
  the firehose table walk in `perception.nearestEnemy`.
- spatial-index's `idx.spatial.cell.*.delta` migration to
  JetStream-backed for failover catch-up is flagged in
  `af4f29f`'s commit body. Revisit when JetStream
  consumer-group cell-mgr work happens.
- NATS 2.14 dropped 2026-04-30 — dev compose still on 2.10.
  **Bump as part of the persistence-writer kickoff** — workqueue+
  mirror pattern requires 2.14+. See `docs/02-architecture.md`
  decision 5.
- No PG dep yet in `build.zig.zon` — research zpg / pg.zig /
  libpq-thin-C-binding (per `feedback_thin_c_bindings.md` default
  to thin-C if no clean Zig 0.15 option) when persistence-writer
  starts.
- `infra/compose.yml` doesn't exist for notatlas yet —
  fallen-runes has one with postgres + nats. Likely first persistence-
  writer commit ships compose + init.sql.
