# M11 structure-lod-merge — synthetic baseline

**Date:** 2026-05-12
**Status:** PASS. All four M11 gate clauses green at the design-cap
500-piece anchorage configuration on the dev box.

This is the **synthetic** baseline. Per
`feedback_synthetic_baseline_then_diff.md`, M27 (Phase 2.5) re-runs
the same harness against real glTF assets + KTX2 textures + real
rigs and diffs against the numbers below. Any frametime regression
attributable to content shape rather than algorithm is isolated by
that diff — start the investigation there, not in the M11 code.

## Gate

> 500-piece anchorage merges <100 ms; far-LOD render uses merged
> mesh, ~1 draw call. Avg + p99 frametime within the 60 fps budget
> (16.67 ms) under merged-path load.

Closes the Phase 2 → Phase 3 transition path for the
structure-lod-merge subsystem. M10 (gpu-driven-instancing) is the
upstream dependency; M12 (animation-LOD) and M1.6 (synthetic harbor
stress) are downstream and the next two synthetic milestones.

## Architecture under test

```
main thread                      worker thread
─────────                        ─────────────
spawn anchorage cluster (N pieces, varied TRS in disc)
  → cluster_merge.Anchorage.init (sync merge)         (initial bake)
  → upload to GPU host-visible VBO + IBO

each frame:
  selectLod(camera_eye, threshold)
  ├── .far  → MergedMeshRenderer.record (1 drawIndexed)
  └── .near → Instanced.record path (M10 multi-draw indirect)

invalidate (I key / --anchorage-invalidate-after T):
  snapshotForMerge → worker.enqueue (dup-copy in)
                                  → mergeCluster (CPU bake, off-thread)
                                  → result enqueued
  worker.drain → Anchorage.applyMerge
              → vkDeviceWaitIdle
              → swap MergedMesh
```

Worker NEVER touches Vulkan — by contract, command-buffer recording
stays single-threaded on the main thread (see `Frame` in
`src/render/frame.zig`). Worker product is a CPU vertex/index slice
pair plus stats; main thread does the GPU upload.

## Diff metadata (load-bearing for the M27 re-gate)

The future re-gate against real assets MUST replay these conditions
to be meaningful:

| Field | Value |
|---|---|
| **Hardware** | RX 9070 XT (RDNA 4); dev box. NOT the RTX 4060 / RX 7600 cited in `pillar_harbor_raid_client_perf.md` — see `dev_machine_gpu.md`. Re-gate must either replay on a 4060-class card OR re-baseline against the same RX 9070 XT for a comparable diff. |
| **Driver** | Mesa RADV stack (Arch Linux Mesa version current as of 2026-05-12). `vulkaninfo` output worth capturing before any real-asset re-gate. |
| **Present mode** | `VK_PRESENT_MODE_MAILBOX_KHR` (`--uncap`). NOT FIFO — see `feedback_gpu_gate_uncap.md`. FIFO measures dropped-frame fraction, not workload. |
| **Warmup skip** | First 30 frames discarded by `FrameSoakStats.warmup_skip` for pipeline-cache warmup. |
| **Soak duration** | 10 s (samples ≈ 30 000 at unconstrained framerate). |
| **Window size** | Default 1280×720 (sandbox default). |
| **Scene config** | `--anchorage-pieces 500 --anchorage-piece-types 20 --anchorage-radius 50 --anchorage-lod-distance 100 --force-far --piece-types 20` — see `scripts/m11_gate_smoke.sh` for the canonical invocation. |
| **Piece geometry** | Procedural ±0.5 unit cube replicated across 20 palette slots (round-robin assignment). 24 verts / 36 indices per piece. Total merged: 12000 verts / 18000 idx. **This is the most important field for the M27 diff** — real glTF building pieces will be ~10-100× this vertex count, and that is exactly what M27 surfaces. |
| **Albedo** | Per-piece, baked per-vertex at merge time. No textures (none exist yet — KTX2 path is M14). |
| **Anchorage placement** | Single cluster at world (+120, ~2, 0); camera at ship origin (~0, ~5, 0). Cluster centroid ≈ 120 m from camera, bounding radius 52.3 m. `--force-far` overrides the LOD distance test so the merged path is always active. |
| **Auto-invalidate** | `--anchorage-invalidate-after 3` fires one mid-soak worker-driven re-merge at t=3 s, exercising the M11.3 off-thread path. |
| **RNG seed** | `0xA10C0A8E` for piece TRS — deterministic scene across runs. |

## Numbers — PASS at 500 × 20

Measured 2026-05-12, latest sandbox at commit `2d5d73b`.

| Gate clause | Threshold | Measured | Margin |
|---|---|---|---|
| Merge time | ≤ 100 ms | **max 2.33 ms** (init 2.77 ms; worker invalidate 2.11–1.99 ms across runs) | ~40× headroom on sync; worker comparable |
| Far-LOD draws per anchorage | ≤ ~1 | **1** (exactly one `vkCmdDrawIndexed`) | structural — `MergedMeshRenderer.record` always emits one |
| Avg frametime | ≤ 16.67 ms (60 fps) | **0.88–0.99 ms** | ~17× headroom |
| p99 frametime | ≤ 16.67 ms | **1.95 ms** | ~8× headroom |

Merge cost breakdown (sync path, 500 pieces, RDP RX 9070 XT):
- Vertex transform + albedo bake — dominates; ~12000 verts × (mat4·vec3 pos + mat3·vec3 normal + 3-float albedo memcpy).
- Index rebase — 18000 u16 → u32 add-and-store loop. Negligible.
- Bounding sphere (two passes: centroid then radius) — 12000 verts each. Negligible.
- Host-visible-coherent GPU upload — two `@memcpy` calls into mapped buffers. Buffer alloc dominates the wall-clock at this size (~ms).

Worker invalidate is the same workload off-thread plus a
`vkDeviceWaitIdle` + new-buffer alloc on the apply side. Roughly
comparable to sync within measurement noise — the win is hiding
the cost behind in-flight GPU work, not reducing the cost.

## Known gaps the M27 re-gate will surface

These are the predicted-but-unmeasured deltas. The whole point of
the synthetic baseline is to make the diff against M27 *useful* —
list the predictions now so the re-gate isn't a fishing expedition.

1. **Vertex count scaling.** Real anchorage pieces (wharf section,
   shed wall, plank stack) will hit 200-2000 verts each instead of
   24. Merge cost is linear in total verts — 500 pieces × 1000
   verts = 500 000 verts ≈ 40× the synthetic load. Expect merge
   to land near 80-100 ms — STILL inside the gate but margin shrinks
   from 40× to ~1×. The async worker becomes load-bearing rather
   than nice-to-have.

2. **GPU vertex memory.** 500 000 × 36 B = 18 MB per anchorage VBO.
   Multiple anchorages on screen at Phase 3 content scale would
   push this past device-local-via-staging being a meaningful win.
   Re-gate should measure host-visible-coherent vs device-local
   bandwidth under real geometry.

3. **Per-vertex albedo is a v0 hack.** With real materials (M14),
   the merged-mesh path needs either (a) bake material params per
   vertex (vertex count balloons further), (b) per-draw material
   binding (defeats single-draw), or (c) bindless materials
   indexed in the vertex stream. M27 chooses.

4. **Frustum culling at the anchorage level.** Single anchorage =
   single bounding sphere — host-side test is free. Multiple
   anchorages on screen at Phase 3 scale wants a GPU pass like
   M10.3 but at anchorage granularity. Out of scope here; future
   work.

5. **Far-LOD-only-1-draw clause is gameable.** Set `--force-far`
   → always one draw. Real LOD with hysteresis switches mid-frame
   as camera moves. M27 should add a "natural LOD" soak variant
   (no `--force-far`) to measure transition cost — Instanced
   `addInstance` / `destroy` on transition is a known small allocator
   churn point.

6. **`vkDeviceWaitIdle` on worker apply.** Invalidate-on-apply
   currently stalls the device. Fine for damage events at human
   rates (seconds apart). Phase 3 will surface whether scripted
   placement / Houdini-cooked re-meshes need the per-frame
   pending-destroy ring pattern instead. See `Anchorage.applyMerge`
   comment for the migration path.

## Reproduce

```
./scripts/m11_gate_smoke.sh                 # defaults: 500 × 20 × 50m × 10s soak
./scripts/m11_gate_smoke.sh 200 8 30 5      # smaller: 200 pieces × 8 types × 30 m × 5 s
```

Direct invocation (lets you skip the rebuild step):
```
./zig-out/bin/notatlas-sandbox \
  --uncap \
  --piece-types 20 \
  --anchorage-pieces 500 \
  --anchorage-piece-types 20 \
  --anchorage-radius 50 \
  --anchorage-lod-distance 100 \
  --anchorage-invalidate-after 3 \
  --force-far \
  --soak 10
```

Interactive (no soak, no exit-on-time):
```
./zig-out/bin/notatlas-sandbox --uncap --anchorage-pieces 100
# WASD to fly, L = toggle force-far, I = invalidate (re-cook)
```

## Phase 2 client-side arc

This closes M11. M10 (gpu-driven-instancing) is shipped, M11 is
shipped, M12 (animation-LOD) is the last synthetic milestone before
the Phase 2 → Phase 2.5 transition. M1.6 (synthetic harbor stress)
combines M10 + M11 + M12 outputs into the synthetic Phase 2 closer
and is the **last** synthetic baseline before the asset-pipeline
phase opens.

M27 (Phase 2.5 close) re-runs this gate harness with real assets.
**Don't lose this doc** — it's the zero-point for that diff.
