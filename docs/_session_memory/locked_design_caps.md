---
name: notatlas locked design caps (v0)
description: Ratified design caps as of 2026-04-27. First-pass numbers; will adjust from playtest data. Data-driven, not code-baked.
type: project
originSessionId: cb0aa047-d395-4803-bc6b-7df96341b031
---
Ratified by user 2026-04-27. All values are *initial* targets — designed to be adjusted from real-world data per the data-driven principle (`principle_data_driven.md`).

| Cap | v0 value | Where it lives |
|---|---|---|
| Wipe cadence | 10 weeks | `data/cycle.toml` |
| Disciplines | 4-5: Sailing, Combat, Survival, Crafting, ?Captaineering | `data/disciplines/*.toml` |
| Players per cell | 200 | `data/cell_caps.toml` |
| Ship tiers v1 | 3: Sloop, Schooner, Brigantine | `data/ships/*.toml` |
| Resource families | ~15 (Atlas count) | `data/resources/*.toml` |
| Sub-types per family | 4-7 | per-family TOML |
| Structures per anchorage | 500 | `data/anchorage_caps.toml` |
| Recipe ingredient count | ≤6 per recipe | recipe Lua schema |
| Quality tiers | 6: Common, Fine, Journeyman, Masterwork, Legendary, Mythical | `data/quality.toml` |
| Replication tiers | 4: 0/1/2/3 (always/visual/close-combat/boarded) | code (mechanism) + `data/tier_distances.toml` (thresholds) |
| Dynamic light cap (client) | 32 | engine config |
| Particle cap (client) | 100k global | engine config |
| Discipline list (open) | TBD final 5th — Captaineering vs Trade | open question |
| Galleon (deferred) | post-v1 | — |

**Adjustment policy:** these change by editing data files, not by patching binaries. Wipe boundaries are natural opportunities to ship significant balance changes. Mid-cycle changes only for emergency fixes.

**Things still open after this batch:**
- Final 5th discipline (Captaineering vs Trade vs neither)
- Tier distance thresholds (need stress test data)
- Per-cycle map seed strategy
