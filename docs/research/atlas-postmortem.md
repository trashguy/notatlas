# R2 — Atlas Postmortem (Why It Failed)

Reception, controversies, and lessons learned from Atlas (Dec 2018 — mid
2020). Used to inform [07-anti-patterns.md](../07-anti-patterns.md).

## Population trajectory

- Peak: ~58,939 CCU on Steam, Dec 29 2018
- Avg Dec 2018: ~39,000 CCU
- Mid 2019: ~10,000 CCU
- June 2020: ~3,000 CCU
- Late 2020 onward: <1,000 CCU
- Steam reviews: 32-46% positive across the lifecycle

## Chronological summary of major patches and pivots

**Dec 6, 2018** — Surprise reveal at The Game Awards as "40,000-player
MMO." Originally scheduled Dec 13, delayed to Dec 22.

**Dec 22, 2018** — Early Access launch on Steam / Xbox. Servers down for
hours. Players couldn't log in. Built on ARK's UE4 fork — players
recognized it as an "ARK reskin" immediately.

**Early Jan 2019** — Land grab catastrophe: by week one, virtually every
island claimed. New players had nowhere to build. Patches add Claim Flag
settings and PvE contest timers.

**Mid-Jan 2019** — Hacker compromised a Grapeshot admin Steam account.
Spawned whales, planes, tanks, and "Subscribe to PewDiePie" creatures
across the NA PvP server. Days later a second exploit forced 5.5-hour
rollback. Group "Black Butterfly" widely blamed. Defined the game's
mainstream press image.

**Late Jan 2019** — Servers offline for emergency rollback over duping /
exploit cheating. Trust in officials never recovered.

**Feb 2019** — Devs publicly acknowledged offline-raiding and alpha-tribe
dominance as the #1 community complaint. Promised major patch (delayed).

**Late March 2019** — "Industrial Wonders" update + first full official
server wipe. Adds new war system, claim system revamp, vitamin
rebalance, submarines (early form), guillotines.

**April 11, 2019** — **Mega-Update v1.5** ("the pivot"). 40% larger map.
Splits the game into two rulesets:
- **Empires** (original hardcore PvP, claim-based)
- **Colonies** (cooperative, settler-based, customizable PvP windows /
  offline-raid protection, settlement upkeep shared between cohabiting
  players)
Adds shipwrecks, deep-sea trenches, full submarine, player shops,
cosmetics.

**Sept 28, 2019** — Another full wipe + major content drop: new world
map, biome layouts, new biome type, 70+ island templates, 20+ cosmetics.

**Late 2019 / early 2020** — Ghost Ship (Ship of the Damned) introduced.
Wildly overtuned at first, "annihilated 95% of player ships," nerfed in
subsequent patches. Vitamin equilibrium widened (±20%), at-sea vitamin
drain removed, level cap dropped.

**Feb 2020** — Devs publicly say "we have problems"; player count
below 5k peak.

**July 3, 2020** — **Maelstrom Update**: full map rebuild (circular
layout, Kraken in center, safer outer rings), island upkeep cut ~75%,
NPC crew upkeep cut ~50% sea / 84% land, gold drops cut 62%. Single
global PvE server, region-locked PvP. By this point peak was ~3,000.

**Post-Aug 2020** — Updates dwindled to 1-2/month, then effectively
stopped. By 2024 the game is in maintenance limbo with the team
reportedly redirected to ARK.

## Things to NOT replicate (consolidated)

These are universally cited as design mistakes by the community and
press; see [07-anti-patterns.md](../07-anti-patterns.md) for the
checklist version.

1. **Claim-flag land monopolization at launch.** First-week players
   locked everyone else out of the world permanently — the single
   biggest cause of churn.

2. **Empty pure-PvP rules with no offline protection.** Offline raiding
   was universally cited as the #1 issue. "Alpha companies" wiped
   sleeping players nightly.

3. **The vitamin system (4 separate nutrients).** Repeatedly voted the
   most hated mechanic. Forced 100s of berries / dozens of fish per day,
   drained while at sea / idle, and was trivial to cheese.

4. **The 15×15 grid (225 servers) for officials.** Server-handoff bugs
   ate ships; lawless freeports became build-spam graveyards; nobody
   could find anyone.

5. **Multi-hour real-time sailing with nothing to do.** Travel time was
   punishment, not adventure.

6. **Build-everything-yourself ship grind for solo / small groups.** A
   galleon's mat cost was tuned for a megacorp, not 4 friends.

7. **Wipes without warning / repeated wipes.** Each wipe shed another
   tier of veterans who refused to grind back.

8. **Trusting admin Steam accounts without 2FA / proper auth.** Caused
   the whale-spawn incident.

9. **Shipping a "surprise" MMO with no real beta.** Day-one was the
   stress test; it failed publicly.

10. **Asset-flipping ARK without diverging the engine.** Same code, same
    bugs, same desync — and reviewers noticed instantly.

11. **Splitting an already-shrinking population across PvE / PvP /
    Empires / Colonies / regions.** Mode proliferation hollowed out
    every individual server.

12. **Ghost Ships that one-shot players' weeks-of-work galleons.**
    Endgame PvE that destroys progression — rage-quit fuel.

## Things players actually wanted but never got

The features the community asked for repeatedly that Atlas never
delivered:

1. **Meaningful pirate gameplay** — boarding actions, treasure maps with
   payoff, naval set-pieces. Most of the game was farming wood and
   managing vitamins.

2. **Faster sailing or skip-travel options** at low cost (fast-travel
   between owned ports without losing the journey's danger).

3. **A real economy / NPC trading loop** that didn't collapse when the
   population fell.

4. **Solo and small-group viable progression** without forced megaguild
   membership.

5. **Reliable offline protection** that worked everywhere, not just
   Colonies.

6. **Fewer survival sim chores** (drop or massively simplify hunger /
   thirst / vitamins / temperature stacking).

7. **Stable cross-grid sailing** — ships despawning at server seams was
   an unsolved bug for the game's life.

8. **Ship persistence / insurance** so a single disconnect or alpha raid
   didn't erase 20 hours.

9. **Actual narrative content / quests** beyond the Power Stones / Kraken
   loop. Maelstrom hinted at this but never delivered.

10. **Communication and a roadmap** — radio silence from devs starting
    April 2020 turned grumbling into total exodus.

11. **Better anti-cheat / report tooling** after the duping and admin-
    account incidents.

12. **A "Sea of Thieves moment-to-moment loop"** — short sessions, high-
    drama encounters. Atlas's loop was always 6+ hours of prep for 10
    minutes of payoff.

## Sources

- Atlas (video game) — Wikipedia
- Atlas, As Told By Steam Reviews — Kotaku (Jan 2019)
- 'Atlas' Hackers Use Admin's Account — Variety (Jan 2019)
- Atlas takes aim at offline raiding — Massively OP (Feb 2019)
- 'Atlas' Mega Update Brings New Land — Variety (April 2019)
- 'Atlas' Update 1.5 Patch Notes — Newsweek (April 2019)
- The Maelstrom has arrived — Massively OP (July 2020)
- Pirate MMO ATLAS Lost 90% of its Playerbase — GameWatcher
- Whatever happened to Wildcard's Atlas — Massively OP (April 2024)
