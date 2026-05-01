---
name: notatlas grid-handoff architecture (NATS-based)
description: Architectural model for notatlas's seamless cross-cell ship handoff using NATS pub/sub and microservices, replacing Atlas's UE4-dedicated-server-per-cell + Redis approach. The headline technical innovation of the project.
type: project
originSessionId: cb0aa047-d395-4803-bc6b-7df96341b031
---
Atlas's grid was 225 UE4 dedicated server processes, each owning a 1×1 cell of UE world. Cross-cell ship transitions serialized actor state and re-spawned on the destination process, coordinated by a single Redis. Result: ~2s stutter, ship-eating bugs, no graceful scaling.

notatlas keeps the *user-facing* seamless grid feel but inverts the ownership model.

**Core principle: cells don't own ships. Cells are interest managers.**

- A **ship simulation service** runs the physics for each ship at high tick rate. Pubs to NATS subject like `sim.ship.<id>.state` with pose/velocity/damage.
- A **cell service** owns a region of world space. It subscribes to whatever ship/entity streams have coordinates inside its region. When a ship's pose crosses the cell boundary, the destination cell starts subscribing and the source unsubscribes. **No state migration. The ship process doesn't know it changed cells.**
- **Players** subscribe to cells (their own + neighbors for view-distance) and to specific ships they're aboard. Their NATS interest set is what defines what they see.
- **Persistence** lives in Postgres keyed by entity id, written through by ownership services on a slower cadence than tick rate.
- **Authoritative truth** for any entity lives in the service that simulates it (ship sim for ships, character sim for players, AI sim for crew/SotD), not in any cell.

**Why this maps cleanly to HFT thinking:**
- High-frequency state stream + interest-managed subscribers = market data fanout to multicast groups.
- Lock-free single-writer per entity = order book per symbol.
- Tick budget per service = quote-to-trade latency budget.
- NATS subjects are spatial topics; subject-prefix wildcards give cheap region queries.

**What this avoids that Atlas couldn't:**
- No serialize/teleport stutter at boundaries.
- No "ship eaten by handoff" — the ship process is unaffected by which cell is watching.
- Cells can hibernate/scale-down when nobody subscribes (idle ocean).
- New cells can be added without coordinating with neighbors — they just subscribe to spatial subjects.
- Ship sim service can be moved between hosts orthogonally to where players are.

**Open architectural questions to resolve in Phase 0/1:**
1. Tick rate target for ship sim (HFT instinct says "as fast as possible"; reality is probably 30-60Hz authoritative with client interpolation).
2. NATS JetStream for replay/persistence vs core NATS for fanout-only.
3. How player input propagates: client → gateway → entity-owning service (probably the ship sim if they're at the helm)?
4. ~~Spatial subject scheme~~ **LOCKED 2026-04-27: Option B+D hybrid.** Mobile entities publish to identity-keyed `sim.entity.<id>.state` forever. Static/environmental state at `env.cell.<x>_<y>.<kind>`. Spatial index service translates "cell membership" via `idx.spatial.cell.<x>_<y>.delta`. Entities don't change subject when crossing cells; subscribers' interest set changes instead.
5. View-distance subscription management (clients need to subscribe/unsubscribe as they move; cheap on NATS but the bookkeeping matters).
