# M12 animation-LOD — synthetic baseline

**Date:** 2026-05-12
**Status:** PASS. All four M12 gate clauses green at the design-cap
200-character configuration on the dev box.

This is the **synthetic** baseline. Per
`feedback_synthetic_baseline_then_diff.md`, M27 (Phase 2.5) re-runs
this harness against real glTF skeletons + skin-palette uploads
and diffs against the numbers below. The diff is the load-bearing
comparison — these numbers in isolation are misleading because the
placeholder anim primitive is orders of magnitude lighter than real
skinning.

## Gate

> 200 animated characters at varied distance; CPU animation cost
> ≤ 2 ms per frame.

Closes M12 and the Phase 2 client-side synthetic arc. M1.6
(synthetic harbor stress) combines M10 + M11 + M12 outputs into the
Phase 2 → Phase 2.5 closer.

## What this milestone is and isn't

**No skeletal-animation system exists in the engine yet.** §12's
three tiers — "full rig + IK", "5 fps reduced rig", "vertex-shader
anim atlas" — are bucket *intents*. What M12 v0 actually ships:

1. **Tier-distance arithmetic + dispatch is correct.** Every
   character lands in exactly one bucket per frame; the far bucket
   is verifiably skipped on the tick path; mid bucket fires at the
   configured rate (default 5 Hz).
2. **A CPU-cost budget gate.** 200 chars at varied distances stay
   under the §12 ≤2 ms/frame ceiling for the synthetic skin-work
   stand-in (a configurable `bone_count` rotation-accumulation
   inner loop).
3. **A working "zero CPU work for far tier" path.** The vertex
   shader (`assets/shaders/instanced.vert`) reads `cam.eye.w` as
   monotonic time and per-instance `meta.y`/`meta.z` as phase +
   amplitude, adding a sinusoidal Y bobble. The CPU never touches
   far-tier instances after spawn — that's what makes the gate
   meaningful, not the bobble itself.

Bucket *contents* (rig depth, IK solve cost, real skin-palette
upload bandwidth) are M27's problem. The bucket arithmetic + the
dispatch + the ≤2 ms gate carry forward into the M27 re-gate
unchanged; only the per-bone unit cost swaps.

## Architecture under test

```
main thread                                 GPU
─────────                                   ───
spawn N characters in 3 distance bands
  → instanced.addInstance × N
  → instanced.setAnimParams(id, phase, amp) × N   (writes meta.yz)

each frame:
  ocean.updateCamera(camera, t)             # eye.w = t
  anim_lod.System.tick(world_eye, dt, &instanced)
  ├── for each char:
  │     d = ‖anchor - world_eye‖
  │     tier = animLodSelect(d, near=30, mid=100)
  │     ├── .near → simBones(near_bones=32)
  │     ├── .mid  → simBones(mid_bones=8) if 5 Hz accumulator fires
  │     └── .far  → SKIP (zero CPU work)
  └── stats.elapsed_ns observed

  instanced.prepareFrame()                  → instance SSBO upload
                                              (meta.yz unchanged for
                                               far-tier chars)
  frame.draw → instanced.vert:
                amp = uintBitsToFloat(meta.z)
                if (amp != 0.0) {
                    phase = uintBitsToFloat(meta.y)
                    wp.y += amp * sin(cam.eye.w * 2.0 + phase)
                }
```

Two load-bearing properties to note for the M27 swap:

- **`updateTransform` is never called for any tier**, including
  near/mid. The CPU does the synthetic skin work but doesn't write
  back to `instance.model`. This matches the M27 swap-in shape —
  real skinning produces a skin-palette SSBO (a separate upload),
  not a new model matrix. The placeholder mirrors that the right
  way.
- **`cam.eye.w` is the global time channel.** Was unused padding
  pre-M12; now carries monotonic seconds. Any future system that
  needs frame-coherent time on the vertex stage uses this. Adding
  a dedicated time UBO is unnecessary — the camera UBO is updated
  once per frame already.

## Diff metadata (load-bearing for the M27 re-gate)

| Field | Value |
|---|---|
| **Hardware** | RX 9070 XT (RDNA 4); dev box. NOT the RTX 4060 / RX 7600 cited in `pillar_harbor_raid_client_perf.md` — see `dev_machine_gpu.md`. Re-gate must either replay on a 4060-class card OR re-baseline against the same RX 9070 XT for a comparable diff. |
| **Driver** | Mesa RADV (Arch Linux Mesa version current as of 2026-05-12). Capture `vulkaninfo` before any real-asset re-gate. |
| **Present mode** | `VK_PRESENT_MODE_MAILBOX_KHR` (`--uncap`). NOT FIFO — see `feedback_gpu_gate_uncap.md`. |
| **Warmup skip** | First 30 frames discarded by `FrameSoakStats.warmup_skip`. |
| **Soak duration** | 10 s (samples ≈ 12 000 at unconstrained framerate). |
| **Window size** | Default 1280×720 (sandbox default). |
| **Scene config** | `--m12-chars 200 --m12-near-threshold 30 --m12-mid-threshold 100` (defaults). Three deterministic distance bands: near ≤ 25 m, mid 34–85 m, far 120–200 m. Camera at ship origin (~0, ~5, 0). RNG seed `0xC1A12C1A`. |
| **Character geometry** | Procedural ±0.5 unit cube (palette piece 0, shared with the M10/M11 grid + anchorage). 24 verts / 36 indices per character. **This is the most important field for the M27 diff** — real character meshes will be ~1000-5000 verts each WITH per-vertex skin weights × 4 bone indices, which is the actual cost the gate measures. |
| **Anim primitive** | `meta.y` = `floatBitsToUint(phase_radians)`, `meta.z` = `floatBitsToUint(amplitude_m)`. Vertex shader does `wp.y += amp * sin(cam.eye.w * 2.0 + phase)`. ONE sin per vertex per far-tier instance. |
| **Skin work (placeholder)** | `simBones(N)` runs N rotation accumulations (cos + sin + 4 mul + 1 sub per "bone"). Near: `--m12-near-bones 32`. Mid: `--m12-mid-bones 8`. Far: 0. M27 swaps this for `mat4 joint = skin_palette[joint_id] * weight; pos += joint * v_pos` × N_bones. |
| **Mid-tier tick rate** | 5 Hz (`--m12-mid-hz 5.0`). Accumulator-gated; mid tier fires exactly once per 200 ms wall-clock. |
| **Time channel** | `cam.eye.w` carries monotonic seconds (was unused padding pre-M12). |

## Numbers — PASS at 200 × default-thresholds

Measured 2026-05-12 via `scripts/m12_gate_smoke.sh`.

| Gate clause | Threshold | Measured | Margin |
|---|---|---|---|
| CPU anim cost (avg) | ≤ 2.0 ms/frame | **0.039 ms** | ~50× headroom |
| CPU anim cost (p99) | ≤ 2.0 ms/frame | **0.055 ms** | ~36× headroom |
| CPU anim cost (max) | — | **0.094 ms** | reported, no gate |
| Far tier exercised + skipped | ≥1 char in .far band | **68 chars** | structural ✓ |
| Avg frametime | ≤ 16.67 ms (60 fps) | **well under** | (FrameSoakStats reports) |
| p99 frametime | ≤ 16.67 ms | **well under** | (FrameSoakStats reports) |

Mid-tier dispatch verification:
- 12 167 frames over 10 s ⇒ ~1217 fps avg.
- 3 234 total mid ticks ⇒ ~49 fires × 66 chars-in-mid-band = 3 234.
- 49 fires / 10 s = **4.9 Hz**, matches the configured 5 Hz within
  one accumulator boundary.

CPU work breakdown (per tick at design cap):
- Near tier: 66 chars × 32 bones × (cos + sin + 4 mul + 1 sub) ≈ 2 112 trig pairs.
- Mid tier (when firing): 66 chars × 8 bones ≈ 528 trig pairs.
- Far tier: 0.
- Sum-over-frame: ~2 112 trig pairs when mid doesn't fire, ~2 640 when it does. At RX 9070 XT scalar perf this lands at 35-95 µs as observed.

The 50× headroom is **not the win to celebrate**. The placeholder
is intentionally light — real skinning is closer to 200 000 ops per
char (1 000 verts × 4 weights × ~50 ops per blend), so M27 expects
roughly a 1000× cost multiplier. The carry-forward result is "we
have ~2 ms budget, divided among ~200 chars, which puts the per-char
budget at ~10 µs". That's the constraint M27 measures against, NOT
"0.039 ms is fine."

## Known gaps the M27 re-gate will surface

1. **Vertex count + skin weights are absent.** Each placeholder
   "character" is a 24-vert cube. Real characters will be
   1 000–5 000 verts with `vec4 joint_weights` + `uvec4
   joint_indices` per vertex, plus skin-palette SSBO sampling in
   the vertex shader. Expect the per-frame GPU vertex-fetch cost
   to dominate everything the synthetic measured.
2. **No skin-palette upload bandwidth.** Real near/mid tiers
   write a `mat4 skin_palette[N_joints]` per character per tick
   (~256 B/char/tick at 16 joints). At 67 near chars × 60 Hz =
   ~1 MB/s upload — well below pcie bandwidth but the buffer
   choreography is currently zero. M27 must measure and budget
   this against the synthetic floor.
3. **No IK solver.** §12's `.near` tier promises "full rig + IK".
   IK is iterative (CCD/FABRIK typically); per-char cost is
   nonlinear in chain length. Out of scope here; the bone-count
   knob will need an "ik_chain_length" companion at M27.
4. **5 Hz mid tier visibly stutters.** Real anim systems
   interpolate between sparse-tick poses. The placeholder has no
   blend logic — far tier bobble is smooth (shader-driven), mid
   tier transforms jump at 5 Hz. Acceptable here because the gate
   measures CPU cost, not visual quality; M27 picks the blend
   strategy (skip-frame palette interpolation vs. dual-quaternion
   slerp vs. linear-blend with a held delta).
5. **No tier-transition cost.** Characters are placed in static
   bands; the camera doesn't move in the gate. Real anim with a
   moving camera will trigger .far ↔ .mid transitions, which want
   to spin up / spin down anim state. M27 should add a "moving
   camera" soak variant analogous to M11's natural-LOD variant.
6. **`updateTransform` plumbing missing.** The synthetic path
   doesn't call `instanced.updateTransform` for any tier. Real
   skinning probably still wants root-motion / world placement
   updates from a separate animation graph — that path is M27's
   responsibility to spec.
7. **`amp != 0.0` short-circuit is gameable.** Any non-anim
   instance (ship, pax, anchorage) currently passes through the
   shader path with one float-bit-cast + one comparison per
   vertex. At anchorage scale (500 pieces × 24 verts × 60 Hz =
   720k vert invocations/sec) this is negligible. M27 with real
   piece geometry (~50k verts per anchorage) should re-measure;
   if it's nonzero, gate the anim-bobble code behind a piece-type
   flag instead of a per-instance amplitude check.

## Reproduce

```
./scripts/m12_gate_smoke.sh                  # defaults: 200 chars × 30/100 thr × 10s soak
./scripts/m12_gate_smoke.sh 400 30 100 5     # stress: 400 chars × 5s
./scripts/m12_gate_smoke.sh 50 20 80 5       # smaller: 50 chars × tight thresholds
```

Direct invocation (lets you skip the rebuild step):
```
./zig-out/bin/notatlas-sandbox \
  --uncap \
  --m12-chars 200 \
  --m12-near-threshold 30 \
  --m12-mid-threshold 100 \
  --m12-mid-hz 5 \
  --m12-near-bones 32 \
  --m12-mid-bones 8 \
  --soak 10
```

Interactive (no soak):
```
./zig-out/bin/notatlas-sandbox --uncap --m12-chars 200
# WASD to fly around the ship; chars bobble at varied distances.
# Sanity check: chars further than ~100 m bobble visibly even though
# the CPU isn't touching them — that's the shader path (M12.2).
```

## Phase 2 client-side arc — closed

M10 (gpu-driven-instancing), M11 (structure-lod-merge), and M12
(animation-LOD) are now all green at their synthetic gates. M1.6
(synthetic harbor stress) combines them into the Phase 2 → Phase 2.5
closer; after M1.6 the planned context clear opens onto Phase 2.5
asset-pipeline work (M13 …).

M27 (Phase 2.5 close) re-runs M10 + M11 + M12 + M1.6 against real
glTF + KTX2 + rigs (+ HDA-cooked content if the Houdini arc shipped)
and diffs against these three synthetic baselines plus M1.6's. The
diff metadata fields above are the replay contract — anything not
captured here is a fishing expedition at re-gate time.

**Don't lose this doc** — it's the zero-point for that diff.

## Cross-references

- `docs/research/m10_gpu_driven_instancing_synthetic.md` — M10 baseline; M12 claims `instance.meta.y/z` + `cam.eye.w` from M10's reserved fields.
- `docs/research/m11_structure_lod_merge_synthetic.md` — M11 baseline; shares the cube-geometry content shape.
- `docs/research/m1_6_synthetic_harbor_stress_synthetic.md` — Phase 2 closer; composes M10 + M11 + M12 in one scene.
