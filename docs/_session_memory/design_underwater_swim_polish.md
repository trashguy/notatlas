---
name: underwater visuals — v0 placeholder, swim polish deferred
description: M2.7 fixed underwater rendering with a flat-fog short-circuit. A real swimming visual experience (caustics, surface-from-below, particles, wake) is deferred to post-M5 when players actually exist in the world.
type: project
originSessionId: e75d58d3-a7e6-474b-a3e9-ea4994fecf12
---
The underwater path in `assets/shaders/water.frag` is a v0 placeholder:
short-circuits on `eye.y < 0` to a plain `fog_color` gradient
(0.6× toward seabed, 1.4× toward surface). Hits the design-doc bar
(`m2-ocean-render.md` §10.2 item 5: "fog kicks in below the waterline")
and nothing more.

A real swim experience will need (rough scope, not a spec):
- caustic light patterns from sun filtering through the wavy surface
- surface visible from below (Snell-cone refraction; sky compressed
  inside total-internal-reflection cone)
- suspended-particle volumetric pass (cheap noise + parallax)
- wake / bubbles around the player when moving
- camera sway proportional to wave drag at depth
- audio muffling (separate concern, not in the renderer)
- "wet screen" / dripping effect when resurfacing

**Why:** decided 2026-04-27 after the M2.7 underwater bug fix. Players
don't exist in the world until M5 (ship-as-vehicle), and swimming as a
gameplay verb isn't on the Phase-0/1 critical path. Building this now
would be premature — it would be tuned against an empty scene with no
players, no boats, no shorelines, no anchorages.

**How to apply:** when underwater visuals come up later (likely Phase 2
or Phase 3 polish), treat it as its own self-contained shader pass —
don't keep growing the `eye.y < 0` short-circuit branch. Probably
warrants its own milestone doc and its own perf gate. Don't let "make
swimming look nice" creep into M2/M3/M5 milestones — they each have
their own gates and this isn't one of them.
