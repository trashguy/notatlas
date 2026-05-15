#!/usr/bin/env bash
# M1.6 synthetic-harbor-stress gate. Combines the Phase 2 client-side
# synthetic milestones (M10 + M11 + M12) plus a disposable particle
# billboard stub into one scene and verifies the harbor density gate:
#
#   - 500 random structures (anchorage path, M11)
#   - 30 static box-ships (M1.6.1, this commit)
#   - 200 placeholder-anim characters (M12)
#   - 100 CPU-billboard particle emitters × 20 particles each (M1.6.2
#     DISPOSABLE STUB — real particle system is M17 in Phase 2.5)
#
# Gate clauses:
#   - scene composition complete
#   - avg frametime ≤ 16.67 ms (60 fps)
#   - p99 frametime ≤ 16.67 ms (no stutter at design cap)
#   - per-subsystem CPU costs ≤ 2 ms (spec: "any subsystem >2 ms gets
#     fixed before content")
#
# Requires a display (the sandbox opens a Vulkan window). Skip on
# headless boxes; not part of `make test`.
#
# Usage:
#   ./scripts/m1_6_gate_smoke.sh [soak]
#     soak  default 10  (s)

set -euo pipefail
cd "$(dirname "$0")/.."

SOAK="${1:-10}"
LOG=/tmp/notatlas-m1_6-gate.log

echo ">>> M1.6 synthetic-harbor gate: 500 structures + 30 ships + 200 chars + 100 emitters × 20, ${SOAK}s soak"
echo ">>> building sandbox"
zig build install

echo ">>> running sandbox (log: $LOG)"
# --uncap = MAILBOX present mode so frametime reflects actual GPU/CPU
# cost rather than the display vsync period. Required for the p99
# gate to be meaningful.
./zig-out/bin/notatlas-sandbox \
  --uncap \
  --piece-types 20 \
  --anchorage-pieces 500 \
  --anchorage-piece-types 20 \
  --anchorage-radius 50 \
  --anchorage-lod-distance 100 \
  --m1_6-ships 30 \
  --m12-chars 200 \
  --m1_6-emitters 100 \
  --soak "$SOAK" \
  --cam-orbit-rate 0.3 \
  --wave-config data/waves/calm.yaml \
  > "$LOG" 2>&1 || {
    echo "!!! sandbox exited non-zero — see $LOG"
    exit 1
  }

echo ">>> harness report:"
sed -n '/==== M1.6 synthetic-harbor gate harness ====/,$p' "$LOG"

M16_LINE=$(grep -E "gate: composition" "$LOG" || true)
if [[ -z "$M16_LINE" ]]; then
  echo "!!! M1.6 gate line not found — see $LOG"
  exit 1
fi
if echo "$M16_LINE" | grep -q "FAIL"; then
  echo
  echo "!!! M1.6 gate FAILED"
  echo "$M16_LINE"
  exit 1
fi

echo
echo ">>> M1.6 gate PASSED"
