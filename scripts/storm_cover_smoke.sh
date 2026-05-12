#!/usr/bin/env bash
# ai-sim storm-cover smoke. Verifies the env.storms consumer path:
#   1. env-sim publishes env.storms at 1 Hz (existing producer)
#   2. ai-sim subscribes, decodes, and exposes nearest_storm to Lua
#
# Approach:
#   - Boot env-sim + ai-sim (no ship-sim needed; we test the wire).
#   - Wait ~3 s so ai-sim's log emits at least one period summary.
#   - Assert ai-sim log shows storm-msgs > 0 AND non-zero storms count.
#
# The Lua leaf behavior itself is covered by perception.zig +
# dispatcher.zig unit tests; this smoke proves the cross-service wire
# end-to-end.
#
# Usage:
#   ./scripts/storm_cover_smoke.sh

set -euo pipefail
cd "$(dirname "$0")/.."

LOG=/tmp/notatlas-storm-cover
mkdir -p "$LOG"
rm -f "$LOG"/*.log

echo ">>> storm-cover smoke (env.storms → ai-sim consumer)"

if ! ss -lnt 2>/dev/null | grep -q :4222; then
  echo ">>> starting NATS"
  make nats-up
  sleep 1
fi

zig build install

PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do
    kill -INT "$pid" 2>/dev/null || true
  done
  wait "${PIDS[@]}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

zig-out/bin/env-sim > "$LOG/env-sim.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do
  if grep -q "publishing wind" "$LOG/env-sim.log"; then break; fi
  sleep 0.1
done

zig-out/bin/ai-sim > "$LOG/ai-sim.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do
  if grep -q "subscribed to" "$LOG/ai-sim.log"; then break; fi
  sleep 0.1
done

# Let ai-sim emit at least 2 period summaries (1 Hz). env.storms is
# 1 Hz so 3 seconds guarantees at least 2 receipts and 2 summary
# lines.
sleep 3

echo
echo "=== ai-sim log tail ==="
tail -20 "$LOG/ai-sim.log"

fail=0
# storm-msgs N (M storms) — assert N >= 1 and M >= 1.
last=$(grep -oE 'storm-msgs \([0-9]+ storms\)|storm-msgs [0-9]+' "$LOG/ai-sim.log" | tail -1 || true)
if [ -z "$last" ]; then
  echo "FAIL: ai-sim never logged a storm-msgs counter"
  fail=1
fi

# Pull every "N storm-msgs (M storms)" — accept any window where N>0.
got_msg=0
got_storms=0
while IFS= read -r line; do
  msgs=$(echo "$line" | sed -nE 's/.* ([0-9]+) storm-msgs \(([0-9]+) storms\).*/\1/p')
  storms=$(echo "$line" | sed -nE 's/.* ([0-9]+) storm-msgs \(([0-9]+) storms\).*/\2/p')
  if [ -n "$msgs" ] && [ "$msgs" -gt 0 ]; then got_msg=1; fi
  if [ -n "$storms" ] && [ "$storms" -gt 0 ]; then got_storms=1; fi
done < "$LOG/ai-sim.log"

if [ "$got_msg" -eq 1 ]; then
  echo "PASS: ai-sim received >= 1 env.storms publish in a 1 s window"
else
  echo "FAIL: ai-sim received 0 env.storms publishes across all windows"
  fail=1
fi
if [ "$got_storms" -eq 1 ]; then
  echo "PASS: ai-sim's snapshot has >= 1 storm (count from wind.yaml)"
else
  echo "FAIL: ai-sim's storm snapshot stayed empty"
  fail=1
fi

echo
echo ">>> logs in $LOG/."
exit "$fail"
