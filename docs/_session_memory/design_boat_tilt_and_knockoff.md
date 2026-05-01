---
name: boat tilt cap + player knock-off threshold
description: Future tuning — gameplay-friendly cap on ship pitch/roll, with explicit threshold above which players get knocked off attached state. Prevents capsizing-as-default while preserving "hold on for storm" gameplay.
type: project
originSessionId: 90d80cdb-1915-424b-a897-3df0344d4ed7
---
At some point we'll need to **cap ship pitch/roll** (a "righting moment"
strong enough that the storm preset doesn't fully flip the deck under
normal play) — pure physics-only buoyancy lets the box capsize, which
breaks naval combat as a gameplay loop.

But there must also be a **knock-off threshold** — extreme storms,
ramming impacts, cannon hits, or large boat-on-boat collisions should
have a chance to break the SoT-style attachment and dump players into
the water. Without that, the architecture feels too "glued."

**Why:** noted by user during M5.5 sandbox testing once the SoT
attachment was clearly working. The deck rolling all the way past
vertical and players still glued to it looked correct mathematically
but felt wrong.

**How to apply:**
- Phase 1 / ship-sim service: add a `righting_torque_factor` to hull
  YAML; clamps roll moment past some angle. Per-ship-tier tunable.
- Phase 1 / collisions: track impact magnitude per ship; trigger a
  `playerKnockedOff(player_id)` event above some threshold. The event
  forces `disembark(ship_pose)` server-side and routes the player into
  a swim/free-agent state.
- Both live in data files (per the data-driven principle), not code,
  so they're season-tunable.
- Don't conflate with hibernation rules — hibernation is about
  unattended-ship raid windows; this is about active-combat physics.
