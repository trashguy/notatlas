---
name: Graceful degradation + circuit breaking across the service mesh
description: Default design lens for any service interaction — assume any dependency may be offline; design for reduced-state operation and clean recovery rather than cascading failure. Apply at every new service boundary.
type: feedback
originSessionId: 95a9947f-138a-4fd8-922f-cc5b85309187
---
When designing or modifying any service-to-service interaction in notatlas, factor in: (1) what reduced-state operation looks like if the dependency goes offline, (2) circuit-breaking so an offline dependency doesn't cascade, (3) recovery semantics when the dependency comes back. Default to "stay up in degraded mode," not "crash and let the supervisor restart."

**Why:** notatlas runs ~8 services on NATS. Hard coupling ("crash if dependency unreachable") would mean any one service flap cascades into a full outage. Atlas's terminal lesson was that production failure modes nobody designed for took down the world. Designing for graceful degradation from day one is cheaper than retrofitting after the first incident; it also forces the right primitives (last-known-good caches, JetStream for durability, NATS req/reply with bounded retry) into the substrate before they're needed.

**How to apply:** at every new service or new cross-service interaction, answer four questions before shipping:

1. **What's the reduced-state behavior?** If the dependency is gone for 30 s, what does this service do?
   - `env` offline → consumers use last-known wind/weather snapshot. 5 Hz update is cosmetic; staleness for tens of seconds is fine. Cache last value per cell.
   - `spatial-index` offline → cell-mgr's entity table goes stale (no new enter/exit deltas). Existing entities continue to receive state msgs (firehose is independent). Sub-region geometry filter still works for already-known entities. **New** entities entering the cell are invisible until spatial-index returns. Acceptable for ~10 s; longer is a player-visible bug.
   - `ship-sim` offline → ships freeze at last published pose (cell-mgr keeps the last state). Per docs/08 §7.4 this is the unsolved one for Phase 1 (process supervisor + fast restart, accept ~5 s loss).
   - `gateway` offline → clients reconnect to a sibling gateway. Stateless per docs/08 §7.3.
   - `persistence-writer` offline → JetStream queue builds up. Bounded by stream size; consumer drain on recovery. Don't block the publish-side path.
   - `cell-mgr` offline → subscribers in that cell see stale fanout. Lease swap re-shards (docs/08 §2.4). Other cells unaffected.

2. **Where does the "current value" cache live?** Any cross-service read that has a "reasonable last-known" should cache it locally. Pattern: subscribe + maintain in-memory current value + serve from cache. Don't req/reply on every read for state that arrives via firehose.

3. **What's the circuit-breaker shape?** Three flavors used in this project:
   - **Subscribe-and-forget** (firehose consumers): NATS handles reconnect transparently. The service stays up with stale data; never errors out.
   - **Bounded req/reply with backoff** (`idx.spatial.query`, future radius queries): per call, max retry budget (~250 ms total, e.g. 50/100/200 ms with jitter). Fail open with empty result rather than block. Document the retry policy in the caller's spec (M9 lag-comp's hit detection in particular).
   - **JetStream-durable** for consumer-side durability (`idx.spatial.cell.*.delta`, persistence events): consumer recovers via cursor on reconnect. Producer crash + standby promotion is invisible to consumer.

4. **What's the recovery story?** When the dependency returns:
   - Cache-warm consumers (firehose): just keep going; new msgs arrive, cache updates.
   - JetStream consumers: cursor-driven catch-up. May see a burst of deltas; the entity table converges within seconds.
   - Req/reply callers: next call after recovery succeeds. No state to repair.
   - Active/standby HA (spatial-index): standbys are state-current via the firehose; promotion is a NATS KV optimistic-lock race, not a state copy. ~3-5 s failover per docs/08 §7.1.

**Anti-patterns to avoid:**
- Synchronous service-to-service calls that block one tick on another tick (cascade amplifier).
- Crash-on-startup if a dependency is unreachable. Wait + retry + degrade.
- Health-check heartbeats that gate publish — if the heartbeat path breaks, the data path shouldn't.
- Unbounded retry / unbounded queues. Both create silent failure modes.
- Per-call dependency check ("is X up?") before every request. If X is up at check-time but down at call-time, you get the worst of both.

**Producer-side discipline:** any producer of a stream that consumers depend on should publish to a JetStream-backed subject if recovery requires history (e.g. cell deltas). Live-only NATS subjects are fine for high-volume firehoses where staleness is the recovery story (e.g. `sim.entity.*.state` — replay doesn't help, just wait for the next tick).

**Consumer-side discipline:** every NATS-subscribing service should track last-msg-time per subject and surface "stale dependency" in its logs. Detection ≠ failure; just observable so an operator can correlate.

When this lens conflicts with simplicity (e.g. early prototypes), document the deferral explicitly: `// TODO graceful-degradation: handle env offline (currently crashes)` so it's an audit-able stub, not a hidden assumption.
