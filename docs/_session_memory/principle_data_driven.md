---
name: notatlas data-driven principle
description: Engineering directive — game content (resources, recipes, ships, disciplines, balance) lives in data files, not code. Hot-reloadable in dev, versioned, per-cycle adjustable in prod.
type: feedback
originSessionId: cb0aa047-d395-4803-bc6b-7df96341b031
---
User: "we should use a data drive approach so we can always adjust later."

**Rule:** Treat anything that's content, balance, or configuration as data, not code. Code defines *systems*; data defines *content tuned by those systems*.

**Why:** notatlas wipes every 10 weeks. Each cycle is an opportunity to retune balance. Compile-and-redeploy-the-server every time we want to nerf a sail coefficient is unworkable. Plus playtesting needs designer iteration speed without engineer-in-the-loop.

**How to apply — what's data:**
- Item definitions (id, type, sub-type, weight, stack size, quality multipliers)
- Recipe definitions (ingredients, station, time, output, skill gate) — likely Lua, leveraging fallen-runes' comptime Lua bindings
- Ship hull definitions (plank layout, cannon mount points, sail attach points, mass distribution)
- Resource sub-type → biome distribution tables
- Discipline tree shape (nodes, prerequisites, costs, granted recipes)
- Stat curves per quality tier (Common→Mythical multipliers)
- NPC crew wage formulas, food consumption, cap by ship size
- Wave system parameters (Gerstner amplitudes, frequencies, directions)
- Wind field parameters per region (mean direction, gust frequency)
- Cell type → biome → spawn table mappings
- Damage/HP values for structures, planks, sails, cannons, characters
- Decay timers, hibernation windows, raid window schedules
- Wipe cycle timing, veteran-tier curves
- Replication tier distance thresholds (Tier 0/1/2/3)

**What stays in code (not data):**
- NATS subject scheme (it's structural API)
- Persistence schema (PG tables, JSONB shapes)
- Engine subsystems (renderer, physics, networking)
- Service decomposition (gateway, ship-sim, cell-mgr, env, persistence-writer)
- Tier-replication mechanism itself (the *system* — only thresholds are data)
- Lua API surface (the system; recipes calling into it are data)

**Format choices (revised 2026-04-27):**
- YAML for static data tables (item lists, biome tables, stat curves, ship hulls). Parser: `zig-yaml` (kubkon), YAML 1.2 schema only. See `feedback_yaml_over_toml.md` for the decision and safety practice.
- Lua for anything with logic (recipes with conditions, stat-roll formulas, AI behavior trees)
- JSON only when interfacing with external tools (e.g. ServerGridEditor-style cell layout)
- TOML rejected in favor of YAML

**Hot reload during dev:**
- File watcher reloads data tables on save
- Schema validation on load — comptime where possible (Zig structs match YAML keys)
- Versioned schemas so old saves don't break across data shape changes
- Failed validation = log + keep running with previous data, don't crash

**Deployment in prod:**
- Each wipe cycle = potential data version bump
- Data files in git, deployed alongside binaries
- Live tuning during cycle = ops procedure, not engineer-in-the-loop

**Pattern reference:** fallen-runes already does some of this with `loot_defs.zig` ("data-driven loot tables") and Lua scripting. Inherit that style; extend to all content.
