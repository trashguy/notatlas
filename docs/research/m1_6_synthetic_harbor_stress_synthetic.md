# M1.6 synthetic-harbor-stress — synthetic baseline

**Date:** 2026-05-12
**Status:** PASS. All five M1.6 gate clauses green at the design-cap
configuration on the dev box. Closes the Phase 2 client-side
synthetic arc.

This is the **synthetic** baseline. Per
`feedback_synthetic_baseline_then_diff.md`, M27 (Phase 2.5) re-runs
the same harness against real glTF + KTX2 + rigs (+ HDA-cooked
content if the Houdini arc shipped) and diffs against these numbers.

## Gate

> 500 random structures + 30 box-ships + 200 dummy characters
> animated + 100 particle emitters firing simultaneously
> Target: 60 fps on RTX 4060 / RX 7600
> Any subsystem >2 ms gets fixed before content lands

Closes Phase 2 → Phase 2.5. After this milestone the engine has a
synthetic baseline for every Phase 2 perf gate; M27 swaps in real
assets and produces the diff that proves "engine survives real
production content" (Phase 3 unlock).

## Composition under test

```
Scene (single sandbox invocation):
  ┌──────────────────────────────────────────────────────────┐
  │ M11 anchorage (500 pieces × 20 piece types, r=50 m)      │  near-LOD
  │  → instanced.addInstance × 500                           │  at this cam
  │  → cluster_merge.Anchorage prepared but force_far OFF    │  position
  │                                                          │
  │ M1.6 ships (30 box-ships, hull 15×3×5 m, r∈[180, 280] m) │  static
  │  → instanced.addInstance × 30                            │
  │                                                          │
  │ M12 chars (200 placeholder-anim, 3 distance bands)       │  near 66
  │  → instanced.addInstance × 200                           │  mid  66
  │  → instanced.setAnimParams (vertex-shader bobble)        │  far  68
  │                                                          │
  │ M1.6 emitters (100 × 20 particles = 2000 slots) DISPOSABLE │
  │  → instanced.addInstance × 2000                          │  CPU-bound
  │  → per-frame instanced.updateTransform × 2000            │  stub
  │                                                          │
  │ Existing scene (1 ship + 4 pax)                          │
  └──────────────────────────────────────────────────────────┘
  Total: 2735 Instanced SSBO slots, single multi-draw indirect

Per-frame CPU:
  - anim_lod.System.tick (M12)        ~0.04 ms
  - particle stub transform loop       ~0.18 ms  (DISPOSABLE)
  - instanced.prepareFrame (bucket)   ~0.5  ms   (dominates)
  - GPU work (MAILBOX, RX 9070 XT)    ~0.3  ms
  ─────────────────────────────────────────────
  ≈ 0.83 ms average frametime, 1206 fps
```

## Diff metadata (load-bearing for the M27 re-gate)

| Field | Value |
|---|---|
| **Hardware** | RX 9070 XT (RDNA 4); dev box. NOT the RTX 4060 / RX 7600 the gate spec cites — see `dev_machine_gpu.md`. M1.6 numbers here are an **upper bound** for the spec target. The re-gate must either replay on a 4060-class card OR establish a fresh RX 9070 XT baseline for a meaningful diff. |
| **Driver** | Mesa RADV (Arch Linux Mesa version current as of 2026-05-12). |
| **Present mode** | `VK_PRESENT_MODE_MAILBOX_KHR` (`--uncap`). See `feedback_gpu_gate_uncap.md`. |
| **Warmup skip** | First 30 frames discarded by `FrameSoakStats.warmup_skip`. |
| **Soak duration** | 10 s (samples ≈ 12 000 at unconstrained framerate). |
| **Window size** | Default 1280×720 (sandbox default). |
| **Scene config** | `--anchorage-pieces 500 --anchorage-piece-types 20 --anchorage-radius 50 --anchorage-lod-distance 100 --m1_6-ships 30 --m12-chars 200 --m1_6-emitters 100 --piece-types 20`. See `scripts/m1_6_gate_smoke.sh` for the canonical invocation. |
| **LOD path actually exercised** | Anchorage centroid sits at ~120 m from the camera (-X 0, 5, 0). After bounding-sphere subtraction the effective distance is ~67 m. That's well inside the 100 m LOD threshold's hysteresis band, so the anchorage stays in **near-LOD** for the full soak — 500 per-piece instanced draws, NOT the merged path. This is the harder render path and the right pessimistic measurement. Far-LOD is gated independently by M11. |
| **Anchorage placement** | Single cluster at world (+120, ~2, 0); r=50 m disc with 500 procedural cubes (24 verts / 36 indices each). |
| **Ship placement** | 30 box-scaled cubes (15 × 3 × 5 m) in a ring r∈[180, 280] m around the origin, yaw set tangentially. RNG seed `0x5111_5111`. |
| **Character placement** | 200 chars in three deterministic distance bands (~25, ~60, ~160 m). RNG seed `0xC1A12C1A`. |
| **Emitter placement** | 100 emitters scattered in a 300 × 300 m harbor patch. 20 particles each on ballistic-arc loops, lifetime 1.5 s. RNG seed `0xE211_7711`. |
| **Particle stub primitive** | Each particle = one Instanced slot, scale 0.15 cube. CPU writes a fresh transform every frame for every particle (2000 writes/frame at design cap). NOT representative of real-particle perf — real M17 will be GPU-compute spawn + GPU-side simulation. |
| **Time channel** | `cam.eye.w` carries monotonic seconds (added at M12). M12 shader bobble + particle phase derivation both read it. |

## Numbers — PASS at design cap

Measured 2026-05-12 via `scripts/m1_6_gate_smoke.sh` (10 s soak).

| Gate clause | Threshold | Measured | Margin |
|---|---|---|---|
| Scene composition complete | all 4 components present | structures + ships + chars + emitters all spawned | structural ✓ |
| Avg frametime | ≤ 16.67 ms (60 fps) | **0.83 ms** (~1206 fps) | ~20× headroom |
| p99 frametime | ≤ 16.67 ms | **1.85 ms** | ~9× headroom |
| max frametime | — | 4.30 ms | (reported, no gate; warmup-skip handled) |
| M12 CPU anim | ≤ 2 ms/frame | **0.038 ms avg / 0.055 ms p99** | ~50× headroom (placeholder cost) |
| Particle stub CPU | ≤ 2 ms/frame | **0.178 ms avg / 0.255 ms p99 / 0.394 ms max** | ~10× headroom (CPU-bound stub) |

Per-frame breakdown (1206 fps, design cap):
- M11 anchorage near-LOD render: 500 instances via the multi-draw indirect path. GPU dominates here.
- M12 CPU anim: 0.038 ms (synthetic skin work for 66 near + 66×5/60 mid).
- Particle stub: 0.178 ms (2000 CPU transform writes/frame, no GPU upload cost — host-coherent SSBO).
- `instanced.prepareFrame`: ~0.5 ms (CPU bucket-scatter for ~2735 slots, dominates the CPU side).
- GPU draw (MAILBOX): ~0.3 ms (compute cull + multi-draw indirect, RX 9070 XT).

## Known gaps the M27 re-gate will surface

1. **The 0.83 ms frame is on a 4060+ card.** Spec cites RTX 4060 /
   RX 7600 (mid-tier 2024 hardware). RX 9070 XT is well above
   that. The 4060-class re-gate must either replay on actual
   4060-class silicon OR scale-adjust based on a published 4060
   workload-equivalence study. Synthetic-margin headroom on the
   dev box is NOT a "we have headroom on the spec target."

2. **Anchorage piece geometry is 24 verts.** Real building pieces
   (wharf section, shed wall, plank stack) are 200-2000 verts
   each. 500 pieces × 1000 verts = 500 000 verts vs the synthetic
   12 000. Near-LOD draw cost is linear in vertex count — expect
   the 0.83 ms baseline to grow to ~10-30 ms when real pieces
   land, putting the gate margin at ~1×. The M11 merged-mesh path
   becomes load-bearing at that scale.

3. **Ship geometry is a scaled cube.** Real ship meshes are ~5-15k
   verts with hull plating, masts, rigging. 30 ships × 10k verts
   = 300k verts. Will dominate the static-render budget. M27 must
   re-measure ship-render cost and decide if ships also need a
   merged-mesh treatment at >100 m.

4. **Character geometry is a 24-vert cube — same gap as M12.** Real
   characters are 1k-5k verts each with skin weights + joint
   indices per vertex. Already covered in
   `docs/research/m12_animation_lod_synthetic.md` §"Known gaps".

5. **Particle stub IS THE OPPOSITE OF REAL PARTICLES.** This stub
   is CPU-bound (2000 transform writes/frame). Real M17 particles
   are GPU-compute spawn + GPU-side simulation with ~zero CPU
   cost per particle. The 0.178 ms here is the cost of the
   placeholder, not a predictor of the real system. The
   directional headroom signal is **only**: "there is ≥10× CPU
   headroom for whatever the real particle system shape turns
   out to be." That's a coarse signal — don't over-interpret.

6. **No materials, no textures.** All instances use per-instance
   vec3 albedo. Real harbor scene will need PBR materials, KTX2
   textures, descriptor-set rebinds per material — none of that
   is measured here. M14 (KTX2 + texture streaming) ships before
   M27.

7. **No skin-palette upload bandwidth.** M12 still doesn't write
   real skin palettes; the bone-count knob is a CPU rotation
   stand-in. Same gap as M12 isolated.

8. **No fog/atmosphere render pass.** Atmosphere is fixed-sky
   sample (per `feedback_fixed_fog_direction.md`); real fragment-
   shader fog over 2735 instances will add cost not measured here.

9. **The single anchorage means single-cluster culling.** Multiple
   anchorages on screen (a real harbor would have 3-5+) means N×
   the anchorage cull cost. Out of scope here; future work.

10. **Camera is stationary.** No LOD transitions during the soak.
    With moving camera, M11 LOD switch + M12 tier transitions both
    fire — M27 should add a "moving camera" soak variant.

## Reproduce

```
./scripts/m1_6_gate_smoke.sh          # defaults: 10s soak at full design cap
./scripts/m1_6_gate_smoke.sh 30       # longer soak
```

Direct invocation (skip the rebuild step):
```
./zig-out/bin/notatlas-sandbox \
  --uncap \
  --piece-types 20 \
  --anchorage-pieces 500 \
  --anchorage-piece-types 20 \
  --anchorage-radius 50 \
  --anchorage-lod-distance 100 \
  --m1_6-ships 30 \
  --m12-chars 200 \
  --m1_6-emitters 100 \
  --soak 10
```

Interactive (no soak):
```
./zig-out/bin/notatlas-sandbox --uncap \
  --piece-types 20 \
  --anchorage-pieces 500 --anchorage-piece-types 20 --anchorage-radius 50 \
  --m1_6-ships 30 --m12-chars 200 --m1_6-emitters 100
# WASD to fly around the harbor.
```

## Phase 2 client-side synthetic arc — CLOSED

M10 (gpu-driven-instancing) ✓, M11 (structure-lod-merge) ✓, M12
(animation-LOD) ✓, M1.6 (synthetic harbor stress) ✓. All synthetic
baselines captured with diff metadata.

**Next:** planned context clear → Phase 2.5 asset-pipeline work
(M13 …). M27 (Phase 2.5 close) re-runs all four gates against real
glTF + KTX2 + rigs and diffs against these four synthetic baselines.

**Don't lose these docs** — they're the zero-point for the M27
diff. The four findings docs together describe the engine's
synthetic perf envelope; M27 turns that into a real-content perf
envelope.

**Disposable code to delete at M17 (real particle system):**
- `M16Emitter` struct + spawn block in `src/main.zig`
- Particle update loop in `src/main.zig`
- `M16SoakStats.particle_*` fields + report lines
- `--m1_6-emitters` CLI flag + parsing
- `m1_6_particles_per_emitter` const
