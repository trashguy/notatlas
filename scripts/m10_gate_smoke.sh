#!/usr/bin/env bash
# M10.4 gate harness. Spawns 5041 static cubes across 20 piece types and
# runs a 10s soak; verifies the M10 gate clauses pass:
#
#   - piece-types ≤ 20            (number of indirect-cmd buckets)
#   - average frametime ≤ 16.67 ms (60 fps target)
#   - p99 frametime ≤ 16.67 ms     (no stutter)
#
# Requires a display (the sandbox opens a Vulkan window). Skip on
# headless boxes; not part of `make test`.
#
# Usage:
#   ./scripts/m10_gate_smoke.sh [grid_dim] [piece_types] [soak_seconds]
#     grid_dim       default 71   (71×71 = 5041 grid instances, target 5000)
#     piece_types    default 20   (the M10 gate ceiling)
#     soak_seconds   default 10
#
# Outputs:
#   /tmp/notatlas-m10-gate.log — full sandbox stderr + stdout

set -euo pipefail
cd "$(dirname "$0")/.."

GRID="${1:-71}"
PIECE_TYPES="${2:-20}"
SOAK="${3:-10}"
LOG=/tmp/notatlas-m10-gate.log

echo ">>> M10 gate: ${GRID}x${GRID}=$((GRID*GRID)) instances, ${PIECE_TYPES} piece types, ${SOAK}s soak"
echo ">>> building sandbox"
zig build install

echo ">>> running sandbox (log: $LOG)"
# --uncap = MAILBOX present mode so frametime reflects actual GPU/CPU
# cost rather than the display vsync period. Required for the p99 gate
# to be meaningful — under FIFO the metric measures dropped-frame
# fraction, not workload.
./zig-out/bin/notatlas-sandbox \
  --uncap \
  --instance-grid "$GRID" \
  --piece-types "$PIECE_TYPES" \
  --soak "$SOAK" \
  --cam-orbit-rate 0.3 \
  --wave-config data/waves/calm.yaml \
  > "$LOG" 2>&1 || {
    echo "!!! sandbox exited non-zero — see $LOG"
    exit 1
  }

echo ">>> harness report:"
sed -n '/==== M10 gate harness ====/,$p' "$LOG"

M10_LINE=$(grep -E "gate: piece-types≤20" "$LOG" || true)
if [[ -z "$M10_LINE" ]]; then
  echo "!!! M10 gate line not found — see $LOG"
  exit 1
fi
if echo "$M10_LINE" | grep -q "FAIL"; then
  echo
  echo "!!! M10 gate FAILED"
  echo "$M10_LINE"
  exit 1
fi

echo
echo ">>> M10 gate PASSED"
