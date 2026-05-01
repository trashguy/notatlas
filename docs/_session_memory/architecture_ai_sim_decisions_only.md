---
name: ai-sim is decisions only — ship-sim does physics
description: Locked 2026-04-30. AI ships are physically just ships in ship-sim's 60Hz rigid-body table; ai-sim runs the 20Hz behavior loop and emits `sim.entity.<ai_ship_id>.input` indistinguishable from a player's gateway input. ship-sim doesn't know or care whether an input came from a player or an AI.
type: project
originSessionId: 1db61b4b-4308-48b3-88c8-aea4bd15b6a5
---
When the `ai-sim` service ships, the decomposition is:

**ship-sim (60 Hz, existing):** owns rigid-body physics for ALL ships (player + AI + NPC). Per docs/08 §2A — "all 60 Hz rigid-body authority". An AI ship is just an ordinary entity in `state.entities` with the EntityKind.ship top-byte tag. ship-sim has no AI-specific code path — it consumes `sim.entity.<id>.input` and applies thrust / steer / fire identically regardless of source.

**ai-sim (20 Hz, new):** owns *decisions only*. Tick loop:
  1. Subscribe to spatial-index radius queries (or `sim.entity.*.state` directly) to know where targets are.
  2. Run behavior tree / FSM per AI entity it owns.
  3. Publish `sim.entity.<ai_ship_id>.input` with thrust/steer/fire as if it were a player's gateway sending TCP→NATS.

**Why:** Splitting physics across two services would mean a NATS round-trip in the middle of every physics tick — the same anti-pattern that motivated docs/08 §2A.5's "no separate player-sim service" rejection. Co-locating physics keeps ship-sim's tick deterministic; AI gets the leverage of running at a slower rate without dragging physics fidelity down.

**How to apply:**
- AI ship spawn: same path as player-controlled ships. ship-sim's existing `--ships N` flag just spawns more ships; ai-sim picks up a subset by id and drives them.
- AI difficulty / behavior live in `data/ai/*.yaml` (data-driven principle).
- Spatial awareness uses `idx.spatial.query.radius` (already shipped) — ai-sim is the first real consumer.
- Cannon fire: same FireMsg path as player ships. AI just sets `InputMsg.fire = true` when in range + cooldown ready.
- Damage / sinking: future increment, separate from AI-control. Damage state lives at ship-sim per docs/02 service-mesh row ("hull/sail/cannon/damage state").

**Update 2026-04-30:** Full service design ratified in `docs/09-ai-sim.md`. BT runtime in Zig (six node types: selector, sequence, parallel, inverter, cooldown, repeat) with leaves in Lua and tree shape in YAML. Read 09 before implementing.
