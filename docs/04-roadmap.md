# 04 — Roadmap

Phased delivery plan with stress-test gates between phases. Phase 0 begins
solo on the engine; later phases absorb additional devs.

Status legend: ✓ shipped (commit) — ▢ pending — ◐ in progress.
Status reflects engineering completion against the milestone's gate, not
balance / polish. Cell-mgr enhancements built on top of M6/M7 (cluster
pathway, fast-lane callback relay, slow-lane cleanup, cross-cell
visibility) ship as separate commits — see `git log` for the full arc.

## Phase 0 — Engine water lift (solo, ~2-4 months)

Build the new engine subsystems that fallen-runes doesn't have. Subsystems
M1 through M5. No networking, no combat. Single-player in sandbox.

| Status | Milestone | Deliverable |
|---|---|---|
| ✓ `a814d1f` | M1: wave-query | Deterministic wave heights; client/server identical to float epsilon |
| ✓ `3bd0478` | M2: ocean-render | Beautiful Gerstner ocean visible in sandbox at 60 fps |
| ✓ `93c0ae0` | M3: buoyancy | A box floats correctly on waves; pitches and rolls; stable for 5 min |
| ✓ `68f8793` | M4: wind-field | Wind direction visible via debug arrows; storms travel across world |
| ✓ `d1f4976` | M5: ship-as-vehicle | Player walks on pitching box without jitter; multiple players supported |

**End-of-phase fun check:** walk around a pitching box on a beautiful
ocean with wind blowing for 20 minutes. If this isn't fun, no MMO
frame fixes it. (Verified 2026-04-28 — gate held.)

**Phase gate:** stop and verify each milestone hits its gate before
moving on. M3 specifically — a box that floats wrong cascades through M5
and Phase 1.

## Phase 1 — Networked ship combat (solo, ~2-3 months)

Wrap Phase 0's engine in the networking layer. Subsystems M6 through M9
plus integration with fallen-runes' gateway / ship-sim service decomp.

| Status | Milestone | Deliverable |
|---|---|---|
| ✓ `6ce6a33` | M6: tier-replication | Synthetic test passes — 100 entities, 50 subscribers, correct tier |
| ✓ `c2e050d` | M7: pose-compression | 1M roundtrip poses; max <1cm error; ≤16 B wire (codec: `9d00323`; integration: `c2e050d`) |
| ✓ `97e8049` + `ca57b02` | M8: deterministic-projectile | 1000 fires gate green (~3× O(dt) drift). ship-sim drives cannon FireMsg publishes via InputMsg.fire (1.5 s cooldown, starboard mount); cell-mgr fanout's fire-lane forwards to subs; gateway forwards to TCP with kind=1 frames. End-to-end: press F → cannonball flies. |
| ✓ `e7d4419` | M9: lag-comp-rollback | 60 Hz rewind buffer; 50 ms / 200 ms ping rewind matches target view to one-tick precision (~8 cm @ 5 m/s); 250 ms cap rejects "shot around corners." Hit-test routine lives at the caller; module is the rewind primitive |
| ✓ multi-commit 2026-05-01 | Integration | ship-sim service running 60 Hz Jolt+buoyancy multi-ship (`6c3f229`/`d8b884a`); JWT-validated multi-client gateway TCP↔NATS bidirectional (`51af4ee`/`ed76523`/`7b446bf`/`ff3141d`); ship-sim input subscription closes the player-control loop (`16c3701`). One cell; 30 ships verified at M1.5. |
| ✓ multi-commit 2026-05-01 | Combat slice | Sloop with cannons (✓ ship-sim cannon fire end-to-end via TCP). Free-agent player capsule + board/disembark with lever-arm velocity inheritance (✓ `3798f72`). AI sloop opponent (✓ `33d4064`+`1bffaf0`: ai-sim service ships at 20 Hz with BT runtime + Lua leaves + perception ctx). Plank / hull damage + sinking (✓ `9dc5063`: cannonball impact resolution, HP per ship, sinking at HP=0 — verified end-to-end with AI ship#3 sinking ship#4 over 4 minutes of broadside fire). Wind-driven sails (✓ next commit: square-rig sail force model — wind from astern pushes the bow forward, beam wind gives no forward force, wind from ahead pushes the ship backward; wind hardcoded for v0 via `--wind-dir`/`--wind-speed`, env service plumbs through in Phase 2). |

**Milestone 1.5 stress test (gate before Phase 2):** ✓ shipped 2026-05-01
- 30 boxes in one cell × 50 simulated clients × actual gateway / NATS
  path → **PASS in BOTH gateway topologies:**
  - Multi-gateway (50 procs, original verification): 32.1% of 1 Mbps/client (321.4 kbps, variance ≈ 0)
  - Single-gateway+JWT (1 proc, 50 conns, post `7b446bf`): 17.3% of 1 Mbps/client (172.5 kbps, variance ≈ 0; lower frame rate due to single-threaded gateway loop, headline gate still passes)
- ship-sim --ships 30 --grid --spacing 30 (worst case: all ships
  inside the 500 m visual tier from every sub at origin)
- Cannonball stream now also integrated end-to-end (`ca57b02` + `ff3141d`)
  — F key fires starboard cannon, fire frames return as kind=1 TCP
  frames. Bandwidth impact negligible (sparse + JSON + small payload).
- See `docs/research/m1_5-stress.md` for full numbers + caveats.

**End-of-phase deliverable:** 4 friends + you on a sloop, fighting an AI
sloop, sinking it. Sub-100ms perceived latency, no stutter.

## Phase 2 — Multi-cell grid + harbor renderer (solo or +1 dev, ~3-4 months)

The architectural payoff. Subsystems M10 through M12 plus cell-mgr,
spatial-index, env, persistence-writer services.

| Status | Milestone | Deliverable |
|---|---|---|
| ✓ multi-commit | Cell-mgr service | Skeleton (`30a3806`) → cluster pathway (`47f3e74`) → fast-lane callback relay (`21c0283`) → slow-lane cleanup (`54a2300`) → cross-cell visibility (`60d0241`) → fast-lane batching (`d769f65`) → fire-lane (`2e2bb17`). Subscribes to spatial-index deltas; runs 30 Hz fanout tick + 60 Hz fast-lane batched relay. |
| ✓ multi-commit | Spatial-index service | v1 complete (2026-04-30). Skeleton (`b08f339`) → aboard-ship gating via `idx.spatial.attach.*` (`3798f72`) → `idx.spatial.query.radius` req/reply (`85d6ae4`) → N=3 active/standby HA via NATS KV leader election (`af4f29f`). All round-out items shipped. Open: `idx.spatial.cell.*.delta` migration to JetStream-backed for clean failover catch-up — deferred until cell-mgr's JetStream consumer-group story lands. |
| ✓ multi-commit 2026-05-11 / 2026-05-12 | Env service | All four broadcasts shipped. Wind (`d421cca`) — 5 Hz `env.cell.<x>_<z>.wind` from `data/wind.yaml`. Waves (`f46c044`) — 5 Hz `env.cell.<x>_<z>.waves` preset broadcast, ship-sim subscribes for runtime preset swap. ToD (`763f7cf`) — 1 Hz `env.time` carrying `world_time_s` + `day_fraction`. Storms (`6881a50`) — 1 Hz `env.storms` with addressable storm entities (Kind.storm=0x04). Consumers wired: ship-sim (wind+waves), ai-sim (wind+storms → perception ctx, `flee_to_storm_cover` leaf), gateway (env.time → raid-window login gate, `data/raid_windows.yaml`, fail-open until first publish per graceful-degradation). Smokes: `wave_broadcast_smoke.sh`, `time_of_day_smoke.sh`, `storms_smoke.sh`, `storm_cover_smoke.sh`, `raid_window_smoke.sh`. |
| ✓ multi-commit | Persistence-writer service | v1 shipped 2026-05-10. 4 workqueue streams (sessions / market trades / cell handoffs / inventory changes); tier-0 fast lane + slow tier round-robin; stream_seq idempotency + ack_wait 300s (`3295f6a`); live metrics + `admin.pwriter.status` snapshots (`05d82f7`); 5-harness smoke suite (`c87d130`). Sole PG writer; never on the hot path. |
| ✓ multi-commit | SLA-arc producers | All 4 producers shipped 2026-05-10 / 2026-05-11. `events.session` ← gateway on login + paired disconnect (`6b3f87f`); `events.handoff.cell` ← spatial-index on cross-cell transition (`5c80027`); `events.market.trade` ← market-sim order matching v0 (`28c345c`); `events.inventory.change.<id>` ← inventory-sim batched + coalesced (`0abb788` + `a386fb7`, 60 s flush + PG hydration). |
| ✓ multi-commit | Cross-cell ship transit | Sloop sails A→B with no stutter via `idx.spatial.cell.*.delta` + cell-mgr's geometry-filter `relayState` (`8934526` + `051df59` + `019b396`). Transit smoke (`transit_smoke.sh`) hard-asserts both visual continuity and cell_handoffs PG rows. |
| ✓ multi-commit 2026-05-12 | SLA-arc multi-stream stress | Multi-stream stress gate on the persistence arc — all 4 producers concurrent, 30 s sustained @ 1000 inv/s + 200 market/s + 100 handoff/s + 100 session/s. Surfaced + fixed session fast-tier SLA breach via fast-lane interleave + 1 ms nats-zig timeout floor workaround (`bad87bc` + `5e8e270` + `2b69ea3`). New comfortable ceiling: 1000 inv/s sustained (122 ms session p99, 40 % under SLA); 1500 inv/s is bursty. Per-batch `--trace-batches` instrumentation in pwriter as a permanent diagnostic surface. See `docs/research/sla_arc_stress.md`. |
| ✓ multi-commit 2026-05-12 | M10: gpu-driven-instancing | Mesh palette + SSBO-driven instancing (`15ec0cd`) → `vkCmdDrawIndexedIndirect` (`f22d262`) → synthetic gate harness + clearance (`0e717aa`) → GPU compute frustum culling (`5bf5712`). Gate on RX 9070 XT @ 5045 instances × 20 piece types, MAILBOX, 10 s: avg 0.83 ms, p99 1.85 (cull ON) / 2.25 (cull OFF), fps 1200. ~20× headroom on the 16.67 ms budget. M10.3 cull primitive earns its keep at M11's higher-poly piece geometry; at unit-cube scale the rasterizer savings wash with the compute dispatch cost. Side win: the prepareFrame/record split (needed to dispatch compute before the render pass) lets CPU bucket-scatter run in parallel with the previous frame's GPU work, cutting baseline 1.93 ms → 0.83 ms. |
| ✓ multi-commit 2026-05-12 | M11: structure-lod-merge | Merge primitive + far-LOD pipeline (`94db6c1`) → Anchorage + LOD switch with ±10% hysteresis (`93a50ce`) → off-thread merge worker + double-buffered swap (`1ccedb1`) → gate harness + smoke (`<this commit>`). Gate on RX 9070 XT @ 500 pieces × 20 piece types × 50 m radius, MAILBOX, 10 s: max merge 2.33 ms (≤100 ms ✓), far-LOD draws=1 ✓, avg+p99 frametime well under 16.67 ms ✓. Worker path exercised by mid-soak auto-invalidate at t=3 s. `scripts/m11_gate_smoke.sh`. |
| ✓ multi-commit 2026-05-12 | M12: animation-lod | Three-tier dispatch (`<this commit>`): `.near` ≤30 m / `.mid` ≤100 m (5 Hz) / `.far` zero-CPU. Placeholder anim — no skeletal system yet; per-tier work via configurable `bone_count` knob (`src/render/anim_lod.zig`). Far tier driven by `instanced.vert` reading `cam.eye.w` + per-instance `meta.yz` (phase + amplitude); near/mid run synthetic skin work but don't write to the instance buffer (matches the M27 swap-in shape — real skinning writes a skin-palette SSBO, not back to model). Gate on RX 9070 XT @ 200 chars, three-band placement (~67 near / ~67 mid / ~66 far), MAILBOX, 10 s: cpu-anim avg 0.039 ms / p99 0.055 ms / max 0.094 ms (gate ≤2 ms ✓), far tier skipped ✓, frame avg+p99 well under 16.67 ms ✓. Synthetic baseline only; M27 re-gate against real glTF rigs is the load-bearing comparison — see `docs/research/m12_animation_lod_synthetic.md`. `scripts/m12_gate_smoke.sh`. |

**Milestone 1.6 stress test (gate before Phase 3): ✓ 2026-05-12**
- Synthetic harbor scene — 500 random structures + 30 box-ships + 200
  dummy characters animated + 100 particle emitters firing
  simultaneously
- Target: 60 fps on RTX 4060 / RX 7600
- Profile with RenderDoc; any subsystem >2 ms gets fixed before content
- **PASS on dev box (RX 9070 XT, NOT the 4060/7600 spec target):**
  avg 0.83 ms / p99 1.85 ms (~20× headroom). M12 cpu 0.038/0.055 ms;
  particle stub 0.178/0.255 ms. All five gate clauses green.
  See `docs/research/m1_6_synthetic_harbor_stress_synthetic.md`.
  Particle stub is disposable (CPU-bound; real particle system is
  M17 in Phase 2.5). Re-gate on 4060-class hardware OR vs RX 9070 XT
  baseline is the load-bearing comparison; M27 owns this.

**End-of-phase deliverable:** the demo that justifies the project. A
3×3 grid; sail seamlessly across; smooth 200-character harbor scene.
The thing Grapeshot couldn't do.

## Phase 2.5 — Content pipeline & tooling (~3-6 months — sized for worst case)

The bridge between "engine algorithms proven at synthetic scale"
(Phase 2) and "engine survives real production content" (Phase 3).
Built around the FiveM-RP team workflow per memory
`project_asset_pipeline_fivem_team.md`: Blender / Photoshop /
Aseprite → drop file → small YAML manifest → hot-reload. The
TypeScriptToLua authoring layer per
`project_typescript_dev_frontend.md` lands here too — designers
write .ts, runtime executes Lua.

Closing this phase requires both the pipeline lift AND a re-gate of
the Phase 2 synthetic milestones against real assets — per
`feedback_synthetic_baseline_then_diff.md`, the diff isolates
content-shape regressions from algorithm bugs.

**Schedule note — plan for the worst:** the Houdini-Engine arc
(M22-M26) is sized for the worst-case scope (full SDK integration
with runtime cooking, parameter exposure, async cook worker,
point-instance procedural placement). Actual depth depends on the
dev team's workflow once they're onboard — if they prefer Blender
+ lighter procedural tools, the Houdini arc compresses to an
"HDA → glTF bake" workflow docs entry and the active milestone
count drops to M13-M20 + M27. The roadmap absorbs the worst case
so a late upshift doesn't re-open it.

### Base asset pipeline

| Status | Milestone | Deliverable |
|---|---|---|
| ▢ | M13: glTF static mesh loader | Lift fallen-runes' `gltf_loader.zig`; load + render a Blender-exported building piece in place of the procedural cube; hot-reload on file save |
| ▢ | M14: KTX2 texture + material v1 | Texture sampling pipeline; basic PBR (albedo + normal + roughness); material YAML manifest |
| ▢ | M15: Per-asset YAML manifest + hot-reload | `data/props/*.yaml`, `data/ships/*.yaml` — one file per unit; mesh + texture + material references; hot-reload extended to meshes / textures / materials |
| ▢ | M16: Skeletal anim format + skinning shader | Bone palette + per-vertex weights + animation clip format; GPU skinning shader; unlocks M12 re-gate against real rigs |
| ▢ | M17: Sprite + particle systems | 2D UI / decal / billboard pipeline (banners, signs); particle emitter system (M1.6's 100-emitter target lives here) |
| ▢ | M18: Map / scene editor | In-engine placement tool for anchorages, props, biomes; saves to YAML; matches FiveM in-game-editor convention |
| ▢ | M19: TypeScriptToLua content scripting | Designer-facing .ts authoring → Lua runtime per locked architecture; comparable to FiveM's resource manifest pattern |
| ▢ | M20: Onboarding doc + worked examples | "How to add a building piece" / "sail texture" / "animated NPC" — written for someone who's installed Zig once |

### Houdini Engine arc (worst-case scope; may compress per dev-team workflow)

| Status | Milestone | Deliverable |
|---|---|---|
| ▢ | M22: Houdini Engine SDK vendor + thin C bindings | Per `feedback_thin_c_bindings.md`: bind against SideFX's C API directly. Session lifecycle, headless cook smoke (cook a stock HDA, log mesh output; no engine integration yet) |
| ▢ | M23: HDA-as-asset in the manifest system | `.hda` recognized as an asset type in M15's manifest; cook → ingest into the M13/M14 mesh+material path; hot-reload on HDA save → re-cook |
| ▢ | M24: Parameter exposure → YAML + editor UI | HDA parameter interface read at load; YAML pins parameter values; M18 editor renders parameter widgets so designers iterate without leaving the engine |
| ▢ | M25: Async cook worker | Same pattern as M11.3 cluster-merge worker — long cooks (seconds) run off-thread; editor stays responsive; cook results applied with double-buffered swap |
| ▢ | M26: Point instances + procedural placement | Ingest HDA point output into the M10 GPU-instancing path; "designer authors a procedural anchorage in Houdini, drops the HDA, gets 500 placed pieces ready for M11 merge" |

### Re-gate (synthetic → real-asset baseline diff)

| Status | Milestone | Deliverable |
|---|---|---|
| ▢ | M27: Re-gate M10 / M11 / M12 / M1.6 with real assets | Each synthetic gate re-run with production glTF + KTX2 + rigs (+ HDA-cooked content if the Houdini arc shipped); per-gate diff doc against the synthetic baseline; content-shape regressions tracked per `feedback_synthetic_baseline_then_diff.md` |

**Practical notes (Houdini):**
- Houdini Engine is free to integrate into a host app per SideFX
  terms; users authoring HDAs need their own Houdini license
  (Indie / FX). The asset-authoring-license dependency is the cost
  of admission for the worst-case path.
- Default session model is **out-of-process** (Houdini crashes
  don't kill the engine); revisit if cook latency dominates.
- Library lookup goes through a `HOUDINI_PATH` env var, not
  vendoring — users have Houdini installed elsewhere on disk.

**Shipping model note (carried from prior preamble):** The shipping
model can differ from FiveM's (we likely want pre-baked deterministic
client builds with content versioning, not on-demand client
downloads), but the **authoring** workflow should feel familiar.

**Phase gate:** the FiveM-RP team onboards with the worked-example
doc only — no architect intervention — and produces a new building
piece, sail texture, and animated NPC end-to-end. The re-gate diffs
against synthetic baselines are published; any regression attributed
to content shape (not algorithm) gets a tracked follow-up.

**End-of-phase deliverable:** the engine is a *real* game engine
ready for content. Phase 3's "land the actual game" work no longer
gated on tooling.

## Phase 3 — Survival, crafting, progression (solo or +1-2 devs, ~4-6 months)

The actual game. With architecture proven (Phase 2 synthetic) AND
real-asset performance confirmed (Phase 2.5 re-gate), content lands
on a known-good substrate.

| System | Notes |
|---|---|
| 4-5 disciplines | Sailing, Combat, Survival, Crafting, ?Captaineering |
| 3 ship tiers | Sloop, Schooner, Brigantine. Galleon deferred |
| Crafting system | ~15 resource families, sub-types, biome distribution |
| Quality tiers | Common → Mythical with stat rolls |
| Skill tree | Per-discipline mastery; data-driven recipes |
| Anchorages + structures | 500-piece cap per anchorage; static-bake LOD merge |
| Treasure-map dig loop | Bottle → map → dig site → soldiers + chest |
| Hibernation rules | Anchored = protected during raid windows |
| Company / guild | Reuse fallen-runes' guild patterns; alliance system |

**Phase gate:** friends-and-family closed playtest in a 3×3 grid. ~20-50
players over multiple sessions. Iterate on friction.

## Phase 4 — Vertical slice + closed playtest (~3-4 months)

| Activity | Notes |
|---|---|
| 5×5 grid | Production scale rehearsal |
| 50-200 invited players | Closed playtest |
| Full wipe cycle (~10 weeks) | Run end-to-end including wipe |
| Telemetry + observability | Identify what's loved, hated, broken |
| Engine bug-bash | Multi-session stability fixes |
| Balance pass | Data-driven adjustments; recipe tuning |
| Spatial-index regional sharding (if needed) | Build only if Phase 4 load reveals single-instance ceiling. Design ratified 2026-05-12 (this conversation, see below). |

**End-of-phase:** decision point. If the loop is fun, scale to open
playtest. If not, iterate.

### Deferred: spatial-index regional sharding

Design captured here so the build doesn't get stuck on a fresh design
pass when load actually demands it. Trigger: stress measurement (see
gates table) shows single spatial-index hits ingest or query ceiling
under realistic Phase 4 load.

**Cell ownership vs entity tracking — the load-bearing distinction.**

- Each cell has *exactly one* owner spatial-index. Cell→region map is
  static config (`data/spatial_shards.yaml` or KV bucket).
- Each spatial-index *tracks* entities in its own cells **plus** an
  overlap belt of border cells in neighboring regions. Both regions
  know about an entity near the boundary; only the owner of any given
  cell emits `idx.spatial.cell.<x>_<y>.delta` for that cell.
- When entity crosses from a cell owned by NW to a cell owned by NE,
  no coordination happens at the moment of crossing — both regions
  see the same `sim.entity.X.state` update via the broker's
  per-subject ordering, both apply the same deterministic rule (emit
  delta for cells in my owned set), the right region emits the
  enter / exit delta. No two-phase commit, no lease, no leader
  election for handoff.

**Audit-event emission (events.handoff.cell):** the region that owns
the *from-cell* emits the handoff event. Same rule as cell delta
emission, applied to the audit stream — exactly-once across regions
without coordination.

**Subject hierarchy stays unchanged.** Subjects are cell-keyed
(`idx.spatial.cell.<x>_<y>.delta`), not region-keyed. Going from 1
spatial-index to N is a service-internal config change; downstream
consumers (cell-mgrs, gateway, pwriter) don't notice. Rebalancing
the cell→region map at server restart is the only operational
knob — no migration protocol needed.

**Belt width tuning:**
- Width = 1 cell for slow entities (galleon at 10 m/s × 100 m cells
  takes 10 s to traverse one cell).
- Wider belt (e.g. 5 cells) if spatial radius queries near the
  boundary need to be answered without cross-region fan-out (a
  500 m sight-line on 100 m cells reaches 5 cells).
- Projectiles (fast, short-lived) likely don't cross regions in
  practice; if they do and we miss them, the cannonball just
  despawns at the boundary — accept it.

**Implementation lift (rough estimate when triggered):**
- Cell→region config + bootstrap: ~50 LOC
- Spatial-index CLI flags (`--region`, `--cells`, `--belt`): ~50 LOC
- Belt membership check in position-update handler: ~30 LOC
- Emit-gating logic for cell deltas + handoff events: ~20 LOC
- Cross-region transit smoke (entity sails across N regions, no
  gap in cell-membership signal, exactly-once handoff event): ~200
  LOC
- Total: roughly half a day of focused work once stress data justifies
  the build.

**Invariant relied on:** NATS preserves per-subject message ordering
across all subscribers. Today this holds because ship-sim shards by
entity-ID range (not by region), so a given entity always publishes
state from one ship-sim shard on one subject. If that invariant
changes — e.g. ship-sim ever migrates entities between shards mid-
flight — the deterministic-from-input property breaks and this
design needs revisiting.

**Why this isn't designing into a corner:** zero new coordination
primitives. State derives from `state = f(immutable_config,
ordered_inputs)`. Add regions, remove regions, rebalance — all
without anyone agreeing on anything at runtime.

**Architecturally consistent alternative considered:** shard
spatial-index by entity-ID hash instead of by region (matches how
ship-sim and pwriter already shard). Loses cell-locality cache
benefit; gains zero handoff problem because every shard sees every
entity it owns regardless of where the entity is. Revisit choice
when triggered — the answer might be "Option C" instead of
"Option A" depending on what the stress test reveals about whether
spatial queries (radius / polygon / LoS) dominate or whether the
position firehose ingest is the bottleneck.

## Phase 5+ — Content scale and live ops (open-ended)

Driven by playtest data and player demand. Possible additions:

- Galleon (4th ship tier)
- Submarine and/or diving platform
- Ramming Galley
- Additional biomes (polar, desert, equatorial — Atlas had 6 biomes)
- NPC crew variety beyond the v1 "hired hand" role
- Boss content (Kraken-equivalent, optional flavor)
- Trade economy with player markets and warehouses
- Additional disciplines (Music & Dance, Trade, Tarot, etc. — Atlas had
  16 originally)
- Taming and breeding (whole new system; entire content cycle of work)

## Stress-test gates summary

| Status | Gate | When | What it proves |
|---|---|---|---|
| ✓ verified 2026-04-28 (`93c0ae0`) | M3 stable for 5 min | Phase 0 | Buoyancy doesn't diverge |
| ✓ verified 2026-04-28 (`d1f4976`) | M5 multi-player | Phase 0 | Ship-as-vehicle works for >1 player |
| ✓ verified 2026-04-29 (`6ce6a33`) | M6 phase gate (synthetic + BW) | Phase 1 | 100×50 fanout correct + ≤1 Mbps slow-lane budget held |
| ✓ verified 2026-05-01 | Milestone 1.5 (live load) | Phase 1 → 2 | 50 conns × 30 ships × actual gateway/NATS path → multi-gateway 32.1%, single-gateway+JWT 17.3% of 1 Mbps/client budget |
| ✓ verified 2026-05-12 | SLA-arc multi-stream stress | Phase 2 | All 4 producers concurrent @ 1000 inv/s sustained, session SLA holds. Fast-lane interleave fix + nats-zig 1 ms timeout. Comfortable ceiling identified; bursty ceiling at 1500 inv/s. |
| ✓ verified 2026-05-12 (`5bf5712`) | M10 gpu-instancing gate | Phase 2 | 5045 instances × 20 piece types @ RX 9070 XT, MAILBOX, 10 s: avg 0.83 ms / p99 1.85 / fps 1200. ~20× headroom on 16.67 ms budget. M10.3 compute cull shipped + verified A/B against `--no-cull`. `scripts/m10_gate_smoke.sh`. |
| ✓ verified 2026-05-12 | M11 structure-lod-merge gate | Phase 2 | 500-piece anchorage × 20 piece types × 50 m radius @ RX 9070 XT, MAILBOX, 10 s, `--force-far`: max merge 2.33 ms (gate ≤100 ms, ~40× headroom — sync path; worker path used for invalidates), far-LOD draws=1 per anchorage (one `vkCmdDrawIndexed`), avg+p99 frametime under 60 fps budget. Mid-soak auto-invalidate exercises the M11.3 off-thread worker round-trip. `scripts/m11_gate_smoke.sh`. |
| ▢ | Single spatial-index throughput ceiling | Phase 4 prep | Stress with 1000s of synthetic entities publishing 60 Hz position firehose; measure delta-emit latency and query response time. Result determines whether regional sharding is needed before Phase 4 playtest or post-launch. |
| ✓ 2026-05-12 | Milestone 1.6 (synthetic harbor stress) | Phase 2 → 2.5 | 500 structures + 30 ships + 200 chars + 100 emitter stubs (disposable, CPU-bound; real particle system is M17). Gate on RX 9070 XT, MAILBOX, 10 s: avg 0.83 ms / p99 1.85 ms (~20× headroom on the 16.67 ms budget); M12 cpu 0.038/0.055 ms; particle stub 0.178/0.255 ms. All gate clauses PASS. Phase 2 client-side synthetic arc CLOSED. `scripts/m1_6_gate_smoke.sh`; baseline in `docs/research/m1_6_synthetic_harbor_stress_synthetic.md`. Particle stub explicitly disposable — delete at M17. |
| ▢ | M27 (M10/M11/M12/M1.6 re-gate with real assets) | Phase 2.5 → 3 | Re-run the Phase 2 synthetic gates against production glTF + KTX2 + rigs (+ HDAs if Houdini arc shipped). Per-gate diff vs synthetic baseline. Confirms the engine survives real artist content, not just placeholder geometry. |
| ▢ | Closed playtest | Phase 4 | The loop is actually fun |

If any gate fails, **stop and fix before adding content**. This is the
single most important discipline that Atlas lacked.
