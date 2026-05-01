---
name: Frame design choices in engineering terms, not gamedev folklore
description: User explicitly distinguishes themselves from "game bros" — wants design discussions framed in engineering trade-offs (change frequency, FFI cost, traversal hot path, schema stability), not "what most games do" or BT-runtime folklore. Confirmed 2026-04-30 when picking BT architecture.
type: feedback
originSessionId: c0f21592-5ca9-4571-9536-a4e657490842
---
Lead with the engineering reasoning; gamedev convention is at most a tiebreaker.

**Why:** User self-identifies as "a software engineer and not game bro." They have an HFT/systems background and trust trade-off analysis (what's hot vs. cold, what changes often vs. rarely, what crosses an FFI boundary, what stays in the cache-friendly language). They distrust appeals to "this is how games do it" because gamedev folklore often hides cargo-culting. Confirmed 2026-04-30 when choosing BT runtime architecture: pure-Lua BT vs. Zig-runtime-with-Lua-leaves. User picked the latter specifically because the engineering framing (composite vocabulary stable + finite, leaf vocabulary open + growing → match each to its strength) was load-bearing, not because BTs are a gamedev standard.

**How to apply:**
- For any design choice with a "the industry does X" version and an engineering-derived version, lead with the engineering version. Mention industry practice only if it's an actual constraint (asset interop, hiring, third-party tooling).
- Frame trade-offs in: change frequency, hot-path cost, FFI/serialization boundary count, schema/runtime stability horizon, determinism story, memory/bandwidth budget. Not in: "feels right," "most engines," "modern AAA does."
- Avoid genre tropes as justification ("survival games usually...", "MMOs typically..."). They're not load-bearing for this project.
- HFT analogies (already noted in user_role.md) are a subset of this preference.
