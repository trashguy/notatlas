---
name: PG client = karlseguin/pg.zig (zig-0.15 branch)
description: Locked 2026-05-01 during persistence-writer kickoff — pure-Zig PG driver, vendored. Don't propose libpq thin-C-binding without a load-bearing reason.
type: feedback
originSessionId: 9faac8f3-1919-4d81-aa68-07970ec6fc44
---
`persistence-writer` uses **karlseguin/pg.zig** on its `zig-0.15` branch
as the Postgres client. Imported via `zig fetch --save` and pinned by
SHA in `build.zig.zon` — same pattern as `nats_zig` (the most analogous
dep: pure-Zig protocol client, hash-pinned, not under `vendor/`).
`vendor/` is reserved for huge C++ submodules (Jolt) and bundled
source (Lua); pg.zig is neither.

**Why:** Considered libpq thin-C-binding (matches the
`feedback_thin_c_bindings.md` precedent of Lua/Jolt/NATS) vs pure-Zig.
Three factors tipped pure-Zig:
1. **Same shape as nats-zig.** nats-zig is also a pure-Zig protocol
   reimplementation, not a thin C wrapper. The "thin C bindings"
   feedback rule is specifically about not pulling zig-gamedev-style
   wrapper modules around C libs — pg.zig is not a wrapper, it's the
   wire protocol natively.
2. **No glibc pin entanglement.** libpq would link against system
   libpq or require vendoring PG client headers; either path
   complicates the existing `build_zig_glibc_pin.md` workaround on
   Arch Linux.
3. **0.15 branch exists and is current.** Last commit on master
   2026-04-25; `zig-0.15` branch tracks 0.15.2 deliberately. README
   officially documents it as the 0.15 path. Active maintainer
   (karlseguin, also runs the @karlseguin/buffer.zig and
   @karlseguin/metrics.zig deps).

**How to apply:**
- Pin via `zig fetch --save https://github.com/karlseguin/pg.zig/archive/<SHA>.tar.gz`
  against a specific commit on the `zig-0.15` branch. `zig fetch` writes
  a hash-pinned entry into `build.zig.zon` — that *is* a pin, equivalent
  in safety to vendoring source.
- pg.zig's transitive deps (`buffer`, `metrics`, `translate-c`) are
  resolved automatically by Zig's package manager from pg.zig's own
  `build.zig.zon`. Verify each has 0.15 support before bumping the
  pinned SHA.
- Use `pg.Pool` even at size=1 — the reconnect-on-failure thread is
  load-bearing for graceful-degradation (`feedback_graceful_degradation.md`).
- pg.zig 0.15 branch supports parameterized queries, prepared statements,
  transactions, LISTEN/NOTIFY. NO COPY FROM STDIN — fine for v0
  because damage_log is the analytics aggregate (low-rate per
  `architecture_locked_decisions_v0`), not a hot-path bulk-insert
  surface. If COPY becomes load-bearing later, either upstream a
  CopyData/CopyDone frame to pg.zig or fall back to libpq.

**Fallback plan:** If pg.zig 0.15 has a blocking gap (auth, big-int
type, etc.), drop to libpq thin-C-binding. Don't escalate quietly —
log the reason and update this memory.
