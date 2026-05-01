---
name: notatlas pillar — deep crafting with global resource sourcing
description: Atlas-style crafting depth where high-tier recipes require sub-typed resources from multiple biomes/cells across the world. The actual progression loop. Quoted: "an awesome crafting system like atlas was where you need to get resources from other parts of the world."
type: project
originSessionId: cb0aa047-d395-4803-bc6b-7df96341b031
---
User explicitly cited Atlas's crafting depth as something to preserve and amplify.

**Why this matters:** Atlas's crafting was actually beloved by people who engaged with it; the complaints were chore-tier survival systems (vitamins, hunger drag) on top of it. With those stripped, the crafting loop becomes the primary content loop — and it's intrinsically motivating without scripted bossfight progression.

**Atlas's crafting design (preserve the spine):**
- ~15 resource families: Wood, Stone, Fiber, Thatch, Flint, Metal, Gems, Crystal, Coal/Sulfur, Oil, Salt, Sap/Sugar, Hide, Keratinoid, Coral
- Each family has 4-7 sub-types: Wood = Ash, Cedar, Fir, Ironwood, Oak, Pine, Poplar
- Sub-type distribution is biome-specific: Ash in temperate, Ironwood in tropical, etc.
- High-tier recipes name specific sub-types (a Mythical Galleon plank requires Strongwood + Darkwood + Wetwood — multiple biomes)
- Quality tiers: Primitive → Common → Fine → Journeyman → Masterwork → Legendary → Mythical
- Each quality tier rolls stat ranges (damage, durability, weight, HP)
- Skill tree gates which recipes the player can craft at all
- Industrial tier processing for bulk (Industrial Forge, Cooker, Grinder)

**This means players must travel.** Travel was tedious in Atlas because sailing was empty. With our naval-combat-at-scale architecture making sailing engaging, **traveling for resources becomes a feature, not a chore.**

**What to refine vs Atlas:**
- Cap recipe ingredient diversity — Atlas's worst recipes needed 8 sub-types from 6 biomes. Tune top-tier ships to need 3-4 sub-types, not 8.
- Don't stack chore-tier survival on top (no vitamins, simple hunger).
- Yields per resource node should reward visiting and leaving, not "chop the same tree for an hour."
- Build a meaningful trade/market loop (player markets, NPC exchanges) for players who'd rather buy than travel.

**The crafting loop IS the world progression:**
- No invented "Power Stones → Kraken" endgame is required. The natural endgame is *"my Mythical Galleon has 8 exotic woods, my crew is imprinted, my company holds 3 anchorages."* That's intrinsically motivating.
- Optional bossfight content can be added later as flavor, not required for progression.

**Technical implications:**
- **Item identity encodes (type, sub-type, quality, stat-roll, blueprint-flag).** Inventory storage is heavier than vanilla MMO (each "wood" is potentially distinct). Use tagged unions or a flat schema with sub-type and quality columns.
- **Recipe definitions in data, not code.** Lua scripting (fallen-runes already has comptime Lua bindings) is the right hammer for recipe declaration — designers can iterate without engine recompiles.
- **World resource distribution** — server-authoritative spawn tables per biome/cell, persistent in PG, respawn timers per node.
- **Crafting station UI** — large surface area: many recipes, search, filter, queue. Probably the heaviest UI work in the project.
- **Persistence cost** — players' inventories can have hundreds of sub-typed item rows. JSONB inventory blobs vs proper relational schema is a real trade. Probably JSONB for player inventories (shape-flexible) + relational for trade-able items in markets (queryable).
- **Replication cost** — inventories are event-sourced (item added/removed/used events), already covered by the change-stream pattern.

**Design caps to set early:**
- Resource families: 12-15 (Atlas's count, don't expand)
- Sub-types per family: 4-6 (Atlas's count)
- Recipe ingredient count cap: 6 ingredients max per recipe
- Quality tiers: 6 (drop "Primitive" as redundant with Common)
- Stat rolls per quality tier: well-defined ranges, not unbounded

**Memory anchor:** when user says "crafting" they mean Atlas-grade depth (sub-types, biome sourcing, quality rolls), not Sea-of-Thieves-grade ("here's a sword"). Lean into the depth.
