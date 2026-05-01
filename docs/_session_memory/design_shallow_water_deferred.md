---
name: shallow water look deferred to Phase 2
description: shallow-water visuals (steepened waves, surf line, foam at shorelines) are out of scope for Phase 0; tied to anchorages/coastlines work
type: project
originSessionId: 0e70b569-17de-45d1-95e3-329e743019b1
---
The current ocean shader (`assets/shaders/water.frag`) renders open
deep-water everywhere — single global wave field, uniform across the
entire surface. Atlas had distinct shallow-water visuals near coasts:
waves shortening and steepening as they approached shore, breaking surf,
shoreline foam.

**Why deferred:** Phase 0 has no anchorages, no coastlines, no land
geometry — the world is "open ocean" only. Shallow-water effects need
either depth-from-bathymetry sampling or a separate per-cell parameter
("this cell is shallow") published by env-service. Both depend on
infrastructure that arrives at Phase 2 (cell-mgr, env service, anchorage
structures).

**How to apply:** Don't try to bolt shallow-water effects onto the M2
shader piecemeal. When the time comes (Phase 2, Milestone 1.6 territory)
plan it as a coordinated change: env-service publishes a per-cell
"depth scalar" or bathymetry texture, water shader samples it, modifies
the wave kernel's `wave_scale_m` and `amplitude_m` locally near
zero-depth shores, plus adds shoreline foam. The current ocean.yaml
already has a `shoreline_falloff_m` placeholder that hints at this from
the original m2 design doc — keep it as a marker.
