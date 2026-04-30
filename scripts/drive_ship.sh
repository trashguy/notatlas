#!/usr/bin/env bash
# Interactive end-to-end driver: NATS + cell-mgr + ship-sim +
# spatial-index + gateway, then hand off to the WASD keyboard driver.
# ship-sim spawns 5 ships (ids 0x01000001..0x01000005) AND one free-
# agent player capsule (id 0x02000001 — what mint_jwt + drive_ship
# default to). On boot the player is free-agent: WASD walks the
# capsule. Press B to board the nearest ship; A/D/W/S then drive its
# helm. Press G to disembark.
#
# Layout:
#   pane 1 (this terminal): all five service stdouts piped through
#                            tag prefixes; foreground is the python
#                            keyboard driver.
#   ship#1 absolute position + N free-agent / N aboard counters are
#   in the [ship-sim] lines, printed once per second.
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

zig-out/bin/gateway --listen-port 9000 > "$LOG/gateway.log" 2>&1 &
PIDS+=($!)

zig-out/bin/spatial-index --cell-side 200 > "$LOG/spatial.log" 2>&1 &
PIDS+=($!)

sleep 0.5

(zig-out/bin/ship-sim --ships 5 --players 1 2>&1 | tee "$LOG/shipsim.log" | sed 's/^/[ship-sim] /') &
PIDS+=($!)

sleep 0.3
zig-out/bin/cell-mgr-harness --scenario static --duration 99999 > "$LOG/harness.log" 2>&1 &
PIDS+=($!)

sleep 1
echo ">>> all services up; entering keyboard driver"
echo ">>> watch [ship-sim] lines for ship#1 pos + free-agent/aboard counters"
echo ">>> default player_id=0x02000001 spawned ~30 m east of origin"
echo
python3 scripts/drive_ship.py --port 9000
