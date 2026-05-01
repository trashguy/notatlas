---
name: EVE-style transversal-velocity hit model (deferred idea)
description: User raised on 2026-05-01 — if naval combat ever struggles with hit-rate fairness, evaluate EVE Online's transversal-velocity tracking model before tuning physics-based AABB hit resolution further.
type: project
originSessionId: c1312058-0055-4b80-b843-8d3ba282200b
---
If hit-rate balance becomes a tuning headache, evaluate EVE Online's
hit-chance formula before continuing to tune the current
physics-based projectile-vs-AABB resolver.

EVE's surface (paraphrased):

  trans_vel = component of target velocity ⊥ line-of-sight to shooter
  hit_chance = 0.5 ^ ( ((trans_vel / range) / tracking)²
                     + ((sig_resolution / sig_radius) * range_mod)² )

Maps cleanly onto naval combat as a mostly-2D plane fight:
  - **tracking** — how fast a cannon mount can re-aim. Sloop's bow
    chasers track fast, broadside cannon banks track slow.
  - **sig_radius** — ship silhouette (Atlas tier: sloop / schooner /
    brig). Bigger ship = easier to hit.
  - **trans_vel / range** — angular velocity of target relative to
    shooter; small ship moving fast at close range is the hardest
    to land on.
  - **range** — explicit damage falloff curve.

**Why:** Current resolver in ship-sim is AABB-test on each tick of
projectile flight (`resolveProjectileImpacts`) against ship hull
half-extents. This is "did the cannonball physically hit?" — pure
ballistics, no skill-vs-cannon-spec interaction. It works at v0
because ships are slow, but as ships get faster (higher-tier
hulls, downwind running) and engagement ranges grow, raw ballistic
hits will favor head-on closing fights and punish maneuvering —
the opposite of what the design pillar wants.

**How to apply:** Don't bolt this onto Phase 1's combat slice;
the AABB resolver is fine for the current balance. Lift this when
hit-rate balance becomes a tuning headache OR when sub-tier cannon
variants ship (Phase 3+ content). Implementation shape:
  - Add `tracking_rad_per_s`, `sig_resolution_m` to ammo/cannon YAML
  - Add `sig_radius_m` per ship hull
  - Replace the AABB direct-hit branch with the EVE roll; keep
    splash-damage geometry on miss as the "near-miss" path
  - Keep deterministic projectile arc — only the hit-decision
    becomes stochastic. Phase 1 deterministic-projectile gate
    (memory `locked_architecture_decisions`) is preserved.
