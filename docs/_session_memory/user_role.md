---
name: user technical background
description: User's day job and technical background — drives what kind of engineering analogies, depth, and trade-off framing are useful.
type: user
originSessionId: cb0aa047-d395-4803-bc6b-7df96341b031
---
**Day job:** frequency trading and big data.

**What this implies for collaboration:**
- Deep familiarity with: lock-free data structures, microsecond-scale networking, kernel bypass, multicast/topic-based pub-sub, deterministic state distribution, NUMA, fixed-tick simulation loops, time sync.
- Comfortable with hand-rolled systems software, Zig, C, C++, FFI.
- Multiple custom-engine projects (fallen-runes, nats-zig, fornax-* OS-ish projects, space-game-throwback). This is a builder, not a glue-code engineer.
- Will see through hand-wavy architecture proposals immediately. Frame trade-offs in concrete latency/throughput/memory terms when relevant.
- HFT analogies are genuinely useful: market-data fanout = state replication; order book per symbol = single-writer entity; quote-to-trade latency = tick budget.

**Useful framing:**
- Don't recommend off-the-shelf MMO frameworks (Photon, Mirror, etc.) — they're not the audience for that.
- Do reference low-level design choices (zero-allocation hot paths, ring buffers, batch tick scheduling).
- When discussing a new subsystem, include a tick budget / memory budget / bandwidth budget if relevant.
- Don't oversimplify or pad explanations. They have less time than patience.
