#!/usr/bin/env bash
# M14.2c gate. Boots the sandbox with --m14, asserts that the libktx →
# VkImage upload + textured pipeline init log lines all fire, no
# Vulkan validation errors surface, and the soak completes cleanly.
#
# Visual confirmation (the textured cube next to the M13 procedural
# cube at (5, 4, -2) vs (5, 4, 0)) requires a display — gate body
# only checks the log surface.
#
# Usage:
#   ./scripts/m14_2_textured_cube_smoke.sh [asset] [soak]
#     asset  default vendor/KTX-Software/tests/testimages/rgba-reference-u.ktx2
#     soak   default 4   (s)

set -euo pipefail
cd "$(dirname "$0")/.."

ASSET="${1:-vendor/KTX-Software/tests/testimages/rgba-reference-u.ktx2}"
SOAK="${2:-4}"
LOG=/tmp/notatlas-m14-2-gate.log

echo ">>> M14.2c gate: asset=${ASSET}, ${SOAK}s soak"

if [[ ! -f "$ASSET" ]]; then
  echo "FAIL: asset missing: $ASSET"
  echo "      git submodule update --init vendor/KTX-Software"
  exit 1
fi

echo ">>> building sandbox + M14 path"
zig build install -Doptimize=ReleaseFast >/dev/null

echo ">>> running sandbox --m14 --soak ${SOAK} --uncap (log: $LOG)"
rm -f "$LOG"
./zig-out/bin/notatlas-sandbox \
  --uncap \
  --m14 \
  --m14-asset "$ASSET" \
  --soak "$SOAK" \
  > "$LOG" 2>&1

echo ">>> M14 log lines:"
grep -E "M14:" "$LOG" || true

# Field assertions on the M14 init logs.
check_log() {
  local pattern="$1" desc="$2"
  if ! grep -qE "$pattern" "$LOG"; then
    echo "FAIL: missing log line — $desc"
    echo "      pattern: $pattern"
    tail -30 "$LOG"
    exit 1
  fi
}
check_log "M14: loaded.*128x128 vk_format=43 bytes=65536" "KTX2 load (128x128 RGBA8)"
check_log "M14: uploaded to VkImage 128x128 format=43" "VkImage upload"
check_log "M14: textured pipeline ready" "Textured pipeline init"

# No Vulkan validation errors anywhere in the run.
if grep -qE "vk-err|vk-warn" "$LOG"; then
  echo "FAIL: Vulkan validation noise — see $LOG"
  grep -E "vk-err|vk-warn" "$LOG" | head -20
  exit 1
fi

# No panics.
if grep -qE "panic|error: " "$LOG"; then
  echo "FAIL: runtime error — see $LOG"
  grep -E "panic|error: " "$LOG" | head -10
  exit 1
fi

# M10 gate clauses must still report PASS (running --m14 alone exits
# through the soak harness which always emits the M10 gate report).
check_log "gate: piece-types.*PASS" "M10 piece-types still PASS with M14 active"
check_log "M10 gate" "harness M10 report"

echo ">>> M14.2c gate PASSED"
