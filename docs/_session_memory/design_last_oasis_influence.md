---
name: Last Oasis structural design influence
description: notatlas adopts Last Oasis-style sector/rotation mechanics rather than Atlas's persistent 15x15 grid. This is a structural design pillar, not a cosmetic borrow.
type: project
originSessionId: cb0aa047-d395-4803-bc6b-7df96341b031
---
The user explicitly cited Last Oasis-style protection mechanics and "maps" (plural, distinct) as the model for notatlas's PvP/world structure.

**What Last Oasis did that maps to notatlas:**
- World is divided into discrete sectors (separate maps), not a stitched continuous world. Players travel between sectors via a hub/portal-equivalent.
- Sectors rotate: maps come online and offline on a schedule. The world is *transient* — no permanent claim of land.
- Population caps per sector keep encounters dense.
- Player's home is mobile (walker → ship). Sink the ship, lose progress (with recovery/insurance lanes).
- Hibernation / scheduled vulnerability windows replace 24/7 raid exposure.
- Tiered sectors gate progression (Tier 1 calm zones → Tier 7 dangerous zones).

**Why this matters for notatlas (resolves Atlas anti-patterns at the structural level):**
- No flag-spam land grab — there is no permanent land claim to spam.
- No multi-hour empty sailing — sectors are bounded, travel between sectors is a portal/hub jump, not a real-time crossing of 14 cells.
- No offline raid trauma — ship is hibernated when crew is logged out (with rules; not a permanent invulnerability).
- No 225-server architecture problem — each sector is one server process; cross-sector state goes through a lightweight matchmaker/portal layer, not seamless actor handoff.

**How to apply:**
- When designing world systems, default to "sector with caps + rotation" not "persistent grid."
- When thinking about PvP balance, default to "scheduled windows / hibernation" not "always-on PvP."
- Atlas terms still apply for *content* (ships, cannons, treasure maps, Power-Stone-equivalents, Kraken-equivalents) but the *frame* around them is Last Oasis, not Atlas.
- Tiered sectors > biome variety — tier is the progression axis, biome is flavor.
