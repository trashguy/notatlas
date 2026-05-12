# M10 gpu-driven-instancing — synthetic baseline (retrospective)

**Date:** 2026-05-12 (retrospective; M10 originally shipped earlier
in the day across `15ec0cd` / `f22d262` / `0e717aa` / `5bf5712`).
**Status:** PASS. Re-verified against the current sandbox the same
day — numbers identical to the M10.3 ship-out.

This is the **synthetic** baseline. Per
`feedback_synthetic_baseline_then_diff.md`, M27 (Phase 2.5) re-runs
this harness against real glTF + KTX2 + rigs and diffs against the
numbers below. M10 was the first Phase-2 client gate to ship; the
synthetic-baseline-then-diff discipline was formalized after M10
landed, so this doc is retrospective. The numbers and diff metadata
below match the state of the engine at HEAD; treat as zero-point
for the M27 re-gate.

## Gate

> ≤ 20 piece-type buckets renderable at once; 5000 static instance
> grid holds 60 fps. Single multi-draw indirect dispatches the
> whole pass regardless of piece-type count.

Closes the Phase 1 → Phase 2 transition path for the
gpu-driven-instancing subsystem. Upstream dependency: the pre-M10
per-piece `Box` draw path (still in `src/render/box.zig` for its
mesh-data constants). Downstream: M11 (structure-lod-merge) consumes
the SSBO layout + `prepareFrame`/`record` split; M12 (animation-LOD)
writes per-instance anim params into the same SSBO via
`Instanced.setAnimParams`.

## Architecture under test

```
CPU side                                    GPU side
────────                                    ────────
spawn N×N grid (default 71×71 = 5041 cubes)
  → instanced.addInstance × N²              instance SSBO (112 B / row)
    .model: mat4
    .albedo: vec4
    .bounds: vec4 (piece-local center + radius)
    .meta: uvec4 (x=piece_id; y/z used by M12 for anim params)

each frame:
  instanced.prepareFrame()                  →   bucket-scatter +
    1. bucket instances by piece_id              indirect-cmd upload
    2. write VkDrawIndexedIndirectCommand[K]
       (K = non-empty piece buckets)
    3. CPU upload SSBO + indirect buffer to host-visible memory
    4. (runs BEFORE frame.draw — overlaps with previous frame's
       GPU work, before the next-frame fence wait)

  frame.draw(..., prePass: dispatchCull):
    pre-pass (outside render pass):         compute (workgroup 64)
      dispatchCull:                           per-thread: read instance i,
        push-const: 6 frustum planes +          transform sphere bounds
                    total_active_count          by model matrix, test
                                                vs 6 planes, on visible:
                                                  atomicAdd(indirect[piece_id].instance_count)
                                                  visible[bucket_offset++] = i
        memory barrier: COMPUTE → DRAW_INDIRECT | VERTEX_SHADER
                        (instance_count + visible_indices)

    inside render pass:
      instanced.record:                     instanced.vert:
        vkCmdBindPipeline                     uint orig = visible[gl_InstanceIndex]
        vkCmdBindDescriptorSets                Instance i = instances[orig]
        vkCmdDrawIndexedIndirect               (M12 amp != 0 → vertex bobble)
          (one call, K buckets via            wp = i.model * pos
           multiDrawIndirect feature)         gl_Position = cam.proj * cam.view * wp
```

Three load-bearing primitives shipped together:

- **MeshPalette**: shared vertex/index buffers packing N piece
  meshes. `addInstance(piece_id, …)` looks up the palette entry's
  geometry slice; no per-piece vbo/ibo. The K ≤ 20 gate caps the
  number of distinct piece geometries on screen, not instance
  count.

- **Instanced SSBO**: per-instance `{mat4 model, vec4 albedo,
  vec4 bounds, uvec4 meta}` rows. `meta.x` = piece_id (compute
  cull reads); `meta.y/z` were unused at M10 time, claimed by
  M12 for anim phase/amplitude.

- **prepareFrame / record split**: CPU bucket-scatter runs
  OUTSIDE the render pass. Two reasons: (1) compute cull must
  dispatch outside any render pass; (2) bucket-scatter runs in
  parallel with the previous frame's GPU work, halving baseline
  CPU cost (see "Side win" below).

## Diff metadata (load-bearing for the M27 re-gate)

| Field | Value |
|---|---|
| **Hardware** | RX 9070 XT (RDNA 4); dev box. NOT the RTX 4060 / RX 7600 cited in `pillar_harbor_raid_client_perf.md` — see `dev_machine_gpu.md`. Re-gate must either replay on a 4060-class card OR re-baseline against the same RX 9070 XT for a comparable diff. |
| **Driver** | Mesa RADV stack (Arch Linux Mesa version current as of 2026-05-12). Capture `vulkaninfo` before any real-asset re-gate. |
| **Present mode** | `VK_PRESENT_MODE_MAILBOX_KHR` (`--uncap`). NOT FIFO — see `feedback_gpu_gate_uncap.md`. M10 was the milestone that surfaced the FIFO/MAILBOX trap; the lesson is in the feedback memory. |
| **Warmup skip** | First 30 frames discarded by `FrameSoakStats.warmup_skip` for pipeline-cache warmup. |
| **Soak duration** | 10 s (samples ≈ 12 000 at unconstrained framerate). |
| **Window size** | Default 1280×720 (sandbox default). |
| **Scene config** | `--uncap --instance-grid 71 --piece-types 20 --soak 10`. 71 × 71 = 5041 grid instances + 4 dynamic (ship + 3 pax) = 5045 total active. See `scripts/m10_gate_smoke.sh` for the canonical invocation. |
| **Piece geometry** | Procedural ±0.5 unit cube replicated across 20 palette slots. 24 verts / 36 indices per piece. The SAME procedural geometry M11 and M12 ride on; their findings docs share this content-shape baseline. **The most important field for the M27 diff** — real piece meshes are ~200-2000 verts each, which is exactly what the re-gate surfaces. |
| **Albedo** | Per-instance vec3 (alpha-padded). No textures (none exist yet — KTX2 path is M14). |
| **Cull config** | GPU compute frustum cull (M10.3) ON by default. `--no-cull` flag toggles for A/B. Cull dispatch: workgroup-64 compute, 6 frustum planes via Gribb/Hartmann extraction in Vulkan z∈[0,1] form, 100 B push constant (6 planes + total_active). |
| **Multi-draw indirect** | `multiDrawIndirect` + `drawIndirectFirstInstance` enabled as VkPhysicalDeviceFeatures at device creation. Both are core-1.0 optional features; widely supported. |
| **Indirect buffer flags** | Host-visible + STORAGE_BUFFER_BIT (compute atomicAdds into `instance_count`). |
| **RNG seed** | Grid placement is deterministic (no RNG); per-instance pieces are round-robin `spawn_idx % piece_types`. Reproducible across runs. |

## Numbers — PASS at 5045 × 20

Measured 2026-05-12 (commit `1edc741` HEAD; identical to M10.3
ship-out at `5bf5712`).

| Gate clause | Threshold | Measured (cull ON) | Measured (cull OFF) |
|---|---|---|---|
| Piece-type bucket count | ≤ 20 | 20 (saturated by `--piece-types`) | 20 |
| API draw calls per frame | structural target ≤ 1 | **1** (`vkCmdDrawIndexedIndirect` × 1) | **1** |
| Avg frametime | ≤ 16.67 ms (60 fps) | **0.838 ms** (~1193 fps) | **0.830 ms** (~1205 fps) |
| p99 frametime | ≤ 16.67 ms | **1.85 ms** | **1.85 ms** |
| max frametime | — | 4.85 ms | 4.66 ms |

**~20× headroom** on the 16.67 ms 60-fps budget for the cubes-only
synthetic scene.

### Cull's measurable contribution (A/B)

At unit-cube geometry the compute cull's rasterizer savings wash
with the compute dispatch cost — frametime difference is within
measurement noise. The primitive earns its keep at:

- M11's higher-poly piece geometry (anchorage merge re-uses the
  same cull primitive at near-LOD when 70%+ of pieces are
  off-screen);
- M27's real glTF pieces (200-2000 verts each — 8-80× the
  rasterizer load per visible instance);
- Multiple-anchorage scenes where the camera frustum excludes
  most of the world.

The cull was kept ON by default at M10.3 ship-out specifically
because M11/M12 needed the SSBO + visible-indices indirection in
place, not because M10's gate required it. The cull dispatch is
load-bearing infrastructure for M11+, not a perf win at M10's
content shape.

### M10.3 side win: prepareFrame split halved CPU baseline

Pre-M10.3 the bucket-scatter ran inside `Instanced.record`, between
`vkBeginRenderPass` and `vkCmdDrawIndexedIndirect`. Pulling it out
(needed anyway for compute dispatch placement) let it run in
parallel with the previous frame's GPU draw, dropping the M10.4
gate-harness baseline from **1.930 ms → 0.832 ms avg** (cull OFF;
cull ON adds zero overhead on top because the dispatch cost is
covered by GPU idle slack). This was unexpected; documented in
the M10.3 commit body.

## Known gaps the M27 re-gate will surface

1. **Vertex count is 24/piece.** Real piece meshes will be
   200-2000 verts each. Per-frame vertex-fetch cost is linear —
   expect frametime to grow ~10-80× on the per-piece geometry
   axis alone. At 5045 instances × 1000 verts = 5M verts/frame,
   GPU vertex stage becomes the bottleneck, not bucket scatter.

2. **Index buffer is 36 indices/piece.** Real meshes have far
   higher index density and varied triangle strip continuity;
   GPU triangle setup cost was negligible in the synthetic and
   will be meaningful at real-content scale.

3. **No materials, no textures.** Per-instance vec3 albedo only.
   Real PBR materials (M14 KTX2 + descriptor-set binding model)
   will add per-bucket descriptor binds, breaking the "1 draw call
   regardless of piece count" property — re-gate must measure the
   draw-call count post-material-binding.

4. **No descriptor-array indirection for textures.** When M14
   lands KTX2 + bindless textures, instance.meta gains a
   texture_id field and the vertex shader reads from a global
   texture array. The current SSBO layout reserves `meta.w` for
   this; the structure is ready, the path isn't built.

5. **Cull at piece-radius granularity.** Sphere bounds are
   conservative — real anchorage / ship meshes have non-spherical
   shapes (long hulls, tall masts). Sphere cull misses early-exits
   that an AABB or oriented-bounding-box test would catch. Worth
   measuring at M27 whether the conservative cull leaves enough
   draws on the table to justify a tighter primitive.

6. **No GPU-side LOD select at the instance level.** Instance
   selection is binary (drawn / culled). Real systems pick LOD per
   instance via screen-coverage thresholds. M11 does this at the
   anchorage-cluster level; M27 should add it at the per-instance
   level if real ship + character geometry surfaces the need.

7. **`--piece-types 20` is the round-robin ceiling.** Real harbor
   scenes likely run 30-100 distinct piece types. The 20-bucket
   gate was chosen as a v0 design cap; M27 should re-validate
   whether 20 is the actual content limit or whether the engine
   needs higher (memory cost is N × VkDrawIndexedIndirectCommand
   = N × 20 B, trivial; bucket-scatter is O(instances), not
   O(buckets)).

8. **Single descriptor set serves both graphics + compute.** Works
   today via `stageFlags = VERTEX | COMPUTE` on the layout
   bindings. M14+ may want graphics + compute on separate sets if
   bind-call frequency matters; not a constraint yet.

## Reproduce

```
./scripts/m10_gate_smoke.sh                  # defaults: 71×71×20 × 10 s
./scripts/m10_gate_smoke.sh 100 20 5         # bigger: 10000 instances × 5 s
./scripts/m10_gate_smoke.sh 71 20 30         # longer soak
```

Direct invocation (skip the rebuild step):
```
./zig-out/bin/notatlas-sandbox \
  --uncap \
  --instance-grid 71 \
  --piece-types 20 \
  --soak 10
```

Cull A/B:
```
./zig-out/bin/notatlas-sandbox --uncap --instance-grid 71 --piece-types 20 --soak 10            # cull ON  (default)
./zig-out/bin/notatlas-sandbox --uncap --instance-grid 71 --piece-types 20 --no-cull --soak 10  # cull OFF
```

Interactive (no soak):
```
./zig-out/bin/notatlas-sandbox --uncap --instance-grid 71 --piece-types 20
# WASD to fly around the grid; visual no-op vs cull-off (same scene).
```

## Phase 2 client-side arc context

M10 was the foundation milestone for the Phase 2 client arc. Every
downstream synthetic milestone rides on its infrastructure:

- **M11** (structure-lod-merge) — uses `Instanced.addInstance` /
  `destroyInstances` on near-LOD transitions; reads piece geometry
  out of `MeshPalette` for the merge-time vertex bake.
- **M12** (animation-LOD) — claims `instance.meta.y/z` for per-
  instance anim phase/amplitude via `Instanced.setAnimParams`;
  rides the same vertex shader + cull path. Vertex-shader bobble
  uses `cam.eye.w` as time (claimed from unused padding at M12 time).
- **M1.6** (synthetic harbor stress) — combines all three with the
  M10 path as the substrate; 2735 Instanced slots active, single
  multi-draw indirect.

M27 (Phase 2.5 close) re-runs M10 alongside M11 + M12 + M1.6
against real assets. **Don't lose this doc** — it's the zero-point
for the M10 component of that diff.

## Cross-references

- `docs/research/m11_structure_lod_merge_synthetic.md` — M11 baseline; shares the cube-geometry content shape.
- `docs/research/m12_animation_lod_synthetic.md` — M12 baseline; claims `meta.y/z` + `cam.eye.w` from M10's reserved fields.
- `docs/research/m1_6_synthetic_harbor_stress_synthetic.md` — Phase 2 closer; composes M10 + M11 + M12 + disposable particle stub.
- `feedback_synthetic_baseline_then_diff.md` — discipline that mandates these findings docs.
- `feedback_gpu_gate_uncap.md` — MAILBOX-vs-FIFO lesson surfaced during M10.
