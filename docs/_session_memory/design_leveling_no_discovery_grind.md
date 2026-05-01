---
name: notatlas leveling/progression — no Atlas-style discovery/Power-Stone grind
description: Atlas's max level required collecting Discovery Points (visit sub-zones across 225 cells) and Power Stones (kill scripted bosses on specific islands with full crews). Universally hated. Replace with mastery-based progression and intrinsic achievement.
type: project
originSessionId: cb0aa047-d395-4803-bc6b-7df96341b031
---
User: "the leveling max system was very dumb in atlas where you needed whole teams to click the things i forgot what they were called on the specific islands."

User is referring to two distinct Atlas systems, both bad:

**1. Discovery Points / Discoveries:**
- Each new sub-zone visited grants permanent +XP-cap and +stat-bonus
- Distributed across 225 cells — required global travel to grind
- "Click landmark, collect dot" content; thin delivery
- Capped your character level if you didn't grind it

**2. Power Stones (9 total):**
- One per Golden Age island, guarded by Hydra or Dragon boss
- Killing boss → 2hr-spoil Artifact Key → Artifact Altar → Power Stone
- All 9 needed to unlock Kraken raid AND further stat caps
- Required organized full-company raids, scheduled across multiple sessions
- Solo/small-group locked out of max progression

**Why both were dumb:**
- Forced specific cooperative scripted content to *progress at all*
- Hard-gated solo and small-group play
- Boss fights were scripted patterns, not emergent
- "Click the right thing on the right island" is thin gameplay
- Created have/have-not divide between players who'd done the raids and those who hadn't

**notatlas replacement model — multi-axis mastery, no scripted gates:**

**Per-character progression:**
- No global character "level" with a cap. Atlas's global level was redundant given Disciplines.
- Discipline mastery levels (4-5 disciplines: Sailing, Combat, Survival, Crafting). Each levels independently from doing the activity. No cap.
- Stat allocation points awarded per discipline level milestone (e.g. every 5 levels in any discipline = 1 point)
- Specialized characters by design — a high-Sailing character is a different player from a high-Crafting character

**No Discovery Points required for progression:**
- "I visited X" remains as an *achievement / lore unlock*, not a power gate
- Players who explore get cosmetics, titles, lore entries — no stat bonus
- Removes the "must travel to 200 specific spots" tedium

**KEEP fog-of-war map discovery (UX layer):**
- Player's world map starts mostly black; fills in as they sail/walk through cells
- Per-character (or per-company?) progressive map reveal — looks great, feels rewarding
- This is the *visual/UX* piece of Atlas's discovery that was actually loved; it's the *power-gate* piece that was hated
- Implementation: client-side bitmap of visited tiles persisted to PG; server validates visit events
- Cycle interaction: fog wipes with each cycle; veteran-tier flag could grant "starts with major coastlines visible" or similar mild perk

**No Power Stones required for max level:**
- Endgame bosses become *optional flavor content* drops — kill the Kraken-equivalent for unique cosmetics, blueprint quality buffs, bragging rights
- Not required for any tier of crafting or character power
- Solo viable, group rewarding, never gating

**The actual progression loop (saved in `pillar_crafting_global_sourcing.md`):**
- Crafting depth + global resource sourcing
- Mythical Galleon with 8 exotic woods, masterwork cannons, hand-trained crew = the natural endgame
- Earned through play, not through scripted boss-clicking

**Wipe-cycle interaction:**
- Each cycle starts fresh. Veterans get a "veteran tier" multiplier on early-cycle XP gain to compress the boring early levels — not a power gap, a *time discount*
- After cycle 3+, a veteran who joins a fresh cycle hits competitive ship-tier in 1-2 weeks instead of 4

**What this saves:**
- ~8 boss fights of scripted content (Hydra/Dragon variants, Kraken)
- Discovery system
- The "you need a full company to progress" social pressure
- A whole class of "we couldn't sync 20 people for the raid this weekend" frustration

**What this gives up:**
- The dramatic "we killed the Kraken!" milestone moment. But notatlas can re-create that *via emergent play* — the first company to crew a fully Mythical-tier galleon is a similar bragging right, earned by the community rather than scripted.
