---
name: nats-zig processIncoming has a 100ms read timeout
description: nats-zig's `processIncoming` blocks up to 100ms on empty socket; affects service tick cadence. We own nats-zig — patch when needed.
type: feedback
originSessionId: 66fc34e7-0baa-4b1c-921e-326aaa61a1d8
---
`nats-zig`'s `Client.processIncoming` calls `conn.setReadTimeout(100)` then loops `processOneOp` until `WouldBlock`. On an idle socket the first read waits the full 100 ms before returning, gating any service that uses `processIncoming` in its main loop to ~10 Hz worst case. `Client.poll()` is non-blocking but useless without `processIncoming` filling the read buffer first — `hasPendingData` only checks already-buffered bytes, never does a non-blocking socket read.

**Why:** during M6.3 cell-mgr smoke tests the 30 Hz fanout tick observed ~10 Hz under no-traffic conditions. Once messages flow it tracks correctly. Confirmed by reading nats-zig's `Client.zig` `poll`/`processIncoming`/`hasPendingData` implementations.

**How to apply:** when service tick cadence needs to be honest at 30 Hz+ (M6.4 onward when filter actually publishes), patch `nats-zig` upstream: either add a `processIncoming(timeout_ms)` parameter or expose `hasPendingData` plus a non-blocking socket read variant. We maintain `nats-zig` (https://github.com/trashguy/nats-zig), so bumping a tag is fast — no need to design around the limitation. Don't proxy via a thread pool just to work around it.

**Resolved 2026-04-29 in nats-zig v0.2.2** (commit `f22bba9`): added `Client.processIncomingTimeout(timeout_ms: u32)`. `processIncoming()` is now a backward-compatible 100 ms wrapper. cell-mgr now calls `processIncomingTimeout(5)` — observed loop floor jumped from ~10 Hz to ~30 Hz (matching the fanout target). When future services need different cadences, the API is in place; no further nats-zig work needed for this issue.
