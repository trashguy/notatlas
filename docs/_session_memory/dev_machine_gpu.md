---
name: dev machine GPU + Vulkan stack
description: Dev box is AMD RX 9070 XT (RADV/Mesa). M2.7 gate has been reconciled to the dev box (see body); other perf gates still reference RTX 4060 and will need reconciling when reached.
type: project
originSessionId: 9014770d-bef4-482b-9b2d-e54d460b2ec1
---
**GPU (2026-04 sandbox):** AMD Radeon RX 9070 XT (GFX1201), driver
RADV/Mesa 26.0.5, Vulkan 1.4.335 reported.

**M2.7 gate (reconciled 2026-04-27):** The M2.7 gate has been rewritten
in `docs/m2-ocean-render.md` §10 + §10.1 from "60 fps on RTX 4060" to
"≥ 150 fps (≤ 6.7 ms) on RX 9070 XT at 1280×720", calibrated at a
conservative 2.5× perf ratio so the dev-box bar back-projects to ≥ 60
fps on a 4060-class card. `docs/03-engine-subsystems.md` M2 row
restates the same. Real cross-vendor validation on a 4060-class NVIDIA
card is still required before declaring M2 fully shipped — the
calibration is a proxy, not a substitute. Other gates that still cite
RTX 4060 (M10 gpu-driven-instancing, Phase-2 harbor scene, M12
animation-lod) are different workloads (instancing/animation, not
fragment-ALU) and need their own reconciliation when those milestones
land — don't assume the same 2.5× ratio carries over.

**Mesa note:** RADV currently warns on every run for GFX1201 ("not a
conformant Vulkan implementation, testing use only") — RX 9070 XT is
new enough that conformance tests haven't been run. Ignore the warning.

**Validation layers:** not installed by default on Arch. Install with
`sudo pacman -S vulkan-validation-layers` to enable
`VK_LAYER_KHRONOS_validation`. The sandbox detects absence and falls
back gracefully with a `[warn]` line.

**glslc:** present (system `shaderc` package). Needed at M2.6.
