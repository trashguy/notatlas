# notatlas — design and architecture docs

Planning artifacts for notatlas, a from-scratch clone of the 2018-2020 era of
Atlas (Grapeshot Games' pirate MMO). Reading order:

| # | Document | What it answers |
|---|---|---|
| 00 | [project.md](00-project.md) | What notatlas is, who it's for, what it isn't |
| 01 | [pillars.md](01-pillars.md) | The six design pillars in priority order |
| 02 | [architecture.md](02-architecture.md) | The ten locked architectural decisions + service mesh |
| 03 | [engine-subsystems.md](03-engine-subsystems.md) | Engine work to add to the Zig + fallen-runes substrate |
| 04 | [roadmap.md](04-roadmap.md) | Phased delivery plan with stress-test gates |
| 05 | [data-model.md](05-data-model.md) | Data-driven principle and where each kind of content lives |
| 06 | [design-caps.md](06-design-caps.md) | First-pass content caps (data-driven, adjustable) |
| 07 | [anti-patterns.md](07-anti-patterns.md) | Atlas mistakes to NOT replicate |
| R1 | [research/atlas-features.md](research/atlas-features.md) | Consolidated feature research |
| R2 | [research/atlas-postmortem.md](research/atlas-postmortem.md) | Why Atlas failed (lessons learned) |
| R3 | [research/atlas-server-tech.md](research/atlas-server-tech.md) | Original Atlas server architecture for reference |

## TL;DR for someone new to the project

notatlas is a pirate MMO in the spirit of 2018-2020 Atlas, built on a custom Zig
engine that reuses substantial parts of `~/Projects/fallen-runes` (ECS,
networking, NATS infrastructure, gateway/auth services, Vulkan 3D renderer).

Atlas's design space remains underserved — Sea of Thieves is too arcade,
Skull and Bones flopped, and Atlas itself was abandoned by Grapeshot. The
opportunity is to build the same vision but with the lessons from Atlas's
failures applied and a substantially better technical substrate.

The headline differentiators are:

1. **Smooth naval combat at scale** (200+ players in one engagement)
2. **Harbor raids that don't tank FPS** (custom GPU-driven Vulkan renderer)
3. **Deep crafting with global resource sourcing** (the actual progression loop)

The headline technical innovation is replacing Atlas's UE4-dedicated-server-
per-cell + Redis-coordinated stutter handoff with an HFT-style per-entity
NATS subject mesh + spatial index, where cells are interest managers rather
than state owners.

## Status

As of 2026-04-27: design and architecture front is closed (ratified). Next
deliverable is Phase 0 work — the engine water lift (Gerstner ocean + wave
query + buoyancy + ship-as-vehicle in the sandbox). See
[roadmap.md](04-roadmap.md).
