---
name: fallen-runes is reference, not a library dependency
description: notatlas builds its own engine. fallen-runes is read for patterns and architectural lessons, never imported as a build dependency.
type: feedback
originSessionId: cdc07d0c-be9d-4d81-8407-11b0c52a6ae2
---
notatlas does NOT take fallen-runes as a library/build dependency. notatlas
has its own engine. fallen-runes is treated as a **reference implementation** —
read it to learn how a subsystem was solved, then reimplement (or selectively
copy trivial utility code) in notatlas.

**Why:** Decided 2026-04-27 during M2 (ocean-render) scoping. fallen-runes is a
different game (top-down, sprites, tilemap) and its renderer carries features
notatlas doesn't need (HDR/bloom, sprite batcher, glTF). Coupling two solo
projects via a build dependency creates permanent coordination friction; both
codebases drift independently anyway. Better to pay duplication cost upfront
and keep notatlas's engine focused on naval-combat-at-scale.

**How to apply:**
- Don't propose adding fallen-runes as a Zig package dep, build module, or
  vendored subtree. Even when scoping work that fallen-runes has already
  solved (renderer, NATS infra, gateway, persistence), the answer is "read
  fallen-runes' code to inform notatlas's implementation," not "import it."
- Trivial pure-utility files (e.g., type aliases over vulkan-headers) can be
  copied verbatim if there's no design decision involved — but assume
  reimplementation by default.
- When sizing engine milestones, account for the cost of writing the
  Vulkan/NATS/etc. boilerplate fresh. Don't price as if fallen-runes' code
  is reusable.
