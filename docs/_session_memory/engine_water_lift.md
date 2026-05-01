---
name: notatlas water/ocean engine lift
description: The major net-new engine work. User has the Zig engine + fallen-runes 3D Vulkan renderer but has never built ocean rendering, buoyancy physics, ship-as-vehicle, or wind. This is the high-risk learning area for Phase 0/1.
type: project
originSessionId: cb0aa047-d395-4803-bc6b-7df96341b031
---
The user explicitly flagged this as the area they have not done before and where the bulk of solo engine work will go before bringing in additional devs.

**Layered subsystems, hardest at top:**

1. **Ocean rendering** — visual water surface
   - v1: Gerstner waves (sum of trochoidal wave functions in vertex shader, ~few hundred lines, 80% of the visual feel for 5% of the work)
   - v2 upgrade: Tessendorf FFT-based ocean (industry standard; UE5's water plugin is this; expensive but stunning)
   - References: Acerola's YouTube ocean series, Tessendorf 1999 paper, Inigo Quilez articles, Sea of Thieves GDC talk
   - Don't build FFT first. Gerstner ships fast and survives playtesting.

2. **Wave query API** — sample wave height/normal at world (x,z) for buoyancy
   - Same wave functions as renderer but evaluated CPU-side at hull sample points
   - Critical: deterministic between client and server given same time + seed

3. **Buoyancy physics** — ships float and pitch correctly
   - Per-hull-point sampling: 6-12 points along ship hull, sample submerged depth, apply Archimedes force per sample
   - Couples to rigid-body solver (use Jolt via FFI, or Bullet, or hand-roll for simple boxes)
   - Damping for water drag

4. **Wind field** — game system, not just particles
   - Per-cell or per-region wind direction + magnitude vector
   - Sails interrogate wind to compute forward force
   - Storms/calms as wind-field perturbations
   - Probably owned by an env service publishing to NATS

5. **Ship-as-vehicle physics** — moving platform with player passengers
   - Hardest detail: characters walking on a ship that's pitching/yawing in waves
   - Practical solution: parent-frame approach. Players' positions are stored in ship-local coordinates while aboard. World-space pose computed = ship pose ⊗ local pose.
   - Server-authoritative ship pose; clients interpolate.
   - Replication: ship pose + velocity at modest rate; ship damage state (planks/sails) on change; attached players in ship-local frame.

6. **Naval combat damage model** — what makes the fight loop feel
   - Plank HP per piece; below 50% leaks (slow water ingress); destroyed = fast leak
   - Cumulative water in hull → reduces buoyancy → ship rides lower → eventually sinks
   - Sail damage → less force from wind
   - Crew/cannon hits as separate damage paths

**Risk-ordered Phase 0/1 milestones:**
1. Gerstner ocean rendering visible and pretty in sandbox.
2. Wave height query function — same answer client and server given (time, seed).
3. A box that floats correctly on the waves.
4. The box has rotational inertia and pitches in waves.
5. The box has a player parented to it; player walks around without breaking.
6. Two clients, one box, one server — the box's pose stays in sync.
7. The box becomes a sloop with a sail; sail produces force from a wind vector.
8. The sloop has plank-HP entities; cannons can damage them; flooding sinks the sloop.

That's the *minimum viable naval engine*. Everything else (multiple cells, NPC crew, treasure maps, taming, building) is a layer on top.
