#!/usr/bin/env bash
# Interactive end-to-end driver: NATS + cell-mgr + ship-sim + gateway,
# then hand off to the WASD keyboard driver. ship-sim is targeted as
# entity id 1 (the lead ship). Other 4 ships bob in place.
#
# Layout:
#   pane 1 (this terminal): all four service stdouts piped through
#                            tag prefixes; foreground is the python
#                            keyboard driver.
#   ship#1 absolute position is in the [ship-sim] lines, printed once
#   per second.
#
# Cleanup: Ctrl-C / q in the keyboard driver kills the bg services.

set -e
cd "$(dirname "$0")/.."

LOG=/tmp/notatlas-drive
mkdir -p "$LOG"

# Start NATS if not already up.
if ! ss -lnt 2>/dev/null | grep -q :4222; then
  echo ">>> starting NATS"
  make nats-up
fi

zig build

PIDS=()
cleanup() {
  echo
  echo ">>> stopping services: ${PIDS[*]}"
  for pid in "${PIDS[@]}"; do
    kill -INT "$pid" 2>/dev/null || true
  done
  wait "${PIDS[@]}" 2>/dev/null || true
}
trap cleanup EXIT

zig-out/bin/cell-mgr --cell 0_0 > "$LOG/cellmgr.log" 2>&1 &
PIDS+=($!)

zig-out/bin/gateway --client-id 256 --player-id 1 --listen-port 9000 > "$LOG/gateway.log" 2>&1 &
PIDS+=($!)

sleep 0.5

(zig-out/bin/ship-sim --ships 5 2>&1 | tee "$LOG/shipsim.log" | sed 's/^/[ship-sim] /') &
PIDS+=($!)

sleep 0.3
zig-out/bin/cell-mgr-harness --scenario static --duration 99999 > "$LOG/harness.log" 2>&1 &
PIDS+=($!)

sleep 1
echo ">>> all services up; entering keyboard driver"
echo ">>> watch [ship-sim] lines for ship#1 position changes"
echo
python3 scripts/drive_ship.py --port 9000
