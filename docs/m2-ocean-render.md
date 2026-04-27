# M2 — ocean-render

Per-milestone design doc for Phase 0 Milestone 2. Detailed design that
elaborates on [03-engine-subsystems.md §2](03-engine-subsystems.md) and
the M2 row in [04-roadmap.md](04-roadmap.md). Drafted 2026-04-27.

## 1. Goal

A beautiful raymarched ocean visible in a single-process sandbox at
≥ 150 fps (≤ 6.7 ms frame time) on the dev-box GPU (RX 9070 XT) at the
default 1280×720 — calibrated to back out to ≥ 60 fps on a 4060-class
card; see §10. Camera flies over the surface; foam appears at wave
crests; underwater fog when the camera submerges. Wave parameters and
shading parameters hot-reload from YAML.

This is the **first rendering work in notatlas** and the deferred layout
decision from M1 is now resolved (§2 below).

## 2. Decision: own renderer in notatlas, fallen-runes as reference

We do **not** take fallen-runes as a build dependency or vendor its
renderer subtree. fallen-runes is a different game (top-down with
sprites, tilemap, glTF asset pipeline) and its renderer carries features
notatlas doesn't need (HDR/bloom for that look, sprite batcher,
multi-tier shadow pass). Coupling two solo projects via a build edge
creates permanent coordination friction, and both codebases drift
anyway.

Instead: read fallen-runes' `src/client/renderer/` to learn how each
piece was solved, then reimplement in notatlas. `water_renderer.zig` in
particular is a near-perfect template for the ocean pass (UBO layout,
descriptor sets, pipeline creation, reflection render target).

## 3. API surface

Restated from [03-engine-subsystems.md §2](03-engine-subsystems.md):

```zig
pub const Ocean = struct { /* opaque to callers */ };

pub fn init(
    gpu: *GpuContext,
    wave_params: WaveParams,        // from M1's wave_query
    ocean_params: OceanParams,      // from data/ocean.yaml
    mesh_resolution: u32,           // grid tessellation, e.g. 256
) !*Ocean;

pub fn render(
    self: *Ocean,
    cmd: vk.CommandBuffer,
    camera: Camera,
    time: f32,
) void;

pub fn paramsSet(self: *Ocean, ocean_params: OceanParams) void;
pub fn waveParamsSet(self: *Ocean, wave_params: WaveParams) void;

pub fn deinit(self: *Ocean) void;
```

`paramsSet` and `waveParamsSet` are the hot-reload entry points; both
are non-blocking (write to next-frame UBOs).

## 4. Module layout in notatlas

New under `src/render/`:

```
src/render/
├── render.zig          ── public surface; re-exports
├── gpu.zig             ── GpuContext: instance/device/queues/VMA
├── window.zig          ── zglfw wrapper; surface creation
├── swapchain.zig       ── images, framebuffers, acquire/present
├── frame.zig           ── per-frame command buffer + sync primitives
├── pipeline.zig        ── pipeline + render-pass helpers
├── shader.zig          ── SPIR-V load + glslc subprocess for hot-reload
├── camera.zig          ── view/proj matrices + UBO
├── mesh.zig            ── vertex/index buffer + plane generator
└── ocean.zig           ── the ocean pass; consumes wave_query
```

Shaders under `assets/shaders/`:

```
assets/shaders/
├── ocean.vert          ── Gerstner displacement (mirrors src/wave_query.zig)
└── ocean.frag          ── water shading + foam + fog
```

`assets/shaders/` is watched by the hot-reload loop in dev builds.

## 5. Sub-milestones

Sequenced for fastest-time-to-pixels. Each step is a working program;
the next builds on it.

| Step | Deliverable | Reference in fallen-runes |
|---|---|---|
| **M2.1** | Window + Vulkan instance/device/queue, validation layers in Debug, prints capabilities | `vulkan_context.zig` |
| **M2.2** | Swapchain, frame loop, clear-to-color (animated). First pixels on screen. | `swapchain.zig`, `commands.zig` |
| **M2.3** | Tessellated plane mesh + camera UBO + minimal pipeline; flat plane visible from a flying camera. | `mesh.zig`, `camera_3d.zig`, `pipeline.zig` |
| **M2.4** | Vertex-shader Gerstner: GLSL port of `waveDisplacement`; wave UBO populated from `data/waves/*.yaml` (M1 loader). Surface waves now. | `water_renderer.zig` |
| **M2.5** | Fragment shading: water albedo/scatter, foam at crests using analytic curvature from `waveNormal`, underwater fog when camera y < 0. | `water_renderer.zig` shaders |
| **M2.6** | Hot-reload: file-watch `data/ocean.yaml`, `data/waves/*.yaml`, `assets/shaders/*`. glslc subprocess → SPIR-V → recreate pipeline. | new — fallen-runes precompiles SPIR-V at build time |
| **M2.7** | Perf gate: ≥ 150 fps on RX 9070 XT at 1280×720 sandbox flythrough (proxy for ≥ 60 fps on 4060-class — see §10); RenderDoc capture confirms no obvious waste; raymarch step count tuned. | — |

M2.1-M2.3 is mostly Vulkan boilerplate (the slog). M2.4 is where the
ocean appears. M2.6 is what makes the rest of Phase 0 fast — every
subsequent milestone benefits from instant param iteration.

## 6. Data: `data/ocean.yaml`

```yaml
mesh:
  resolution: 256        # vertices per side of the plane
  size_m: 1024.0         # plane edge length in world meters
  tile_pattern: radial   # radial | grid; radial = denser near camera

shading:
  shallow_color: [0.10, 0.45, 0.55]
  deep_color:    [0.02, 0.08, 0.18]
  scatter:       0.25     # subsurface scatter fudge for shallow waves
  fresnel_pow:   5.0
  sun_specular:  64.0

foam:
  crest_curvature_threshold: 0.6   # |∂η/∂x|+|∂η/∂z|; above this = crest
  crest_width: 0.15
  shoreline_falloff_m: 4.0         # later milestone; placeholder

underwater:
  fog_color:    [0.05, 0.18, 0.22]
  fog_density:  0.08               # exponential fog coefficient
```

Wave parameters live in their own files (`data/waves/{calm,choppy,storm}.yaml`)
and are loaded by M1's `yaml_loader.zig`. The active wave config is a
sandbox-time selection for M2; in the real game it's published per cell
by env service (out of scope here).

## 7. External dependencies to add

To `build.zig.zon`:

| Package | Purpose | 0.15.2 status |
|---|---|---|
| `zglfw` | Window + input | check tag; expect to vendor if no 0.15 release |
| `vulkan-headers` | Vulkan API definitions | usually fine |
| `vma-zig` | GPU memory pooling (VMA) | check; fallen-runes uses it |
| (math) | Vec3/Mat4 + SIMD | start with stdlib + `src/wave_query.zig` types; add `zmath` only if profiling demands |

Verify each dep has a 0.15-compatible tag before adding (many Zig
libs have HEAD on 0.16-dev with no 0.15 release tag). Pin commits.

`glslc` is a build-time tool (system binary), not a Zig dep. Document it
in the README's prereqs.

## 8. Risks

| Risk | Mitigation |
|---|---|
| Vulkan boilerplate scope-creeps; M2.1-M2.3 eats weeks | Time-box: if M2.3 isn't done in 2 weeks, simplify (skip VMA, use one queue, single-frame-in-flight). |
| Vertex Gerstner output diverges from CPU `waveHeight` | Port `waveDisplacement` line-for-line from `src/wave_query.zig` into GLSL; add a debug toggle that samples the surface at known `(x,z,t)` and asserts within float epsilon. |
| Driver bugs / validation-layer warnings drown the loop | Run with validation layers in Debug always; treat any warning as a hard fail. Dev-box validation runs on AMD/RADV; cross-vendor check on a 4060-class NVIDIA card before declaring M2 done. |
| Hot-reload via `glslc` subprocess is slow on Linux | Acceptable. Reload latency budget: <500 ms from save to pipeline swap. If it exceeds that, switch to in-process `shaderc` later. |
| Mesh resolution choice locks a perf cliff | Surface is now a raymarched fragment shader (no mesh post-M2.5); the equivalent perf knob is `iterations` (waves) and raymarch step count in `water.frag`. Both data-driven; tune at M2.7. |

## 9. Out of scope for M2

- **FFT ocean.** Tessendorf upgrade is a v2 (post-Phase-0) task. Gerstner only.
- **Ship rendering.** No hulls, no sails, no glTF. Just the water.
- **Networking.** Single-process sandbox. No NATS, no gateway.
- **Buoyancy.** That's M3. M2 doesn't apply force to anything; it just
  draws the surface.
- **Sun/sky/clouds.** A directional light and a flat sky color are
  enough. Skybox/atmosphere is post-Phase-0 polish.
- **Anti-aliasing pass, post-processing, HDR/bloom.** Defer until a
  reason exists.

## 10. Gate

Restated from [04-roadmap.md](04-roadmap.md), with the perf bar
re-expressed against the dev box (see calibration below):

> Beautiful raymarched ocean visible in sandbox at ≥ 150 fps
> (≤ 6.7 ms frame time) on RX 9070 XT at 1280×720. Camera flyover;
> no z-fighting; foam at wave crests; underwater fog when camera
> submerges.

Plus from [03-engine-subsystems.md §2](03-engine-subsystems.md): the
hot-reload requirement (`paramsSet` and shader watch) must work end to
end.

### 10.1 Perf calibration: 9070 XT → 4060-class

The original gate ("60 fps on RTX 4060") was written before the dev box
landed as an RX 9070 XT. The 9070 XT is roughly 2.5× a 4060 in real-
world raster benchmarks at 1080p, and closer to ~3× on
fragment-ALU-heavy workloads (which a raymarcher is). To keep the
intent — "any mid-range card from 4060 onwards holds 60 fps" — we
calibrate at a conservative ratio of **2.5×**:

  4060 deadline = 16.67 ms (60 fps)
  ratio assumed  = 2.5
  9070 XT bar    = 16.67 / 2.5 ≈ 6.7 ms (≥ 150 fps)

If the dev box clears 150 fps with headroom (≥ 180 fps), a 4060 will
clear 60 fps comfortably under the assumed ratio. **The bar is a proxy,
not a substitute** — real cross-vendor validation requires running on
a 4060-class card before declaring M2 fully shipped (see §8 Risks).

If the workload turns out to be bandwidth-bound rather than ALU-bound
(unlikely for this raymarcher; 9070 XT has 644 GB/s vs 4060's 272 GB/s,
ratio ≈ 2.4×), the calibration still holds.

### 10.2 Acceptance walkthrough

Concretely M2 is done when, in a single 5-minute session on the dev
box, you can:

1. Launch the sandbox; frame time ≤ 6.7 ms (≥ 150 fps).
2. Edit `data/ocean.yaml` (e.g. change `deep_color` or `fog_density`);
   see the change in the running window without restarting.
3. Edit `data/waves/storm.yaml` (e.g. raise an amplitude); see the
   surface react.
4. Edit `assets/shaders/water.frag` (e.g. tweak Schlick fresnel); see
   the change without restarting.
5. Fly the camera through the surface; underwater fog kicks in below
   the waterline; resurface; spec/foam visible at crests.
6. RenderDoc capture: no validation warnings, sane draw count
   (= 1 fullscreen triangle), frame time stable.
