---
name: Hull config inheritance via extends-chain
description: Per-tier hull tuning (sloop/schooner/brig) lives in `data/hulls/<tier>.yaml` with optional `extends:` chains. Loader merges child over parent. Same pattern available for any future tunable.
type: project
originSessionId: c1312058-0055-4b80-b843-8d3ba282200b
---
Shipped 2026-05-01 in `e4ce7e4`. Pattern designers should follow
when authoring new ship tiers (or any other inheritance-friendly
config — AI archetypes, ammo families, biome variants).

**Schema** (`data/hulls/_base.yaml` is the reference template):
- half_extents (collision + render scale)
- mass_kg, hp_max
- buoyancy: cell_half_height, cell_cross_section, drag_per_point,
  sample_points
- sail_force_max_n, sail_baseline_mps, steer_max_n
- cannons[]: per-cannon offset_xyz, cooldown_s, range_m

**Authoring a new tier:**

```yaml
# data/hulls/schooner.yaml
extends: _base.yaml
mass_kg: 22000
hp_max: 450
cannons:
  # arrays REPLACE — list every cannon you want, not just deltas
  - { offset_x: 2.5, offset_y: 1.0, offset_z: -2.0, cooldown_s: 1.5, range_m: 200 }
  - { offset_x: 2.5, offset_y: 1.0, offset_z:  2.0, cooldown_s: 1.5, range_m: 200 }
```

Multi-level chains work (`brig.yaml extends schooner.yaml`).
Cycles bounded at depth 8 → `error.ExtendsCycle`.

**Loader behavior:**
- Path resolution: relative to the file containing `extends:`.
- Merge: child non-null scalars win. **Arrays REPLACE wholesale**
  — there's no append/insert/diff. If you want all of base's
  cannons plus more, list them all in the child.
- Validation: every required `HullConfig` field must be non-null
  at the leaf, else `error.MissingField`.

**Why hand-rolled parser, not ymlz:** ymlz panics on missing
fields. The whole `extends:` premise is "child has only the
fields it overrides" so the parent's deltas pass through. ymlz
can't represent that. Same constraint that justified
`shared/bt_loader.zig`'s mini-parser.

**Per-cannon cooldown:** entity has single `next_fire_allowed_s`;
`salvo_cooldown_s = max(cannons[].cooldown_s)` gates broadside
on the slowest gun. Mixed-cooldown batteries (bow chaser +
broadside) would need per-cannon timestamps; lift when a tier
needs it.

**Per-entity hull pointer:** v0 has a single global hull;
ship-sim threads it through tick / fireCannon / applyShipInputForces.
Lifting to per-entity hull (when schooner spawns alongside sloop)
is a small follow-up — entity carries `*const HullConfig`, fire/
input paths look it up rather than threading from main.
