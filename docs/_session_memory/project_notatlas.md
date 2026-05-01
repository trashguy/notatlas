---
name: notatlas project goal
description: Clone of Atlas (2018-2020). Built on the user's custom Zig engine, using fallen-runes as substrate (ECS, NATS microservices, gateway/auth, 3D Vulkan renderer). Small team, no deadline, stylized, PvP-first. Keeps Atlas-style seamless grid handoff but reimplemented on NATS + HFT-grade networking — not UE4 dedicated servers stitched by Redis.
type: project
originSessionId: cb0aa047-d395-4803-bc6b-7df96341b031
---
notatlas is a from-scratch clone of ATLAS (Grapeshot, Dec 2018 - mid 2020). Pre-Maelstrom-update mechanics with the lessons-learned filter applied.

**Why:** Original was abandoned. Sea of Thieves too arcade, Skull and Bones flopped, design space open.

**Locked decisions (2026-04-27):**
- **Team:** small, solo on engine work initially, more devs later.
- **Timeline:** "done when it's done."
- **Engine:** user's custom Zig engine. Substantial reuse from sibling project `~/Projects/fallen-runes` (ECS, networking, NATS infra, gateway/auth services, Vulkan 3D renderer, Lua scripting, persistence). Sibling `~/Projects/nats-zig` is their NATS client.
- **Art:** stylized where it makes sense.
- **PvP/PvE:** PvP-first with Last Oasis-flavored protections (hibernation, scheduled vulnerability windows) on top of Atlas's structural model.
- **World architecture:** **keep Atlas's seamless grid handoff** — but reimplemented on NATS + microservices, not UE4 dedicated servers + Redis. User's day job is HFT/big data; they have stronger primitives for distributed real-time state than Grapeshot used. Grid stutter / ship-eating handoff bugs are not architectural; they're implementation. notatlas should solve them.

**How to apply:**
- Don't pitch UE/Godot/Bevy/Unity — engine is committed.
- The previous "Last Oasis sectors instead of grid" framing is **superseded**. Grid handoff is back; only behavioral protections (hibernation/raid windows) carry over from Last Oasis.
- Reference fallen-runes' patterns when proposing services — they likely already have NATS subject conventions, gateway routing, circuit breakers (`src/shared/resilience/`), DB models, etc. Don't reinvent.
- "Engine lift" is specifically the **naval/water/ocean** layer. The user has never done water rendering or buoyancy physics. Treat that as the high-risk learning area.
- HFT framing is genuinely useful when discussing networking — think market-data fanout, lock-free queues, microsecond budgets, multicast/topic-based interest, NUMA-aware tick loops. Not condescendingly, but as actual analogies they'll find native.
