#!/usr/bin/env bash
# M12 gate harness. Spawns 200 placeholder-anim characters across
# three distance bands (~67 near / ~67 mid / ~66 far under default
# 30 m / 100 m thresholds) and soaks for 10 s under MAILBOX. Asserts
# the M12 gate clauses:
#
#   - cpu-anim ≤ 2 ms / frame    (§12 spec)
#   - far tier exercised + skipped (the "vertex-shader anim atlas,
#     no CPU work" intent — at least one char must have landed in
#     the .far band and been skipped by the CPU tick path)
#   - avg frametime ≤ 16.67 ms (60 fps target)
#   - p99 frametime ≤ 16.67 ms (no stutter under anim load)
#
# Requires a display (the sandbox opens a Vulkan window). Skip on
# headless boxes; not part of `make test`.
#
# Usage:
#   ./scripts/m12_gate_smoke.sh [chars] [near_thr] [mid_thr] [soak]
#     chars    default 200   (§12 gate design cap)
#     near_thr default 30    (m; .near/.mid boundary)
#     mid_thr  default 100   (m; .mid/.far boundary)
#     soak     default 10    (s)

set -euo pipefail
cd "$(dirname "$0")/.."

CHARS="${1:-200}"
NEAR="${2:-30}"
MID="${3:-100}"
SOAK="${4:-10}"
LOG=/tmp/notatlas-m12-gate.log

echo ">>> M12 gate: ${CHARS} chars, near≤${NEAR} m / mid≤${MID} m, ${SOAK}s soak"
echo ">>> building sandbox"
zig build install

echo ">>> running sandbox (log: $LOG)"
# --uncap = MAILBOX present mode so frametime reflects actual GPU/CPU
# cost rather than the display vsync period. Required for the p99
# gate to be meaningful.
./zig-out/bin/notatlas-sandbox \
  --uncap \
  --m12-chars "$CHARS" \
  --m12-near-threshold "$NEAR" \
  --m12-mid-threshold "$MID" \
  --soak "$SOAK" \
  > "$LOG" 2>&1 || {
    echo "!!! sandbox exited non-zero — see $LOG"
    exit 1
  }

echo ">>> harness report:"
sed -n '/==== M12 gate harness ====/,$p' "$LOG"

M12_LINE=$(grep -E "gate: cpu-anim≤2ms" "$LOG" || true)
if [[ -z "$M12_LINE" ]]; then
  echo "!!! M12 gate line not found — see $LOG"
  exit 1
fi
if echo "$M12_LINE" | grep -q "FAIL"; then
  echo
  echo "!!! M12 gate FAILED"
  echo "$M12_LINE"
  exit 1
fi

echo
echo ">>> M12 gate PASSED"
