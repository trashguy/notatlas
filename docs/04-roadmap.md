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
| ✓ `97e8049` | M8: deterministic-projectile | 1000 fires; closed-form predict matches Euler-ref within 0.15 m (~3× O(dt) drift). Vacuum ballistic v1; data/ammo/cannonball.yaml; sim.entity.<weapon>.fire wire format; integration with cell-mgr/gateway is a separate step |
| ✓ (uncommitted) | M9: lag-comp-rollback | 60 Hz rewind buffer; 50 ms / 200 ms ping rewind matches target view to one-tick precision (~8 cm @ 5 m/s); 250 ms cap rejects "shot around corners." Hit-test routine lives at the caller; module is the rewind primitive |
| ▢ | Integration | ship-sim service spun up; gateway routes; one cell |
| ▢ | Combat slice | One sloop with cannons, sails, planks, AI sloop opponent |

**Milestone 1.5 stress test (gate before Phase 2):**
- 30 boxes in one cell, each running buoyancy + a fake "I am firing
  5 cannonballs/sec" stream
- 50 simulated clients subscribed via the actual gateway / NATS path
- Verify per-client BW ≤1 Mbps, server tick stable at 60 Hz, NATS
  throughput within target
- Tune tier-replication thresholds in `data/tier_distances.yaml`
- **If this fails, fix before content lands.**

**End-of-phase deliverable:** 4 friends + you on a sloop, fighting an AI
sloop, sinking it. Sub-100ms perceived latency, no stutter.

## Phase 2 — Multi-cell grid + harbor renderer (solo or +1 dev, ~3-4 months)

The architectural payoff. Subsystems M10 through M12 plus cell-mgr,
spatial-index, env, persistence-writer services.

| Status | Milestone | Deliverable |
|---|---|---|
| ◐ skeleton at `30a3806` | Cell-mgr service | Subscribes to entities in its region via spatial index |
| ▢ | Spatial-index service | Single process, sharded-ready, owns membership deltas |
| ▢ | Env service | Wind, weather, wave seed, time of day at 5 Hz |
| ▢ | Persistence-writer service | Sole PG writer, batches change streams |
| ▢ | Cross-cell ship transit | Sloop sails from cell A to cell B with no stutter |
| ▢ | M10: gpu-driven-instancing | 5000 instances at 60 fps; ≤20 draw calls |
| ▢ | M11: structure-lod-merge | 500-piece anchorage merges <100 ms; far-LOD = 1 draw |
| ▢ | M12: animation-lod | 200 animated chars at varied distance; CPU ≤2 ms |

**Milestone 1.6 stress test (gate before Phase 3):**
- Synthetic harbor scene — 500 random structures + 30 box-ships + 200
  dummy characters animated + 100 particle emitters firing
  simultaneously
- Target: 60 fps on RTX 4060 / RX 7600
- Profile with RenderDoc; any subsystem >2 ms gets fixed before content
- **If this fails, fix before content lands.**

**End-of-phase deliverable:** the demo that justifies the project. A
3×3 grid; sail seamlessly across; smooth 200-character harbor scene.
The thing Grapeshot couldn't do.

## Phase 3 — Survival, crafting, progression (solo or +1-2 devs, ~4-6 months)

The actual game. With architecture proven and bottlenecks understood,
content can land safely.

**Content pipeline prerequisite (lands during Phase 2):** the team
includes devs from a GTA 5 / FiveM RP modding background. Their
content workflow — author in Blender → drop file → small manifest →
hot-reload — sets the bar for the asset onboarding UX. By the time
Phase 3 content scaling starts, the engine needs:

- glTF mesh + KTX2 texture loaders (lift fallen-runes' `gltf_loader.zig` per the reference rules)
- Hot-reload extended to meshes / textures (already established for shaders + YAML)
- Per-content-unit YAML manifests (`data/ships/*.yaml`, `data/props/*.yaml` — one file per unit, no monolithic registries)
- A worked-example onboarding doc — "how to add a new sail texture" — written for someone who's installed Zig once

The shipping model can differ from FiveM's (we likely want pre-baked
deterministic client builds with content versioning, not on-demand
client downloads), but the **authoring** workflow should feel
familiar. See memory `project_asset_pipeline_fivem_team.md` for the
full set of tensions to manage.

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

**End-of-phase:** decision point. If the loop is fun, scale to open
playtest. If not, iterate.

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
| ▢ | Milestone 1.5 (live load) | Phase 1 → 2 | Server tick + replication scales under live ship-sim + gateway |
| ▢ | Milestone 1.6 | Phase 2 → 3 | Renderer holds 60 fps in dense scene |
| ▢ | Closed playtest | Phase 4 | The loop is actually fun |

If any gate fails, **stop and fix before adding content**. This is the
single most important discipline that Atlas lacked.
