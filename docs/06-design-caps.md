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
| Players per cell | 200 | `data/cell_caps.yaml` |
| Ship tiers v1 | 3: Sloop, Schooner, Brigantine | `data/ships/*.yaml` |
| Resource families | ~15 (Atlas count) | `data/resources/*.yaml` |
| Sub-types per family | 4-7 | per-family YAML |
| Structures per anchorage | 500 | `data/anchorage_caps.yaml` |
| Recipe ingredient count | ≤6 per recipe | recipe Lua schema |
| Quality tiers | 6: Common, Fine, Journeyman, Masterwork, Legendary, Mythical | `data/quality.yaml` |
| Replication tiers | 4: 0/1/2/3 (always / visual / close-combat / boarded) | code (mechanism) + `data/tier_distances.yaml` (thresholds) |
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

- v1 grid: 3×3 = 9 cells (Phase 2)
- Closed playtest: 5×5 = 25 cells (Phase 4)
- Production initial: 7×7 = 49 cells; scale via NATS-config (no rebuild)
- Long-term ceiling: bounded by NATS throughput, not architecture

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

## Replication tier distance thresholds

First-pass values; tune from milestone-1.5 stress test:

| Tier | Distance |
|---|---|
| 3 (boarded) | aboard same ship |
| 2 (close combat) | <150 m |
| 1 (visual) | <500 m |
| 0 (always) | any |

## Open questions remaining

- Final 5th discipline (Captaineering vs Trade vs neither)
- Tier distance thresholds (need stress test data)
- Per-cycle map seed strategy (regenerate from seed each wipe?
  hand-curated map per cycle? mix?)
- Hibernation raid window schedule (daily 4 hr? weekend? company-set?)
