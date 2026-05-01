---
name: fallen-runes engine substrate reference
description: ~/Projects/fallen-runes is the user's existing Zig MMO project. notatlas reuses much of its engine substrate. Quick reference for what's already built vs what notatlas will need to add.
type: reference
originSessionId: cb0aa047-d395-4803-bc6b-7df96341b031
---
`~/Projects/fallen-runes` is the user's other Zig MMO project — fantasy/RPG, top-down. notatlas reuses substantial parts of its engine.

**Already built in fallen-runes (likely reusable):**
- ECS (`src/shared/ecs/world.zig`, `systems.zig`) — entity management, components, movement, collision
- Networking — TCP framing, packet protocol (~5300 lines across 22 files), prediction/interpolation
- 3D Vulkan renderer — G-buffer, deferred lighting, shadow pass, glTF mesh loading, materials, PBR-ish, 3D camera
- 2D Vulkan renderer (probably not needed for notatlas)
- Authoritative server pattern (`src/server/server.zig` — ~2780 lines)
- Persistence — Postgres models (`src/shared/db/models.zig`), cross-session player state
- Lua scripting via comptime-generated Zig bindings, with HTML doc gen
- MMO microservice infra (Phase 7 work):
  - NATS subjects (`src/shared/nats/subjects.zig`)
  - NATS messages (`src/shared/nats/messages.zig`)
  - Gateway service (port 7780) — stateless client-facing
  - Auth service (port 7781) — login, JWT, accounts
  - Resilience: circuit breaker, request context with correlation+timeout, health monitoring
- Game systems likely partially reusable as patterns: gathering, loot, crafting, party (5-player), guild, trade (P2P), shop (NPC), travel/recall, ability bar, buffs/DoTs, chat (proximity), death penalty, AI state machine
- Test infrastructure — extensive coverage across all server systems
- `~/Projects/nats-zig` — their NATS client library

**What notatlas needs that fallen-runes doesn't have:**
- Ocean rendering (Gerstner → FFT)
- Water/buoyancy physics
- Wind field as game system
- Ship-as-vehicle / moving-platform physics with player coupling
- Naval combat damage model (plank HP, flooding, sinking)
- Multi-cell/grid spatial architecture (fallen-runes is single-server-authoritative)
- Cross-cell entity handoff via NATS interest management
- Scale beyond fallen-runes' likely target (party-of-5 dungeon vs. dozens-per-sea)

**Pattern references (when proposing notatlas systems):**
- For service decomposition: copy fallen-runes' gateway/auth split. notatlas probably needs additional services: cell-manager, ship-sim, env (wind/weather), persistence-writer.
- For NATS subject naming: read `src/shared/nats/subjects.zig` first.
- For network protocol: study fallen-runes' approach before designing notatlas's.
- For Phase planning: user numbers phases (1-7) and ships incrementally with tests. Match that style.
