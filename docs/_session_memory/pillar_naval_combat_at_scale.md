---
name: notatlas headline pillar — smooth naval combat at scale
description: The defining feature for notatlas. Atlas died at ~100 players per node during big boat/land raids. notatlas's selling point is naval combat that stays smooth with hundreds of players in close engagement. All architecture decisions must support this; if a system can't, redesign it.
type: project
originSessionId: cb0aa047-d395-4803-bc6b-7df96341b031
---
The user has identified this as **the** pillar. Phrasing was: "the big gameplay issue with the original was everyone wanted to do massive boat and land raids and it would die at like 100 players on node — smooth boat combat will be the biggest selling point."

**This means:**
- Whenever we evaluate a design or library choice, the question to ask is: "Does this scale to 200+ players in a single naval engagement?"
- Acceptable to drop other features (taming, complex survival sim, vitamin systems, etc.) to preserve combat-at-scale.
- Unacceptable to design systems that work fine at 50 CCU but melt at 200. If we can't see the scale path, we're not building it that way.

**Concrete targets to design against:**
- 200 players in a single contiguous engagement (one cell + neighbors)
- 30 ships (mix of sloop/schooner/brigantine/galleon) in active combat
- 1000+ in-flight projectiles peak (mass cannon volleys)
- 60Hz authoritative ship pose, ≤100ms client perceived latency
- No frame stutter, no rubber-banding, no cell-boundary hitches
- Per-client downstream bandwidth ≤1 Mbps under peak load

**What this constraint propagates to:**
- Tiered replication is mandatory (full fidelity nearby, summary at distance)
- Deterministic projectile model required (don't replicate cannonballs per-tick)
- State-change side channel separate from pose firehose
- Aggressive pose compression (quaternion + delta + bit-packed)
- Server-side spatial filtering before fanout, not client-side
- Voice chat spatial-filtered or pushed to a separate transport
- Damage model must be event-driven (publish on change), not state-replicated

**Stress test gate (use as a project milestone):**
Before Phase 3 content work begins, run a synthetic "naval brawl" load test:
- 50 bots + 10 humans, 5 ships, single cell, 5-minute engagement
- Then scale to 200 bots + 10 humans, 30 ships
- Then 200 humans (closed playtest)
- Each scale level must show: stable 60Hz tick, ≤100ms perceived latency, ≤1Mbps client BW, no client stutter
- If a level fails: stop, fix before adding content. Atlas's terminal mistake was layering content on architecture that already couldn't hold scale.
