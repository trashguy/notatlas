---
name: Zig 0.15 — `continue` with runtime condition not allowed in `inline for`
description: Bit-pack codec patterns hit Zig 0.15's restriction on `continue` inside `inline for` when the condition is runtime. Use plain `for`.
type: feedback
originSessionId: 66fc34e7-0baa-4b1c-921e-326aaa61a1d8
---
In Zig 0.15.2, `inline for (...) |i| { if (i == runtime_var) continue; ... }` fails to compile with `error: comptime control flow inside runtime block`. The `continue` is comptime-evaluated but lives inside a runtime branch.

**Why:** hit during M7 pose codec smallest-three encoder. Workaround in pose_codec.zig:135: switch the loop from `inline for (0..4)` to plain `for (0..4)` — the 4-iteration unrolling savings are negligible vs. the round/clamp work in the body, and the regular loop accepts runtime `continue` cleanly.

**How to apply:** any time a small comptime-known loop conditionally skips an iteration based on a runtime value, use `for`. `inline for` is fine when every iteration runs unconditionally.

**Related gotcha (same M7 work):** `var bit_off: u5 = 2; bit_off += 10` after three iterations becomes 32, which overflows u5. When using a counter that only constrains shift amounts, keep it in `u8` (or wider) and `@intCast(bit_off)` at the shift site. Don't size it tightly to the shift type's width if the loop body can push it past.
