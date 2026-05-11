#!/usr/bin/env bash
# env-sim → ship-sim wave broadcast smoke. Verifies the wave preset
# travels from env-sim's --wave-preset flag through NATS into
# ship-sim's runtime wave_params (the prior compile-time hardcode at
# src/services/ship_sim/main.zig:142).
#
# Approach:
#   1. Start NATS (services-up if not already running).
#   2. Start env-sim --wave-preset calm. env-sim publishes env.cell.*.waves
#      at 5 Hz with the calm preset (amplitude_m=0.5, seed=1001 per
#      data/waves/calm.yaml).
#   3. Sniff env.cell.0_0.waves via nats-box and assert the payload
#      carries the calm preset fields.
#   4. Restart env-sim with --wave-preset storm. Sniff again; assert
#      storm preset (different seed + larger amplitude) lands.
#
# This smoke proves the producer side end-to-end. The consumer side
# (ship-sim's drainWavesSub overwriting wave_params) is asserted by
# the wire roundtrip unit test + smoke log inspection.
#
# Usage:
#   ./scripts/wave_broadcast_smoke.sh

set -euo pipefail
cd "$(dirname "$0")/.."

LOG=/tmp/notatlas-wave-broadcast
mkdir -p "$LOG"
rm -f "$LOG"/*.log

echo ">>> wave broadcast smoke"

if ! ss -lnt 2>/dev/null | grep -q :4222; then
  echo ">>> starting NATS"
  make nats-up
  sleep 1
fi

zig build install

NATS_BOX="podman run --rm --network host docker.io/natsio/nats-box:latest"

PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do
    kill -INT "$pid" 2>/dev/null || true
  done
  wait "${PIDS[@]}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

run_scenario() {
  local preset="$1" expect_seed="$2" expect_amp_int="$3"  # amp as int*100
  local logfile="$LOG/${preset}.log"
  local snifffile="$LOG/${preset}.sniff"

  echo ">>> scenario: --wave-preset $preset"
  zig-out/bin/env-sim --wave-preset "$preset" > "$logfile" 2>&1 &
  local env_pid=$!
  PIDS+=($env_pid)
  for _ in $(seq 1 50); do
    if grep -q "wave preset='$preset'" "$logfile"; then break; fi
    sleep 0.1
  done
  if ! grep -q "wave preset='$preset'" "$logfile"; then
    echo "FAIL: env-sim didn't log preset banner"; cat "$logfile"; return 1
  fi

  # Sniff one wave publish at cell 0_0 (3×3 default block covers it).
  $NATS_BOX nats sub -s nats://127.0.0.1:4222 'env.cell.0_0.waves' --count=1 \
    > "$snifffile" 2>&1
  kill -INT "$env_pid" 2>/dev/null || true
  wait "$env_pid" 2>/dev/null || true
  # Remove this PID from the trap list now that it's stopped.
  PIDS=("${PIDS[@]/$env_pid}")

  # Extract the JSON line (nats-box prints a banner then the payload).
  local payload
  payload=$(grep -E '^\{' "$snifffile" | head -1)
  if [ -z "$payload" ]; then
    echo "FAIL: no JSON payload sniffed for preset $preset"
    cat "$snifffile"
    return 1
  fi
  echo "    payload: $payload"

  local seed amp
  seed=$(echo "$payload" | python3 -c 'import sys,json;print(json.load(sys.stdin)["seed"])')
  # Multiply amplitude_m by 100 and truncate to int to avoid float
  # equality in shell. data/waves/calm.yaml: 0.5 → 50; storm.yaml:
  # 4.0 → 400.
  amp=$(echo "$payload" | python3 -c 'import sys,json;print(int(json.load(sys.stdin)["amplitude_m"]*100))')

  if [ "$seed" = "$expect_seed" ]; then
    echo "PASS: $preset seed = $seed"
  else
    echo "FAIL: $preset seed = $seed (expected $expect_seed)"
    return 1
  fi
  if [ "$amp" = "$expect_amp_int" ]; then
    echo "PASS: $preset amplitude_m*100 = $amp"
  else
    echo "FAIL: $preset amplitude_m*100 = $amp (expected $expect_amp_int)"
    return 1
  fi
}

fail=0
# Expected values mirror data/waves/<preset>.yaml.
#   calm:  seed=1001, amplitude_m=0.5  (×100 → 50)
#   storm: seed=1003, amplitude_m=8.0  (×100 → 800)
run_scenario calm  1001 50  || fail=1
run_scenario storm 1003 800 || fail=1

echo
echo ">>> logs in $LOG/."
exit "$fail"
