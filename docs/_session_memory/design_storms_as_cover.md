---
name: Storms as cover (visibility + stealth + audio)
description: Storm cells aren't just wind perturbations — they're cover regions. Visibility, stealth, and audio masking share the storm's center+radius. Shapes M4.2+ scope and constrains storm_vortex_mix.
type: project
originSessionId: d921bb73-2d2b-48f6-9521-6f173380f4e4
---
Storms in notatlas are a multi-system feature, not just a wind effect.
Each storm cell exposes a center + radius + strength that drives, at
minimum, four orthogonal subsystems:

- **Wind perturbation** — `windAt(x,z,t)` (M4.1, already in)
- **Visibility / fog** — `stormDensityAt(x,z,t) → f32`, fog density and
  draw-distance reduction sharing the same Gaussian falloff as the wind
  contribution
- **Stealth / concealment** — server-side spotting / aggro / name-tag
  checks gate on storm density at target position
- **Audio masking** — rain/thunder masks gunfire and footsteps inside
  the cover region

**Why:** in Atlas, sneaking up on enemy ships using storm + fog cover is
one of the canonical "fun moments" the user remembers from their own
play (2026-04-28 chat). The combat-at-scale pillar's interesting
emergent behavior comes from terrain-as-tactic, and storms ARE the
ocean's terrain. If storms are just a wind effect, that whole behavior
is gone.

**How to apply:**

1. When M4.2 lands the YAML loader / storage for wind storms, expose
   storms as **addressable entities** (id, center(t), radius, strength),
   not just an opaque `windAt` kernel. The visibility / stealth / audio
   queries can be added in a later milestone (likely a dedicated storm
   subsystem post-M4 or piggybacked on env service in Phase 2), but the
   API shape needs to be set early so all four uses share consistent
   boundaries (a target either *is* or *isn't* inside the same storm
   for wind, fog, stealth, and audio).

2. Keep `storm_vortex_mix` low (≤ ~0.2) in default presets. A swirly
   cyclone makes a bad hiding spot because wind direction inside is
   chaotic — players want predictable sailing inside cover. Vortex
   flavor is fine as a rare visual element, not the default.

3. Don't model storms with smooth blended fields where "is target in a
   storm" can't be answered cleanly. The Gaussian falloff used for wind
   contribution is fine because we can apply a density threshold (e.g.,
   density > 0.3) for boolean "in cover" checks.
