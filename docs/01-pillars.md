# 01 — Design Pillars

The pillars are listed in priority order. When a design choice creates
tension, the higher-numbered pillar is the one that gets compromised. When
a system can't honor a pillar, redesign — don't ship.

## Pillar 1: smooth naval combat at scale (THE selling point)

Atlas died at ~100 players per node during big boat/land raids. This was
a server-tick + replication-bandwidth problem, not a fundamental limit.
notatlas's defining feature is naval combat that stays smooth with hundreds
of players in close engagement.

**Targets:**

- 200 players in a single contiguous engagement (one cell + neighbors)
- 30 ships (mix of sloop / schooner / brigantine / galleon) in active combat
- 1000+ in-flight projectiles peak (mass cannon volleys)
- 60Hz authoritative ship pose, ≤100ms client perceived latency
- No frame stutter, no rubber-banding, no cell-boundary hitches
- Per-client downstream bandwidth ≤1 Mbps under peak load

**Implications propagated through the architecture:**

- Tiered replication (full fidelity nearby, summary at distance) is mandatory
- Deterministic projectile model — don't replicate cannonballs per-tick
- State-change side channel separate from pose firehose
- Aggressive pose compression (~16 B/pose)
- Server-side spatial filtering before fanout, not client-side
- Voice chat off the gameplay path entirely
- Damage events published on change, not state-replicated per tick

**Stress test gate:** before any Phase 3 content work begins, run a synthetic
naval brawl load test at three scales (50 bots + 10 humans, 200 bots + 10
humans, 200 humans). Each scale must hold 60Hz, ≤100ms latency, ≤1 Mbps
client BW, no client stutter. If a tier fails, stop and fix before adding
content.

## Pillar 2: harbor raids that don't tank FPS

Distinct bottleneck from Pillar 1. Same scenario triggers both, but Pillar
1 is server / network and Pillar 2 is client GPU.

**Why it tanked Atlas:**
- 500-2000 player-built structure pieces, each its own draw call
- 10-20 attacking ships × 50-200 components each
- Per-piece shadow draws across cascades, dynamic lights, particle
  emitters, animation ticks
- UE4 fights GPU-driven rendering for composite player-built geometry

**Why notatlas can win here:** a custom Zig + Vulkan renderer designed for
the scene shape from day one — bindless textures, GPU-driven culling,
indirect draws, palette-instanced structures, hierarchical LOD with
auto-merging, single uber-shader for the structure palette. UE4/UE5 fight
this; a purpose-built renderer makes it natural.

**Targets:**
- 60fps on mid-range GPU (RTX 4060 / RX 7600) in a synthetic harbor
- 500 structures + 30 ships + 200 characters + 100 emitters simultaneously
- No subsystem >2 ms in RenderDoc capture

**Stress test gate:** synthetic harbor scene with the above density, before
Phase 3 content work. No gameplay logic, just rendering. If GPU subsystem
budget breaks, fix before content lands.

## Pillar 3: deep crafting with global resource sourcing

Atlas's crafting was the actual content loop — beloved by people who got
into it; the chore-tier survival sim on top is what people hated. With
those stripped, crafting becomes the primary progression motor and intrinsic
endgame.

**Spine to preserve:**
- ~15 resource families, 4-7 sub-types per family
- Sub-type distribution is biome-specific (Ash in temperate, Ironwood in
  tropical, etc.)
- High-tier recipes name specific sub-types — players must travel
- Quality tiers Common → Mythical with stat rolls
- Skill tree gates which recipes can be crafted at all
- Industrial tier for bulk processing

**Refinements over Atlas:**
- Ingredient diversity capped (~6 ingredients max per recipe; Atlas had 8+)
- No vitamin system or other chore-tier survival overlay
- Resource yields reward visiting and leaving, not "chop the same tree for
  an hour"
- Player-driven trade and markets for those who'd rather buy than travel

**The natural endgame:** "my Mythical-tier Galleon has 8 exotic woods,
masterwork cannons, hand-trained crew." Emergent, earned through play, no
scripted-bossfight progression gate required. See [07-anti-patterns.md](07-anti-patterns.md)
for why scripted endgame (Power Stones / Kraken) is cut.

## Pillar 4: competent FPS player combat

User framing: "smooth as we can fps combat for people, but most players are
used to jank." Lower priority — execution, not innovation. Target Rust-
grade feel; don't chase Tarkov or Mordhau.

**Approach:**
- 60Hz authoritative tick for player-on-player engagements
- Lag compensation / rollback for hit registration (capped ~250 ms)
- Client-side prediction for own movement; reconciliation on mismatch
- Hit registration that doesn't lie (geometry-aware)
- Honest ping display
- Reuse the deterministic projectile primitive from cannons for all
  ranged weapons (muskets, blunderbuss, bow, mortar)

**Don't over-invest:**
- No directional-melee with chamber/parry windows
- No Tarkov-grade ballistics for flintlocks
- Hitscan acceptable for muskets/pistols at typical 1-30 m
- Pick one camera mode (1st or 3rd) per weapon class and commit

## Pillar 5: scheduled wipe cycles

10-week wipes, scheduled and telegraphed. Built in from day one. Each cycle
is a content drop + balance reset + architecture stress test.

**What wipes:** structures, ships, character level, skill points, tames,
inventory, claims, treasure progress.

**What persists:** account, cosmetics, achievements, veteran tier (XP
acceleration), unlocked discipline knowledge, trade reputation, friend list
/ company roster.

**Architecture wins:** schema migrations land at wipe boundaries; engine
upgrades shipped during wipe staging; hibernation/raid loss anxiety
bounded by 8-10 week horizon; every wipe is a fresh load test.

See [06-design-caps.md](06-design-caps.md) for cycle structure.

## Pillar 6: mastery-based leveling without scripted gates

Atlas required Discovery Points (visit zones) and Power Stones (kill
scripted island bosses with full crews) to raise character level cap.
Universally hated; locked out solo and small-group play.

**notatlas replacement:**
- Per-discipline mastery, leveled independently from doing the activity
- No global character level wall
- Fog-of-war map UX *kept* (visiting reveals world map) — but as cosmetic
  / lore, not as power gate
- Boss content (Kraken-equivalent, big creatures) becomes optional flavor
  drops — unique cosmetics, blueprint-quality buffs, never required for
  any progression tier

The natural endgame is pillar 3 (crafting), not scripted bosses.
