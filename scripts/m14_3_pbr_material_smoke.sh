#!/usr/bin/env bash
# M14.3 gate. Boots the sandbox with --m14, asserts the PBR material
# path lights up: YAML loaded, 3 KTX2 textures uploaded as VkImages,
# textured pipeline initialized, no Vulkan validation noise, soak
# completes cleanly, M10 gate clauses still PASS with M14 active.
#
# Visual confirmation (Cook-Torrance lighting on the textured cube
# next to the M13 procedural cube) requires a display — gate body
# only checks the log surface.
#
# Test asset is regenerated from scripts/gen_test_textured_cube.py
# (idempotent) so this script doesn't depend on the user having run
# that previously.
#
# Usage:
#   ./scripts/m14_3_pbr_material_smoke.sh [material] [soak]
#     material  default data/materials/test_cube.yaml
#     soak      default 4   (s)

set -euo pipefail
cd "$(dirname "$0")/.."

# zvm-managed Zig 0.15 lives outside the default PATH (Zig is on 0.15
# per zig_015_ecosystem_gap.md; system zig may be 0.16). Prepend zvm
# bin so any `zig` invocation hits the right version.
export PATH="$HOME/.zvm/bin:$PATH"

MATERIAL="${1:-data/materials/test_cube.yaml}"
SOAK="${2:-4}"
LOG=/tmp/notatlas-m14-3-gate.log

echo ">>> M14.3 gate: material=${MATERIAL}, ${SOAK}s soak"

echo ">>> regenerating test asset bundle (idempotent)"
python3 scripts/gen_test_textured_cube.py >/dev/null

echo ">>> building sandbox"
zig build install -Doptimize=ReleaseFast >/dev/null

echo ">>> running sandbox --m14 --soak ${SOAK} --uncap (log: $LOG)"
rm -f "$LOG"
./zig-out/bin/notatlas-sandbox \
  --uncap \
  --m14 \
  --m14-material "$MATERIAL" \
  --soak "$SOAK" \
  > "$LOG" 2>&1

echo ">>> M14 log lines:"
grep -E "M14:" "$LOG" || true

# Field assertions on the M14.3 init logs.
check_log() {
  local pattern="$1" desc="$2"
  if ! grep -qE "$pattern" "$LOG"; then
    echo "FAIL: missing log line — $desc"
    echo "      pattern: $pattern"
    tail -30 "$LOG"
    exit 1
  fi
}
check_log "M14: loaded material 'test_cube'" "Material manifest YAML"
check_log "M14:   albedo=data/textures/test_cube/albedo.ktx2" "Albedo path resolved"
check_log "M14:   normal=data/textures/test_cube/normal.ktx2" "Normal path resolved"
check_log "M14:   orm=data/textures/test_cube/orm.ktx2" "ORM path resolved"
check_log "M14: uploaded 3 VkImages \(albedo 256x256/43, normal 1x1/37, orm 1x1/37\)" "3 textures uploaded"
check_log "M14: PBR pipeline ready" "Pipeline init"

# No Vulkan validation noise.
if grep -qE "vk-err|vk-warn" "$LOG"; then
  echo "FAIL: Vulkan validation noise — see $LOG"
  grep -E "vk-err|vk-warn" "$LOG" | head -20
  exit 1
fi

# No panics or error: lines.
if grep -qE "panic|error: " "$LOG"; then
  echo "FAIL: runtime error — see $LOG"
  grep -E "panic|error: " "$LOG" | head -10
  exit 1
fi

# M10 gate clauses must still report PASS — running --m14 alone exits
# through the soak harness which always emits the M10 gate report.
check_log "gate: piece-types.*PASS" "M10 piece-types PASS with M14 active"

echo ">>> M14.3 gate PASSED"
