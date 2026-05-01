---
name: atlas anti-patterns to avoid in notatlas
description: Specific design choices from Atlas (2018-2020) that the playerbase consistently rejected. Use as a "do not replicate" checklist when scoping notatlas mechanics.
type: project
originSessionId: cb0aa047-d395-4803-bc6b-7df96341b031
---
When designing or scoping mechanics for notatlas, treat the following as anti-patterns from the original Atlas. Each is rooted in a specific failure during the 2018-2020 lifecycle.

**Don't replicate:**
1. **4-vitamin nutrition system (A/B/C/D)** — universally hated; forces berry-grinding chores. If nutrition matters at all, use a single bar or 2 categories max.
2. **Claim-flag spam land grab** — week-1 players locked the entire map. Replace with island-level settlement model from the start (Atlas only got there in v1.5 after a wipe).
3. **Unrestricted offline raiding** — #1 community complaint. Ship and base offline protection windows must be a launch feature, not a patch.
4. **15x15 = 225 cell official world** — too big for population; transition bugs ate ships. Start with a smaller grid (e.g. 5x5 = 25), scale only with proven CCU.
5. **Multi-hour empty sailing** — travel time was punishment. Either compress travel scale, add fast-travel between owned ports, or fill open-water with set-piece encounters.
6. **Megacorp-tuned ship/base costs** — galleons designed for 50-player guilds locked out solo/small groups. Tune for 4-friend cells.
7. **Repeated full wipes** — every wipe shed veterans. Plan persistence carefully; wipes only as last resort.
8. **Asset-flipping ARK without engine divergence** — players noticed the same bugs. If reusing an existing engine, diverge gameplay code aggressively.
9. **Mode proliferation (Empires/Colonies/PvE/PvP × NA/EU)** — split a shrinking pop. One ruleset at launch, fork only when CCU justifies it.
10. **Endgame PvE that one-shots progression** — Ghost Ships destroying weeks-of-work galleons drove rage-quits. Cap PvE damage to ship HP %.
11. **Grapeshot's "surprise launch" with no real beta** — Day-1 was the stress test. Public playtests / staged rollout required.
12. **Admin accounts without 2FA** — caused the whale-spawn hacker incident that defined the game's press image.

**What players wanted but never got (positive design targets):**
- Real boarding mechanics with ship-capture, not just sink-and-loot
- Treasure maps with payoff proportional to risk
- Solo-and-small-group viable progression
- Short-session moment-to-moment loops (the Sea of Thieves comparison kept coming up)
- A real economy/trade loop that survives population dips
- Stable cross-grid ship transitions
- Communicative dev cadence with a public roadmap
