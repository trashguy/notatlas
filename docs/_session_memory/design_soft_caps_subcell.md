---
name: 200/cell is soft target; ports get sub-cell partitioning
description: 200 players/cell is the design target, not a hard cap — exceeding degrades performance gracefully (hardcore players tolerate some lag for the big fight). High-density zones (ports, anchorages) use sub-cell partitioning per docs/08 §2.4a, not population caps.
type: project
originSessionId: f742d3a7-70b9-48ed-9e79-2dcda4fb8d1e
---
200 players/cell is a **soft target**, not a hard limit. The system should degrade gracefully past it (added latency / dropped fast-lane forwards / coarser tier banding) rather than refusing entries or hard-capping the cell.

**Why:** hardcore PvP players tolerate some lag during the headline fight. A hard cap that turns players away is worse UX than a degraded fight. Atlas's failure mode was "~100/node and falling over"; ours should be "200/node smooth, 300/node degraded but playable, no cliff."

**Ports / anchorages specifically need a sub-cell setup.** Population concentrates spatially in a way that empty-ocean tuning won't survive. Per docs/08 §2.4a sub-cell partitioning (M-workers-per-cell of one cell) is the architectural lever; ports/anchorages are the canonical use case for it. Phase 2+ gameplay decision when those zones get built out.

**How to apply:**
- BW / perf gates: design scenarios at 1.0× and 1.5× target. Both should pass; the second should show soft degradation, not a cliff.
- When proposing density solutions, default to sub-cell partitioning for spatial concentration, not population caps.
- Don't treat 200/cell as a contract or assertion — it's the comfortable design point. The roadmap stress gates should phrase it that way.
- The existing entity-inventory framing (~30 ships + ~30 free-agents = ~60 fanout entities at peak) is the comfortable point; ports will routinely exceed it and that's expected.
