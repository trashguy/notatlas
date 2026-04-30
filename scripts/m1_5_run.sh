#!/usr/bin/env bash
# M1.5 stress gate launcher — 30 ents/cell × N simulated clients.
#
# Default: ONE gateway process, JWT-authenticated multi-client. The
# orchestrator (scripts/m1_5_drive.py) opens N TCP conns to a single
# port, sends a JWT bearer per conn (claims supply client_id/player_id),
# then drains state frames.
#
# Set MODE=multi for the legacy per-process-per-client workaround
# (50 gateway procs on consecutive ports). Used during the original
# 2026-05-01 M1.5 gate before JWT landed.
#
# Pass criterion: per-conn TCP outbound rate ≤ 1 Mbps. Worst case is
# all subs at origin (spread=0) so every sub sees all 30 ships at
# visual-tier — no slow-lane cluster-aggregate compaction.
#
# Usage:
#   ./scripts/m1_5_run.sh [duration_s] [n_subs] [mode]
#     mode = 'single' (default) | 'multi'

set -euo pipefail
cd "$(dirname "$0")/.."

DURATION="${1:-30}"
N_SUBS="${2:-50}"
MODE="${3:-single}"
N_SHIPS=30
PORT_BASE=9000
CLIENT_BASE=256

LOG=/tmp/notatlas-m15
mkdir -p "$LOG"
rm -f "$LOG"/*.log

echo ">>> M1.5 ($MODE-gateway): $N_SHIPS ships × $N_SUBS subs × ${DURATION}s"

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

if [[ "$MODE" == "single" ]]; then
  echo ">>> spawning 1 gateway (JWT multi-client)"
  zig-out/bin/gateway --listen-port "$PORT_BASE" > "$LOG/gateway.log" 2>&1 &
  PIDS+=($!)
  ORCHESTRATOR_FLAGS="--single-gateway"
else
  echo ">>> spawning $N_SUBS gateway processes (per-process-per-client)"
  for ((i=0; i<N_SUBS; i++)); do
    port=$((PORT_BASE + i))
    cid=$((CLIENT_BASE + i))
    pid_player=$((i + 1))
    zig-out/bin/gateway --listen-port "$port" \
      > "$LOG/gateway-$i.log" 2>&1 &
    PIDS+=($!)
  done
  ORCHESTRATOR_FLAGS=""
  # NOTE: legacy mode uses the new multi-client gateway too — each
  # process gets one conn from the orchestrator, with JWT auth still
  # required. The mode toggle just spreads conns across N ports vs
  # one. The original ed76523-era single-conn-no-JWT gateway is no
  # longer the binary on disk.
fi

sleep 1.5
echo ">>> gateways up; spawning harness bench subs"

zig-out/bin/cell-mgr-harness --scenario bench --n-subs "$N_SUBS" --duration "$DURATION" \
  > "$LOG/harness.log" 2>&1 &
PIDS+=($!)
HARNESS_PID=${PIDS[-1]}

sleep 2

echo ">>> running orchestrator"
python3 scripts/m1_5_drive.py --n-subs "$N_SUBS" --port-base "$PORT_BASE" \
  --measure-s "$((DURATION - 6))" --client-id-base "$CLIENT_BASE" $ORCHESTRATOR_FLAGS

wait "$HARNESS_PID" 2>/dev/null || true

echo ">>> done"
