---
name: notatlas wipe cycle design
description: Scheduled seasonal wipes (Rust-style but longer cadence). Built into design from day one — not a panic mechanism like Atlas's emergency wipes.
type: project
originSessionId: cb0aa047-d395-4803-bc6b-7df96341b031
---
User: "we will need a wipe cycle like rust, but maybe longer."

**Why this is correct:** Atlas's wipes were unscheduled emergencies that bled veterans every time. Rust's wipes are predictable, telegraphed, and a player feature — fresh start, level playing field, balance reset window, content drop opportunity.

**Cadence target:** "Longer than monthly" → likely **8-12 weeks** per wipe cycle. Tradeoffs:
- 4 weeks (Rust): too short for Atlas-scale ships + bases (galleon takes days, anchorage takes weeks)
- 8 weeks: long enough to build a full fleet + claim, short enough to refresh meta
- 12 weeks: comfortable long-term progression, may stale toward end
- 6 months+: veterans dominate, new-player onboarding gap widens

Recommend launching at 10 weeks; tune from playtest data.

**What wipes (resets every cycle):**
- World structures (anchorages, harbors, all player builds)
- Ship fleet (all ships destroyed; players keep blueprints learned, not hulls)
- Character level + skill points + tamed creatures
- Inventory (carried items, storage contents)
- Company territory claims
- Sea Forts ownership
- Treasure-map progress

**What persists across wipes (account-bound):**
- Account + login + cosmetics + skins
- Achievements / badges / "I survived season 3" tags
- Veteran tier (see leveling memo): each completed cycle accelerates future leveling
- Unlocked discipline knowledge (you know HOW to craft, even if you don't yet have the skill points this cycle)
- Trade/market reputation (subtle effect on NPC prices)
- Friendlist / company roster (re-form in new cycle)

**Cycle structure:**
- Week 0: Wipe + new map seed + content drop + balance changes announced
- Weeks 1-2: Land rush, early ship building, T1 sectors active
- Weeks 3-6: Mid-game, fleets form, harbor raids begin, T2/T3 sectors unlock
- Weeks 7-9: Endgame, mythical-tier crafting, large-scale wars
- Week 10: Final week countdown, "last stand" events; wipe at end

**Architectural advantages:**
- Database migrations land at wipe boundaries — never need live schema migrations
- Engine upgrades / patches deployed at wipe — test for 2 weeks on staging during prior cycle
- Telemetry / balance data captured per cycle = clean A/B comparison
- Hibernation/raid-loss anxiety bounded by cycle horizon (8 weeks of risk, not "forever")
- Stress test cadence — every wipe is a fresh load test of the architecture

**Servers / shards:**
- Multiple cycles can run staggered (NA cycle + EU cycle + Oceania cycle, offset by 3 weeks each)
- "Long" cycle servers (20 weeks) for casual community alongside main 10-week cycle
- "Speedrun" 2-week servers for hardcore (later, post-launch)
- Single global PvE server (no wipes? or wipe with rollover?) — TBD; PvE is secondary anyway

**Live ops cadence:**
- 2 weeks before wipe: announce cycle theme, balance changes, content drop
- 1 week before: mid-cycle players know "use it or lose it"
- Wipe day = launch day, fresh marketing push, streamers re-engage
- Each cycle's wipe is a marketing event, not a maintenance hassle
