---
name: Disembark — lever-arm velocity inheritance (Atlas-style fall, fixed)
description: Updated 2026-04-30 (same day as initial save). Disembarking players inherit ship velocity at the lever arm — `ship.lin_vel + ship.ang_vel × world_off`. Earlier "matches Atlas's drop-straight-down" memory was reversed by user; jolt set_linear_velocity C-API was added.
type: project
originSessionId: 1db61b4b-4308-48b3-88c8-aea4bd15b6a5
---
When a player disembarks (passenger → free-agent), the new capsule body is created at `ship_pose ⊗ local_pose` **with inherited velocity**: `inherited_v = ship.lin_vel + ship.ang_vel × world_off`. Implemented in `src/services/ship_sim/main.zig::applyDisembark`.

**Why:** initial v1 plan deferred this since the Jolt C-API didn't expose `set_linear_velocity`, and Atlas's "fall straight down" was acceptable. User reversed (2026-04-30 same session) — "kinda silly, plus could make collisions fun later" — so the C-API gained `jolt_body_set_linear_velocity` + `jolt_body_set_angular_velocity` (mirrors of the existing getters), and `applyDisembark` now applies the lever-arm formula.

**How to apply:**
- Disembarking off a moving / rotating ship: player carries the kinematic-point velocity at their attach point.
- Future ramming / collision knock-off: same C-API hooks already in place. Use `phys.setLinearVelocity` / `phys.setAngularVelocity` for any "pop a body to a known velocity at spawn" need.
- Don't bring back the "drop straight down" behavior unless it's specifically requested for a verb that means "let go" (vs. "jump off"). The lever-arm formula is the physically correct default.
