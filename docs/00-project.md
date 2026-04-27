# 00 — Project

## Goal

notatlas is a from-scratch clone targeting the 2018-2020 iteration of ATLAS
(Grapeshot Games / Studio Wildcard, Dec 2018 — mid 2020), with the hindsight
of what failed and a substantially better technical substrate.

## Why

Grapeshot abandoned Atlas after the 2020 Maelstrom update; the team was
redirected to ARK. The pirate-MMO design space remains open:

- Sea of Thieves is intentionally arcade, with no progression depth, no
  player building, no large-scale fleet combat.
- Skull and Bones launched in 2024 and flopped commercially.
- Atlas itself is in maintenance limbo with sub-1k concurrent players.

There is no successor project that targets Atlas's design — large-scale
seamless naval combat with deep crafting, ship building, and player-driven
territory.

The project is also a vehicle for the technical work the author has been
building toward across `fallen-runes`, `nats-zig`, and the `fornax-*` lower-
level projects: a Zig-based authoritative-server MMO architecture with NATS-
backed inter-service messaging.

## What it isn't

notatlas is not:

- A 1:1 fork of Atlas. Several headline Atlas systems are intentionally cut
  (the four-vitamin nutrition system, the discovery-points + power-stones
  leveling cap, the unrestricted-claim-flag land grab, the Empires/Colonies
  ruleset split). See [07-anti-patterns.md](07-anti-patterns.md).
- A solo dev's UE5 hobby project. notatlas is custom-engine, with the engine
  built incrementally from prior work.
- A Sea of Thieves competitor. Sea of Thieves is session-based arcade
  combat. notatlas is persistent-world (within wipe cycles) sandbox with deep
  crafting and player-built territory.
- A live ops AAA MMO. The team is small and the timeline is "done when it's
  done." Scope must be aggressive.

## Locked decisions (as of 2026-04-27)

- **Team:** small, solo on the engine work initially. More devs once the
  engine substrate is far enough along to absorb them.
- **Timeline:** quality over speed. No deadline.
- **Engine:** custom Zig engine. Substantial reuse of `~/Projects/fallen-
  runes` (ECS, networking, NATS infrastructure, Vulkan 3D renderer, Lua
  scripting, persistence). `~/Projects/nats-zig` provides the NATS client.
- **Art direction:** stylized where it makes sense. Pragmatic, not chasing
  photorealism.
- **PvP/PvE:** PvP-first with Last-Oasis-flavored protections (hibernation,
  scheduled raid windows). PvE servers possible later as a derivative
  ruleset.
- **World architecture:** keeps Atlas's seamless cross-cell ship handoff —
  but reimplemented on NATS + microservices, not UE4 dedicated servers
  stitched by Redis. See [02-architecture.md](02-architecture.md).
- **Wipe model:** scheduled seasonal wipes, ~10 weeks per cycle. See
  [06-design-caps.md](06-design-caps.md).

## Comparable projects (and why they don't address this space)

| Project | What it is | Why it's not a substitute |
|---|---|---|
| Atlas (Grapeshot) | The thing being cloned | Abandoned, dying, technical debt |
| Sea of Thieves (Rare) | Arcade pirate co-op | No progression, no building, small ships only |
| Skull and Bones (Ubisoft) | Naval combat MMO | Flopped, on-foot combat removed, low player count |
| ARK (Wildcard) | Survival MMO | Land-based, no naval, same engine as Atlas |
| Rust (Facepunch) | Survival shooter | Land-based, FPS focus, not naval |
| Last Oasis (Donkey Crew) | Walker-based PvP MMO | Walkers not ships; structural design influence on notatlas's hibernation |
| Star Citizen (CIG) | Space MMO | Space, not sea; perpetual development |
