# 06 — Design Caps (v0)

First-pass numbers ratified 2026-04-27. All values are designed to be
adjusted from real-world data per the data-driven principle ([05-data-model.md](05-data-model.md)).

These are *initial* targets, not final balance. Adjustment policy:
mid-cycle changes only for emergency fixes; significant changes ship at
wipe boundaries.

## Top-level caps

| Cap | v0 value | Lives in |
|---|---|---|
| Wipe cadence | 10 weeks | `data/cycle.yaml` |
| Disciplines | 4-5: Sailing, Combat, Survival, Crafting, ?Captaineering | `data/disciplines/*.yaml` |
| Players per cell (soft target) | 200 — degrade gracefully past, see ["Cell / world structure"](#cell--world-structure) below | `data/cell_caps.yaml` |
| Cell side length | 2–4 km production target (Fanout default 4 km), pinned per ["Cell / world structure"](#cell--world-structure) | `data/cell_caps.yaml` |
| Ship tiers v1 | 3: Sloop, Schooner, Brigantine | `data/ships/*.yaml` |
| Resource families | ~15 (Atlas count) | `data/resources/*.yaml` |
| Sub-types per family | 4-7 | per-family YAML |
| Structures per anchorage | 500 | `data/anchorage_caps.yaml` |
| Recipe ingredient count | ≤6 per recipe | recipe Lua schema |
| Quality tiers | 6: Common, Fine, Journeyman, Masterwork, Legendary, Mythical | `data/quality.yaml` |
| Replication tiers | 5: 0 always / 0.5 fleet_aggregate / 1 visual / 2 close_combat / 3 boarded | code (mechanism) + `data/tier_distances.yaml` (thresholds + per-tier rates) |
| Dynamic light cap (client) | 32 | engine config |
| Particle cap (client) | 100 k global | engine config |

## Wipe cycle structure

10-week cycles, scheduled and telegraphed. Built in from day one.

| Week | Phase |
|---|---|
| 0 | Wipe + new map seed + content drop + balance changes |
| 1-2 | Land rush, T1 sectors, early ships |
| 3-6 | Mid-game; harbor raids start; T2/T3 unlocks |
| 7-9 | Endgame; Mythical-tier crafting; large wars |
| 10 | Final-week countdown; "last stand" events; wipe |

**What wipes:** structures, ships, character level, skill points, tames,
inventory, claims, treasure progress.

**What persists across wipes (account-bound):**
- Account, cosmetics, achievements, badges
- Veteran tier (XP acceleration on early-cycle leveling)
- Unlocked discipline knowledge ("you know HOW to craft")
- Trade reputation (subtle effect on NPC prices)
- Friend list / company roster (re-form in new cycle)

## Discipline list (open question)

4 disciplines confirmed:

1. **Sailing** — ship operation, navigation, sail trim, captaining
2. **Combat** — melee, firearms, hand-to-hand, FPS combat skills
3. **Survival** — gathering, taming (later), basic crafting, exploration
4. **Crafting** — recipes, station ops, quality rolls, blueprints

5th discipline is open: **Captaineering** (NPC crew management, ship
maintenance buffs, fleet command) vs **Trade** (markets, contracts,
wages economy) vs neither (4-discipline launch).

Recommendation: Captaineering, since fleet ops is core to the pillar 1
fantasy. Trade systems can be a Phase 5+ addition.

## Ship tier costs (rough order-of-magnitude)

| Tier | Ship | Build time (4-player crew) | Crew cap |
|---|---|---|---|
| 1 | Sloop | ~1 evening | 4 |
| 2 | Schooner | ~weekend | 8 |
| 3 | Brigantine | ~1 week | 16 |
| (deferred) | Galleon | ~2-3 weeks | 32 |

All tuned for a 4-player crew, not a 50-player guild. Larger groups
should feel like overkill for tier 1-2, useful for tier 3.

## Cell / world structure

### Grid sizing

- v1 grid: 3×3 = 9 cells (Phase 2)
- Closed playtest: 5×5 = 25 cells (Phase 4)
- Production initial: 7×7 = 49 cells; scale via NATS-config (no rebuild)
- Long-term ceiling: bounded by NATS throughput, not architecture

### Cell side length

| Use | Side length | Rationale |
|---|---|---|
| Phase 1 fanout default | 4 km | Matches `Fanout.ClusterConfig.cell_size_m` default; comfortable for empty-ocean dev |
| Production target | 2–4 km | Brings closer-gameplay encounters into the same cell more often (less cross-cell relay traffic during a sloop chase); 2 km is the floor where storm coverage / sailing-time-per-cell still feels open |
| Lower bound | ~1 km | Below this, structure caps overwhelm cell-mgr's per-cell entity table at hot anchorages |

The `cell_size_m` field in `data/cell_caps.yaml` (when it lands) is the authoritative knob. The Phase 1 cell-mgr default is the conservative empty-ocean number; production should pin somewhere in 2–4 km after the milestone-1.5 stress gate measures the cross-cell relay cost at boundary speeds.

### 200 players/cell is a soft target

200 is the design point at which fanout / tier-replication / NATS budget all comfortably hold. It is **not a hard cap**:

- Going *above* 200 should degrade gracefully — added latency / tighter tier banding / dropped fast-lane forwards — never refuse entry. Hardcore PvP players tolerate some lag during the headline fight; a hard cap that turns players away is worse UX than a degraded fight. Atlas's failure mode was "~100/node falling over"; ours should be "200 smooth, 300 degraded but playable, no cliff."
- Going *systematically above* — i.e. ports / harbor anchorages where dense population is the steady-state — uses **sub-cell partitioning** (docs/08 §2.4a), not population caps. The architectural lever is multiplying cell-mgr workers per cell, not turning players away.

See memory `design_soft_caps_subcell.md` for the full framing and how it shapes BW measurement gates.

### Entity inventory at peak

The "200/cell" number is **players per cell**, NOT fanout entity count. Most players are aboard ships (tier-3 boarded, ride on the ship's tier-3 stream); free-agent players have their own state subject. The fanout-entity count at peak is therefore much lower:

| Source | Count | Notes |
|---|---:|---|
| Ships | ~30 | All ship tiers; covers a large naval fight |
| Free-agent players | ~30 | Swimming, falling, on-deck-but-not-aboard transitions |
| **Fanout entities at peak fight** | **~60** | This is the number cell-mgr's filter walks per fanout tick |
| Players (all states, mostly aboard ships) | up to 200 | Soft target per above |
| Plank HP / sail trim / cannon state | embedded | Fields ON the ship entity (M6.2 `replicated(T, tier)` wrapper), not separate entities |
| Cannonballs in flight | 0 | Not replicated; deterministic projectile (M8) — 1 fire-event broadcast per shot, zero per-tick cost |

This matters for the M6.4 / M6.5 BW gates: scenario sizing should treat ~60 fanout entities as "hot fight density," not 200. Plank damage / cannon / sail fields ride along on each ship's per-tier stream — they don't multiply the fanout-entity count.

## Anchorage caps

- 500 structure pieces per anchorage (static-bake LOD merge target)
- 20 stationed NPC crew per anchorage
- 200 concurrent attackers per anchorage instance (matchmade entry,
  queue beyond)

These caps exist so 200v200 stays at 60 fps instead of becoming
1000v1000 at 12 fps. Caps are floors against degradation, not ceilings
on player ambition.

## Resource family count

15 families (matching Atlas):

Wood, Stone, Fiber, Thatch, Flint, Metal, Gems, Crystal, Coal/Sulfur,
Oil, Salt, Sap/Sugar, Hide, Keratinoid, Coral.

Each with 4-7 sub-types defined per-family in YAML. Sub-type → biome
distribution defined in `data/biomes/<biome>.yaml`.

## Replication tier distance thresholds + producer rates

First-pass values; tune from milestone-1.5 stress test. All values
live in `data/tier_distances.yaml` (loaded via
`yaml_loader.loadTierThresholdsFromFile`).

| Tier | Distance | Producer rate |
|---|---|---|
| 0 always | any | 30 Hz |
| 0.5 fleet_aggregate | <2000 m (clustered, per docs/08 §3.2a) | 5 Hz, per-cluster |
| 1 visual | <500 m | 60 Hz |
| 2 close_combat | <150 m | on-change |
| 3 boarded | aboard same ship | on-change |

Consumer-side fast-lane window is fixed at 60 Hz (matches the highest producer rate). Producers MUST honour these rates — at 60 Hz the harness mimics ship-sim correctly; the `--rate` override warns when used, since exceeding tier-1 spec is what created the 134 % BW pressure point measured pre-batching.

## Open questions remaining

- Final 5th discipline (Captaineering vs Trade vs neither)
- Tier distance thresholds (need stress test data)
- Per-cycle map seed strategy (regenerate from seed each wipe?
  hand-curated map per cycle? mix?)
- Hibernation raid window schedule (daily 4 hr? weekend? company-set?)
