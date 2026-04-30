#!/usr/bin/env bash
# M1.5 stress gate launcher — 30 ents/cell × 50 simulated clients.
#
# Architecture: per-process-per-client gateway workaround until
# JWT + multi-client gateway lands. 50 gateway processes on ports
# 9000..9049 with client_ids 0x100..0x131 (= 256..305). The harness
# `bench` scenario spawns matching cell-mgr subscribers in that id
# range so cell-mgr fans out per-sub on `gw.client.<id>.cmd`.
#
# Pass criteria: per-conn TCP outbound rate ≤ 1 Mbps, headline gate
# per docs/04 §M1.5. Worst case is all 50 subs at origin (spread=0)
# so every sub sees all 30 ships at visual-tier — no slow-lane
# cluster-aggregate compaction. If the gate passes here it passes
# anywhere.
#
# Usage: ./scripts/m1_5_run.sh [duration_s] [n_subs]

set -euo pipefail
cd "$(dirname "$0")/.."

DURATION="${1:-30}"
N_SUBS="${2:-50}"
N_SHIPS=30
PORT_BASE=9000
CLIENT_BASE=256

LOG=/tmp/notatlas-m15
mkdir -p "$LOG"
rm -f "$LOG"/*.log

echo ">>> M1.5: $N_SHIPS ships × $N_SUBS subs × ${DURATION}s"

if ! ss -lnt 2>/dev/null | grep -q :4222; then
  echo ">>> starting NATS"
  make nats-up
fi

zig build

PIDS=()
cleanup() {
  echo ">>> stopping ${#PIDS[@]} processes"
  for pid in "${PIDS[@]}"; do
    kill -INT "$pid" 2>/dev/null || true
  done
  wait "${PIDS[@]}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Backbone services.
zig-out/bin/cell-mgr --cell 0_0 > "$LOG/cellmgr.log" 2>&1 &
PIDS+=($!)
zig-out/bin/ship-sim --ships "$N_SHIPS" --grid --spacing 30 > "$LOG/shipsim.log" 2>&1 &
PIDS+=($!)
sleep 0.5

# 50 gateway processes — each with its own port + client_id +
# player_id. The harness's bench scenario spawns matching subs.
echo ">>> spawning $N_SUBS gateway processes"
for ((i=0; i<N_SUBS; i++)); do
  port=$((PORT_BASE + i))
  cid=$((CLIENT_BASE + i))
  pid_player=$((i + 1))  # ships are ids 1..30; if i>=30 player_id is bogus (no ship)
  zig-out/bin/gateway --client-id "$cid" --player-id "$pid_player" --listen-port "$port" \
    > "$LOG/gateway-$i.log" 2>&1 &
  PIDS+=($!)
done

# Wait for gateways to bind and subscribe.
sleep 1.5
echo ">>> $N_SUBS gateways up; spawning harness bench subs"

zig-out/bin/cell-mgr-harness --scenario bench --n-subs "$N_SUBS" --duration "$DURATION" \
  > "$LOG/harness.log" 2>&1 &
PIDS+=($!)
HARNESS_PID=${PIDS[-1]}

# Give harness time to publish all subs and cell-mgr to absorb them.
sleep 2

echo ">>> running orchestrator"
python3 scripts/m1_5_drive.py --n-subs "$N_SUBS" --port-base "$PORT_BASE" --measure-s "$((DURATION - 6))"

# Wait for the harness duration to complete (it tears down subs on exit).
wait "$HARNESS_PID" 2>/dev/null || true

echo ">>> done"
