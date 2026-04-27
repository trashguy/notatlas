# 05 — Data Model and Data-Driven Principle

## The principle

Game content, balance, and configuration live in **data files**, not in
code. Code defines *systems*; data defines *content tuned by those
systems*.

**Why:** notatlas wipes every ~10 weeks. Each wipe is an opportunity to
retune balance. Compile-and-redeploy-the-server every time we want to
nerf a sail coefficient is unworkable. Designer iteration speed matters
more than engineer throughput.

## What's data, what's code

### Data (YAML or Lua)

- Item definitions (id, type, sub-type, weight, stack size, quality
  multipliers)
- Recipe definitions (ingredients, station, time, output, skill gate)
- Ship hull definitions (plank layout, cannon mount points, sail attach
  points, mass distribution)
- Resource sub-type → biome distribution tables
- Discipline tree shape (nodes, prerequisites, costs, granted recipes)
- Stat curves per quality tier (Common → Mythical multipliers)
- NPC crew wage formulas, food consumption, cap by ship size
- Wave system parameters (Gerstner amplitudes, frequencies, directions)
- Wind field parameters per region (mean direction, gust frequency)
- Cell type → biome → spawn table mappings
- Damage / HP values for structures, planks, sails, cannons, characters
- Decay timers, hibernation windows, raid window schedules
- Wipe cycle timing, veteran-tier curves
- Replication tier distance thresholds
- Loot tables per dig site / map quality

### Code (Zig)

- NATS subject scheme — structural API, not data
- Persistence schema — PG tables, JSONB shapes
- Engine subsystems — renderer, physics, networking, replication
- Service decomposition — gateway, ship-sim, cell-mgr, env, etc.
- Tier-replication mechanism (only thresholds are data)
- Lua API surface — system; recipes calling into it are data

## File format choices

| Format | When to use | Why |
|---|---|---|
| **YAML** | Static data tables | Chosen 2026-04-27. Nested structure (ship hulls, recipes, biomes) reads better than TOML; native multi-line strings for inline Lua snippets |
| **Lua** | Anything with logic | Recipe conditions, stat-roll formulas, AI behavior trees |
| **JSON** | External tool interop only | e.g. ServerGridEditor-style cell layout |
| **TOML** | Not used | Considered and rejected in favor of YAML |

**YAML safety practice (mandatory for this project):**
- Parser must be YAML 1.2 schema only (no `yes/no→bool`, no octal `011`, etc.). `zig-yaml` (kubkon) is the chosen parser; it follows 1.2.
- Quote any string value that *looks* numeric, boolean, or null-shaped (`"north"` is fine; `dir: no` is not — write `dir: "no"`).
- Schema validation on load via Zig struct reflection. Type mismatch = hard error, not silent coercion.
- See engine subsystem M1b (wave-query loader) for the reference loader pattern.

## Directory structure

```
data/
  cycle.yaml                       # wipe cadence, veteran tier curves
  cell_caps.yaml                   # players-per-cell, structure caps
  anchorage_caps.yaml
  tier_distances.yaml              # replication tier distance thresholds
  quality.yaml                     # quality tier multipliers
  ocean.yaml                       # wave system root config
  wind.yaml                        # wind field root config

  biomes/
    tropical.yaml
    temperate.yaml
    polar.yaml
    ...

  resources/
    wood.yaml                      # 7 sub-types: ash, cedar, fir, etc.
    stone.yaml                     # 7 sub-types
    fiber.yaml                     # 6 sub-types
    metal.yaml                     # 6 sub-types
    ...                            # ~15 family files

  ships/
    sloop.yaml                     # hull layout, cannon mounts, mass
    schooner.yaml
    brigantine.yaml

  ammo/
    round_shot.yaml
    chain_shot.yaml
    grape_shot.yaml
    ...

  recipes/
    common.lua                     # primitive recipes
    smithy.lua                     # metalwork recipes
    shipyard.lua                   # ship part recipes
    ...

  disciplines/
    sailing.yaml
    combat.yaml
    survival.yaml
    crafting.yaml
    captaineering.yaml             # if final 5th discipline

  waves/
    calm.yaml                      # Gerstner config
    choppy.yaml
    storm.yaml
```

## Hot reload during dev

- File watcher reloads data tables on save
- Schema validation on load — comptime where possible (Zig structs match
  YAML keys via reflection)
- Versioned schemas so old saves don't break across data shape changes
- Failed validation = log + keep running with previous data; don't crash
- Designer can tweak `data/ships/sloop.yaml`, save, and see the change in
  the running sandbox without restart

## Deployment in prod

- Each wipe cycle = potential data version bump
- Data files in git, deployed alongside binaries
- Live tuning during cycle = ops procedure, requires confirmation, never
  silent
- Major balance changes deploy at wipe boundaries, not mid-cycle

## Database storage shape (matches architecture decision 5)

| State | Storage | Schema |
|---|---|---|
| Player inventory | JSONB blob per player row | `players(id, inventory_json, ...)` |
| Market items | Relational, queryable | `market_items(id, owner, type, sub_type, quality, stats, price, ...)` |
| Structures | Relational | `structures(id, anchorage_id, type, transform, hp, ...)` |
| Anchorage claims | Relational | `claims(anchorage_id, company_id, claimed_at, ...)` |
| Account / cosmetics | Relational, persists across wipes | `accounts(id, ...)`, `account_cosmetics(...)` |
| Discipline progress | Relational, character scope | `character_disciplines(character_id, discipline, level, xp)` |
| Fog-of-war | JSONB blob per character | `characters(id, fog_json, ...)` |
| Damage event log | JetStream KV with TTL → wipe | (not in PG) |
| Pose / sim state | Never persisted | (not in PG) |

## Pattern reference

`fallen-runes` already does some of this with `loot_defs.zig` (data-driven
loot tables) and Lua scripting. notatlas inherits that style and extends
it to all content.
