# notatlas — Claude project notes

## Project status

Pre-Phase-0. Repo is greenfield; no engine code yet. Planning and
architecture front is closed; design memos and architecture decisions
are documented under `docs/`.

Substrate engine work happens in `~/Projects/fallen-runes` (sibling
project). NATS client is `~/Projects/nats-zig`.

## Read order for orientation

1. `docs/README.md` — index
2. `docs/00-project.md` — project goal
3. `docs/01-pillars.md` — design pillars
4. `docs/02-architecture.md` — locked architecture (10 decisions, service
   mesh, NATS subject scheme)
5. `docs/03-engine-subsystems.md` — engine work to do, dependency-ordered
6. `docs/04-roadmap.md` — phased plan with stress-test gates

## Locked decisions reference

- 60Hz auth tick (player + ship-sim); 20Hz AI; 5Hz env
- Hybrid determinism (waves + projectile arcs deterministic; rest auth+interp)
- Jolt Physics via Zig FFI for rigid body
- NATS B+D hybrid subject scheme: `sim.entity.<id>.*` for mobile
  entities; `env.cell.<x>_<y>.*` for static state
- Spatial index: single service, sharded-ready
- Mixed persistence: pose never persisted, inventory JSONB, market
  relational, events JetStream-KV with TTL
- Hibernation: at-sea always raidable; anchored = protected during
  raid windows
- Pose compression ~16 B/pose (quantized pos + smallest-three quat +
  delta + cell-id)
- 4-tier replication system (always / visual / close-combat / boarded)
- LiveKit WebRTC SFU for voice (off the gameplay path)
- Wipe cycles every 10 weeks
- Disciplines: Sailing, Combat, Survival, Crafting, ?Captaineering
- Ship tiers v1: Sloop, Schooner, Brigantine
- Resource families: ~15 (Atlas count)
- Players per cell target: 200
- Structures per anchorage cap: 500

## Engineering principles

- Data-driven for content / balance / config (TOML + Lua), code for
  systems. See `docs/05-data-model.md`.
- Service decomposition: 8 services. gateway + auth from fallen-runes;
  ship-sim, cell-mgr, spatial-index, env, persistence-writer, voice-sfu
  added.
- Stress-test gates between phases. Atlas's terminal mistake was
  shipping content on top of architecture that hadn't been proven at
  scale.

## When working on this project

- Don't propose UE5 / Godot / Bevy / Unity — engine is committed.
- Don't relitigate the 10 architecture decisions in
  `docs/02-architecture.md`. They're locked unless the user explicitly
  reopens.
- Reference fallen-runes patterns (`~/Projects/fallen-runes/CLAUDE.md`)
  before writing new infrastructure. Most NATS / persistence / service
  patterns already exist there.
- Naval combat at scale is *the* selling point. If a proposal can't
  scale to 200+ players in one engagement, redesign.
- Harbor raids must hold 60fps. GPU-driven instancing + structure caps
  are the levers.
- Atlas anti-patterns checklist is `docs/07-anti-patterns.md`. Apply
  it.

## Known gaps in docs

- Engine subsystems doc has API surfaces sketched, not fully specced.
  Each subsystem will need a detailed design doc when it's its turn to
  build.
- Database schema not yet written. Will be drafted alongside the
  persistence-writer service.
- No code yet.
