#!/usr/bin/env bash
# M11 gate harness. Spawns a 500-piece anchorage (20 piece types,
# 50 m radius) in --force-far, soaks for 10s, and asserts the M11
# gate clauses:
#
#   - merge time ≤ 100 ms (sync initial + worker invalidate)
#   - far-LOD draws = 1 (merged-path single drawIndexed)
#   - avg frametime ≤ 16.67 ms (60 fps)
#   - p99 frametime ≤ 16.67 ms (no stutter under merged-path load)
#
# Also fires one programmatic invalidate at t=3 s to exercise the
# M11.3 off-thread worker path under soak conditions.
#
# Requires a display (the sandbox opens a Vulkan window). Skip on
# headless boxes; not part of `make test`.
#
# Usage:
#   ./scripts/m11_gate_smoke.sh [pieces] [piece_types] [radius] [soak]
#     pieces       default 500   (M11 gate design cap)
#     piece_types  default 20    (matches the M10 gate ceiling)
#     radius       default 50.0  (m; anchorage footprint)
#     soak         default 10    (s)

set -euo pipefail
cd "$(dirname "$0")/.."

PIECES="${1:-500}"
PIECE_TYPES="${2:-20}"
RADIUS="${3:-50.0}"
SOAK="${4:-10}"
LOG=/tmp/notatlas-m11-gate.log

echo ">>> M11 gate: ${PIECES} pieces × ${PIECE_TYPES} types, r=${RADIUS} m, ${SOAK}s soak (force-far)"
echo ">>> building sandbox"
zig build install

echo ">>> running sandbox (log: $LOG)"
# --uncap = MAILBOX present mode so frametime reflects actual GPU/CPU
# cost rather than the display vsync period. Required for the p99
# gate to be meaningful.
# --anchorage-invalidate-after fires one invalidate mid-soak so the
# M11.3 worker round-trip is exercised in the harness output.
./zig-out/bin/notatlas-sandbox \
  --uncap \
  --piece-types "$PIECE_TYPES" \
  --anchorage-pieces "$PIECES" \
  --anchorage-piece-types "$PIECE_TYPES" \
  --anchorage-radius "$RADIUS" \
  --anchorage-lod-distance 100 \
  --anchorage-invalidate-after 3 \
  --force-far \
  --soak "$SOAK" \
  --cam-orbit-rate 0.3 \
  --wave-config data/waves/calm.yaml \
  > "$LOG" 2>&1 || {
    echo "!!! sandbox exited non-zero — see $LOG"
    exit 1
  }

echo ">>> harness report:"
sed -n '/==== M11 gate harness ====/,$p' "$LOG"

FAILS=$(grep -E "^.*gate: .*\bFAIL\b" "$LOG" | grep -i "M11\|merge\|far-LOD\|p99\|avg" || true)
# More strictly: the M11 gate line starts with "  gate: merge". Match it.
M11_LINE=$(grep -E "gate: merge≤100ms" "$LOG" || true)
if [[ -z "$M11_LINE" ]]; then
  echo "!!! M11 gate line not found — see $LOG"
  exit 1
fi
if echo "$M11_LINE" | grep -q "FAIL"; then
  echo
  echo "!!! M11 gate FAILED"
  echo "$M11_LINE"
  exit 1
fi

echo
echo ">>> M11 gate PASSED"
