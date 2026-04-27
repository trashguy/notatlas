# 07 — Anti-patterns (do NOT replicate)

Atlas-era design choices that the playerbase rejected, with the reason each
one failed. Use as a checklist when scoping any notatlas mechanic — if a
proposal has the same shape as an entry below, it's the wrong choice.

## Don't replicate

### Four-vitamin nutrition system (A/B/C/D)

Atlas tracked four separate food groups (vegetables, meats, fruits, fish/
dairy). Both deficiency and surplus caused debuffs; "equilibrium" buff
required maintaining all four within 20% of each other. Universally voted
the most-hated mechanic. Forced berry grinding and dozens of fish per
day; trivial to cheese; drained at sea or while idle.

**notatlas:** at most one nutrition bar. If nutrition matters at all, it's
a single value, not four.

### Claim-flag land monopolization at launch

Atlas players in week one planted claim flags across virtually every
island. New players had nowhere to build. Single biggest cause of churn.
Took a full server wipe and the v1.5 Colonies rework to fix.

**notatlas:** structural fix from day one — anchorage-bound territory caps,
not unlimited flag radii. Cap structures per anchorage. Settlement-level
claim, not flag-pole spam.

### Unrestricted offline raiding

#1 community complaint throughout Atlas's life. Alpha companies wiped
sleeping players nightly. Took the Empires/Colonies split to address, and
even then poorly.

**notatlas:** hibernation rules at sea; protected raid windows when
anchored at owned anchorage. PvP-first does not mean 24/7 vulnerability.

### 15×15 grid (225 official servers) at launch

Population was 60k-ish at peak; spread thin. Cross-cell handoff bugs ate
ships. Lawless zones became build-spam graveyards. Players couldn't find
each other.

**notatlas:** start with a small grid (5×5 = 25 cells) and scale up only
with proven CCU. Architecture (NATS-based) supports adding cells with no
neighbor coordination, so this is a config decision, not a rebuild.

### Multi-hour empty sailing

Travel was punishment, not adventure. Atlas's sailing took hours with
nothing to do.

**notatlas:** smaller cells, denser content, fewer cells to cross. Real
danger and real encounters fill what would otherwise be empty water.
Sailing exists in service of crafting and combat goals, not as a tax.

### Megacorp-tuned ship/base costs

Galleon material costs were tuned for 50-player guilds. Solo and small
groups locked out of high-tier content.

**notatlas:** tune all costs for a 4-player crew. A 50-player guild doing
the same thing should feel like overkill, not necessity.

### Repeated full wipes without warning

Each Atlas wipe shed another tier of veterans who refused to grind back.
Wipes were emergency response, not scheduled events.

**notatlas:** wipes are scheduled (~10 weeks), telegraphed weeks in
advance, and become marketing events with content drops. Veteran-tier
account flag accelerates early-cycle XP for returning players.

### Asset-flipping ARK without engine divergence

Players noticed Atlas was an ARK fork with the same bugs. Reviewers
called it out immediately. The engine inheritance ran too deep.

**notatlas:** custom engine. The renderer, networking, and physics
architecture are designed for the actual scene shape (large-scale naval
combat + dense harbor raids), not retrofitted from a different game.

### Mode proliferation on a shrinking population

Atlas split players across PvE × PvP × NA × EU × Colonies × Empires.
Each shard hollowed out faster than population could fill it.

**notatlas:** one ruleset at launch. Fork only if CCU justifies, not on
hope.

### Endgame PvE that one-shots progression

Ghost Ships introduced in 2019-2020 destroyed weeks-of-work galleons.
Drove rage quits.

**notatlas:** PvE damage to player ships caps at a percentage of HP per
encounter. Catastrophic loss happens because of *players*, not because of
scripted spawns.

### Discovery Points and Power Stones for max level

Required visiting 200+ specific landmarks and killing scripted island
bosses with full companies, for character power gain. Locked out solo /
small group; "click the right thing on the right island" is thin gameplay.

**notatlas:** mastery-based per-discipline leveling; no global cap; bosses
optional. Fog-of-war map UX kept as cosmetic, not as power gate.

### Surprise launch with no real beta

Atlas's launch day was its first real stress test. It failed publicly.
"40,000 player MMO" was advertised but never tested.

**notatlas:** stress-test gates are baked into the roadmap (see milestone
1.5 and 1.6). Closed playtests before any open exposure.

### Admin Steam accounts without 2FA

A hacker compromised a Grapeshot admin Steam account in Jan 2019, spawned
whales/planes/tanks/PewDiePie creatures across the NA PvP server. Defined
the game's mainstream press image.

**notatlas:** admin auth requires hardware 2FA from day one. Audit log on
all admin actions. No exceptions.

## What players wanted but never got (positive design targets)

The mirror-image of the above — features the community asked for that
Atlas never delivered, which notatlas should aim at:

- Real boarding mechanics with ship-capture, not just sink-and-loot
- Treasure maps with payoff proportional to risk
- Solo-and-small-group viable progression (Pillar 3 addresses this)
- Short-session moment-to-moment loops (the Sea of Thieves comparison)
- A real economy and trade loop that survives population dips
- Stable cross-grid ship transitions (the architectural innovation in
  [02-architecture.md](02-architecture.md) addresses this)
- Communicative dev cadence with a public roadmap
- Anti-cheat and report tooling on day one
