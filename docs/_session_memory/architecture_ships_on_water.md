---
name: ship buoyancy hits wave_query.waveHeight, not a mesh
description: ships float by sampling the same CPU heightfield the GPU draws — no separate collision mesh; this is the load-bearing reason wave_query is the project's center of gravity
type: project
originSessionId: 0e70b569-17de-45d1-95e3-329e743019b1
---
Ships do **not** float by colliding with a mesh — there is no water
mesh. Both visuals and physics derive from the same scalar function
`wave_query.waveHeight(params, x, z, t)`. The GPU raymarches it for
rendering; future ship buoyancy (M5+) samples it at hull points for
Jolt force integration. Same function, same params, same time → the
hull always sits on the height the player sees.

**Why:** This is what the M2.5 mesh→raymarch rewrite preserved. The
"server source of truth" is the wave function, not geometry. Sharing
the function across CPU/GPU is what keeps client visuals and server
physics aligned without round-tripping pose through a heightmap
texture.

**How to apply:** When M5 ship-as-vehicle work starts, the buoyancy
loop is: sample `waveHeight` at ~12-20 hull points → compute submerged
volume per point → apply buoyant force at point → Jolt integrates.
Don't try to:
- Generate a water mesh for ships to collide against (there isn't one).
- Maintain a separate "physics surface" that diverges from the visual
  surface (defeats the whole point of the rewrite).
- Bake a heightmap texture and sample that instead of calling
  `waveHeight` directly (per-cell wave params need to be live;
  baking adds staleness).

`wave_query.waveHeight` is hot-path: it'll be called ~16 sample points
× 30+ ships × 60 Hz = ~30k calls/sec server-side. Each call is ~20
octaves × ~5 ops = trivial. Don't pre-optimize.

**Open extension:** `wave_query` needs a `waveVelocity()` for rudder/
keel drag forces and Stokes-drift on flotsam. Vertical velocity =
finite difference in time; horizontal Stokes drift = small term
proportional to wave steepness. Add when M5 needs it; not before.
