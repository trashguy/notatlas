# R1 — Atlas Feature Research (2018-2020)

Consolidated feature inventory of the original Atlas, organized by
subsystem. Sources are atlas.fandom.com, atlas.wiki.fextralife.com, Steam
patch notes, and contemporary press coverage. This is reference material
for what the original game shipped — see [01-pillars.md](../01-pillars.md)
for what notatlas adopts vs cuts.

## Survival mechanics

- Stats: Health, Stamina, Oxygen, Food, Water, Weight, Melee Damage,
  Movement Speed, Intelligence, Fortitude, Torpidity (unconscious at 50%)
- **Vitamin system (CUT in notatlas):** 4 separate bars — Vitamin A
  (vegetables), B (meats), C (fruits/berries), D (fish/dairy). Both
  deficiency and surplus caused debuffs; "equilibrium" buff required
  maintaining all four within 20% of each other for 30 minutes
- Hunger / thirst depletion damages HP; cooked food gives more food +
  vitamins than raw
- Temperature: Hypothermia / Hyperthermia tied to biome and clothing;
  Fortitude reduces severity
- Stamina drains for sprint, jump, swim, harvest, melee
- Oxygen drains underwater; Survivalism skills reduce consumption
- Weight encumbrance with strength-tier carry skills

## Character creation, leveling, skills

- Full body slider customization at Freeport spawn (height, build, face,
  skin, age)
- Per-level stat allocation: Health, Stamina, Oxygen, Food, Water, Weight,
  Melee Damage, Fortitude, Intelligence
- XP per skill use, harvest, kill; Skill Points granted per level
- 16 Disciplines (only Survivalism unlocked at start, rest discovered):
  Survivalism, Construction & Mercantilism, Beastmastery, Hand-to-Hand
  Combat, Melee Weaponry, Archery & Throwing Weapons, Firearms, Armory,
  Medicine, Artillery, Seamanship, Captaineering, Cooking & Farming,
  Music & Dance, Piracy, Tarot
- Feats: active / passive abilities tied to skills (Power Hit, Olfactory
  Sense, Bola Throw, Heal Other, Whistle commands, Intimidating Yell)

## Combat

- Melee: fists / brass knuckles, swords, sabers, maces, pikes, sickles,
  shields with block, plus torpor weapons (whip, bola)
- Ranged primitive: bow, crossbow, arrows (simple, fire), spear / javelin
- Firearms (flintlock era): Flintlock Pistol, Blunderbuss, Carbine Rifle,
  Hand Mortar
- Ammo types: ball, grapeshot, liquid fire, explosive
- Artillery: ship cannons, ballistas, catapults, swivel guns, mortars,
  puckle gun, gatling, explosive barrels

## Taming and breeding

- ~21 land tames + 3 aquatic + several mythological (Drake, Fire Elemental,
  Rock Elemental, Leatherwing, Gorgon)
- Knockdown taming: bola + reduce HP <20% then bola (predators); passive
  feeding for small creatures
- Per-creature preferred food (Bear=Honey, Lion=Prime Animal Meat, etc.)
- Taming Pen prevents escape during tame
- Breeding: mate boost radius; non-mammals lay eggs, mammals gestate;
  baby → juvenile (10%) → adolescent (50%) → adult
- Imprinting: one player imprints baby via care actions; up to +30%
  damage / resist when ridden by imprinter
- Stat inheritance: each stat picks higher of two parents probabilistically;
  mutations possible

## Death, respawn, aging

- Drop full inventory at corpse
- Respawn at Freeport (always), Bed (claimed land), Bedroll (one-shot),
  Ship Bed (lawless zones); cooldown timer
- Injured status (HP <30): slow, no jump
- **Aging (CUT in notatlas):** character ages from 20 to 100 over ~3 real-
  time months; aging applies stat drift; Fountain of Youth resets to 20

## PvE creatures and bosses

- Hostile wildlife per biome (Wolf, Lion, Tiger, Bear, Crocodile, Cobra,
  Yeti, Cyclops, Gorgon, Mermaid)
- Soldiers / Army of the Damned: undead pirate NPCs at treasure dig sites
- Aquatic hostiles (Whale, Shark, Manta, Jellyfish, Eel, Squid, Anglerfish)
- **Ship of the Damned:** ghost ship NPCs at sea, multiple tiers
- **Power Stones (CUT as progression gate in notatlas):** 9 stones, one
  per Golden Age island, guarded by Hydra or Dragon; collecting all 9
  unlocked Kraken raid
- **Kraken:** endgame boss at A11 portal-gated cell

## Naval — ship tiers and hulls

- **Raft** (Tiny Shipyard) — single sail, no gunports
- **Rowboat / Dinghy** — oared scout craft
- **Sloop** (Small Shipyard) — starter combat ship; ~2.0 sail-unit cap,
  1-2 crew, single gunport
- **Schooner** (Small Shipyard) — ~28 medium planks, ~5 sail cap
- **Brigantine** (Large Shipyard) — ~40 medium planks, ~10 sail cap
- **Galleon** (Large Shipyard) — 16 sail cap, multiple decks, ~14 large
  gunports per side
- **Ramming Galley** (later patch) — purpose-built ramming hull
- **Submarine** (Update 1.5) — small underwater scout
- **Tramp Freighter** (later) — modular cargo hauler

## Naval — modular components

- Planks (small / medium / large in wood and metal)
- Gunports (replace planks 1:1 in matching size)
- Decks, ceilings, ramps, stairs, railings
- Ship Resources Box (auto-pays crew, supplies repair)
- Cargo Rack (1600 weight, 80% reduction = effective 8000)

## Naval — sails and wind

- 3 types × 3 sizes
- Small = 1.0 unit, Medium = 1.7, Large = 2.7
- Speed Sail (Gaff): speed bonus, best with wind
- Handling Sail (Bermuda): fast turn, tolerates wide angles, best for
  tacking against wind
- Weight Sail: adds carry capacity (Small +250, Medium +750, Large +1000)
- Wind direction changes server-side; sail effectiveness scales with
  alignment

## Naval — combat artillery

- Ship Cannon (Medium): main gunport weapon, ammo types Cannon Ball /
  Spike Shot / Bar Shot / Grape Shot
- Large Cannon: Galleon / Ramming Galley class; loads Large Cannon Ball,
  Spike, Bar, Explosive Barrel
- Swivel Gun: railing-mounted, fires Grape Shot
- Puckle Gun (base only): rapid-fire
- Mortar (base only): high-arc siege
- Ballista: fires bolts and Harpoon (tethers ships)
- Catapult: lobs Explosive Barrels
- Explosive Barrel: heavy structural damage

## Naval — crew and economy

- Hire Crewmembers at Freeport Crew Recruiter for 5 gold
- Wages: ~1 gold per 1.1-4.7 hours per crew, scaled by station,
  accommodations, distance to shore
- Pay via gold in Ship Resources Box; feed via Food Larder
- Crew cap scales with ship size and accommodations

## Naval — leveling

- Choose one per level: Weight, Damage, Resistance, Sturdiness,
  Accommodations, Crew
- Max level 42 base, up to ~52 from shipyard quality

## Building / structures

- Material tiers: Thatch (cheap, fragile), Wood (~10× thatch HP, immune
  to stone tools), Stone (same HP as wood, ~1 dmg from metal tools)
- Components: Foundations, Walls, Ceilings, Roofs, Doorframes, Doors,
  Windowframes, Windows, Pillars, Ramps, Stairs, Beams, Trapdoors, Gates,
  Ladders, Fence Foundations
- Snap-point preview, automatic elevation adjustment, dynamic tile-type
  swap during placement
- Pillars confer support; structures collapse if upstream support
  destroyed
- Plumbing: Water Pipes (Stone & Metal), Faucets, Water Reservoir
- Electrical: Generators, Wires, Lamps

## Crafting stations

- Smithy (metal weapons, tools, ship parts)
- Forge (smelt ore: Cobalt, Copper, Iridium, Iron, Silver, Tin)
- Loom (sails, cloth, ropes)
- Tannery (armor: hide, fur, plate)
- Mortar & Pestle (Gunpowder, Blasting Powder, Preserving Salt, Organic
  Paste)
- Cooking Pot, Grill (food)
- Preserving Bag (~12× spoilage extension)
- Industrial Cooker, Industrial Grinder, Industrial Forge (bulk processing)
- Shipyards: Tiny / Small / Large / Advanced

## Resources (15 families × 4-7 sub-types each)

- Wood: Ash, Cedar, Fir, Ironwood, Oak, Pine, Poplar
- Stone: Coquina, Granite, Limestone, Marble, Pearl, Sandstone, Slate
- Fiber: Bamboo, Cotton, Hemp, Jute, Silk, Straw
- Thatch: Fronds, Reeds, Roots, Rushes, Twigs
- Flint: Agate, Basalt, Chalcedony, Chert, Obsidian, Radiolarite
- Metal: Cobalt, Copper, Iridium, Iron, Silver, Tin
- Gems: Diamond, Emerald, Garnet, Opal, Ruby, Sunstone
- Crystal: Calcite, Herkimer, Quartz, Tellurite
- Coal/Sulfur: Anthracite, Graphite, Lignite, Nitre, Peat, Sulfur
- Oil: Blubber, Crude, Fish, Mineral, Naptha, Olive
- Salt: Flake, Iodine, Kala Namak, Sea
- Sap/Sugar: Gum, Honey, Sugars, Syrup, Sugar Cane, Resin
- Hide / Leather / Pelt / Wool / Hair / Skin
- Keratinoid: Bone, Carapace, Chitin, Scale, Shell, Residue
- Coral: Brain, Fire (rare); Mythos (Power Stone reward)

## Quality tiers

Common (gray) → Fine (green) → Journeyman (blue) → Masterwork (pink) →
Legendary (yellow) → Mythical (cyan), plus Primitive baseline.

Blueprints define a one-shot or n-craft recipe with multiplied material
costs and rolled stat bonuses (Damage, Armor, Durability, Weight, HP for
ship parts).

## Treasure maps

- Bottles spawn on shorelines, glow purple/green/red at night by rarity
- Map shows region grid, treasure chest quality, minimum gold reward
- Travel to grid → beacon (pink shaft of light) → spawns Army of the
  Damned waves → clear → dig with Shovel → chest spawns
- Loot: gold coins, blueprints, resources, occasional skins

## Trade system (added v514.3, 2020)

- Farmhouse: auto-gathers nearby nodes; 30 slots, 8000 weight
- Warehouse: pulls from all Farmhouses within 450 m
- Market: adjacent to Warehouse; lists trade offers consumed by other
  Markets via Trade Routes between Sea Forts
- 20 active offers per Market; up to 30 gold per completed trade

## Company / guild

- 50 player cap per Company
- Up to 5 Alliances per Company
- Tunable rank system (promote / demote / kick)
- Per-rank governance for build / demolish / ride / access permissions
- Crew Log: audit log of structures built / destroyed, joins / leaves,
  kills, tames

## World structure

- 15×15 = 225 cells at launch
- Cell types: Freeport (16 cells, PvE safe, NPC vendors, character
  spawn), Lawless (PvP, no flag claim, structures decay 4 days),
  Claimable (flag-based ownership), Golden Age Ruins (7 cells, Power
  Stone bosses), Kraken's Maw (A11)
- 6 biomes: Polar, Tundra, Temperate, Tropical, Desert, Equatorial

See [research/atlas-server-tech.md](atlas-server-tech.md) for the actual
server architecture.

## What changed across Atlas's lifecycle (high-level)

- Dec 2018: launch, 60k peak CCU
- Jan 2019: hacker compromised admin Steam account; whale/plane spawn
  incident; 5.5h rollback
- April 2019: Mega-Update v1.5 — 40% larger map; Empires (legacy) vs
  Colonies (new) ruleset split; submarines, shipwrecks, deep trenches,
  player shops, cosmetics
- Sept 2019: full wipe + new world map / biomes / 70+ island templates
- Late 2019 / early 2020: Ghost Ships introduced (overtuned, nerfed)
- Feb 2020: devs publicly say "we have problems"; <5k peak CCU
- July 2020: Maelstrom Update — circular map layout, Kraken in center;
  upkeep cuts; ~3k peak CCU
- Aug 2020+: updates dwindled, then stopped; team redirected to ARK
