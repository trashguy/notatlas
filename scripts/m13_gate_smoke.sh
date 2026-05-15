#!/usr/bin/env bash
# M13 gate. Loads `data/props/test_cube.gltf` and renders one
# instance alongside the procedural-cube ship, then re-writes the
# asset mid-soak to exercise the M13.2 hot-reload path. Asserts:
#
#   - loader emits "M13: loaded ..." with the expected vertex /
#     index count (24 / 36 — same shape as the procedural cube)
#   - the M13 instance is registered with piece_id ≥ cli.piece_types
#   - file_watch + palette.updatePiece fire a "reload" log line on
#     a mid-soak overwrite of the glTF asset
#   - sandbox exits cleanly under a short soak
#
# Requires a display (the sandbox opens a Vulkan window). Skip on
# headless boxes; not part of `make test`.
#
# Usage:
#   ./scripts/m13_gate_smoke.sh [asset_path] [soak]
#     asset_path  default data/props/test_cube.gltf
#     soak        default 4   (s — covers the t≈2s hot-reload pulse)

set -euo pipefail
cd "$(dirname "$0")/.."

ASSET="${1:-data/props/test_cube.gltf}"
SOAK="${2:-4}"
LOG=/tmp/notatlas-m13-gate.log

echo ">>> M13 gate: asset=${ASSET}, ${SOAK}s soak"
echo ">>> regenerating test asset (idempotent)"
python3 scripts/gen_test_cube_gltf.py

echo ">>> building sandbox"
zig build install

echo ">>> running sandbox (log: $LOG)"
rm -f "$LOG"
./zig-out/bin/notatlas-sandbox \
  --uncap \
  --m13 \
  --m13-asset "$ASSET" \
  --soak "$SOAK" \
  --cam-orbit-rate 0.3 \
  --wave-config data/waves/calm.yaml \
  > "$LOG" 2>&1 &
SANDBOX_PID=$!

# Wait for the sandbox to settle past startup, then overwrite the
# glTF file to trigger inotify CLOSE_WRITE → events.gltf → handleReload.
sleep 2
echo ">>> overwriting glTF to trigger hot-reload"
python3 scripts/gen_test_cube_gltf.py

wait "$SANDBOX_PID" || {
  echo "!!! sandbox exited non-zero — see $LOG"
  exit 1
}

echo ">>> M13 log lines:"
grep -E "M13:|reload data/props" "$LOG" || {
  echo "!!! no M13 log lines emitted"
  exit 1
}

LOAD_LINE=$(grep -E "M13: loaded.*verts.*indices" "$LOG" || true)
if [[ -z "$LOAD_LINE" ]]; then
  echo "!!! M13 load line not found — see $LOG"
  exit 1
fi

# Visual-parity assertions: same vert + index counts as the procedural
# cube in src/render/box.zig. M13 swap-in is expected to match shape.
echo "$LOAD_LINE" | grep -q "24 verts" || {
  echo "!!! expected 24 verts (procedural-cube parity); got: $LOAD_LINE"
  exit 1
}
echo "$LOAD_LINE" | grep -q "36 indices" || {
  echo "!!! expected 36 indices (procedural-cube parity); got: $LOAD_LINE"
  exit 1
}

INSTANCE_LINE=$(grep -E "M13: instance placed" "$LOG" || true)
if [[ -z "$INSTANCE_LINE" ]]; then
  echo "!!! M13 instance line not found — see $LOG"
  exit 1
fi

RELOAD_LINE=$(grep -E "reload data/props/.*verts.*indices" "$LOG" || true)
if [[ -z "$RELOAD_LINE" ]]; then
  echo "!!! M13.2 hot-reload line not found — file_watch / palette.updatePiece path broken"
  echo "--- last 30 lines of log ---"
  tail -30 "$LOG"
  exit 1
fi

echo
echo ">>> M13 gate PASSED (load + hot-reload)"
