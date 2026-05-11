#!/usr/bin/env bash
# env-sim time-of-day smoke. Verifies env.time is published at 1 Hz
# with monotonic world_time_s and a day_fraction in [0,1) that
# advances as expected for a short --day-length-s.
#
# Approach:
#   1. Start env-sim --day-length-s 10 (10-second day so two 1 Hz
#      ticks span ~10% of the cycle — day_fraction delta visible).
#   2. Sniff env.time --count=3 via nats-box.
#   3. Assert: all three messages parse; world_time_s strictly
#      increases; each day_fraction is in [0,1); the delta between
#      consecutive day_fractions matches the expected ~0.1 (within
#      slop for scheduler jitter).
#
# Usage:
#   ./scripts/time_of_day_smoke.sh

set -euo pipefail
cd "$(dirname "$0")/.."

LOG=/tmp/notatlas-tod
mkdir -p "$LOG"
rm -f "$LOG"/*.log

echo ">>> time-of-day smoke (--day-length-s 10)"

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

zig-out/bin/env-sim --day-length-s 10 > "$LOG/env-sim.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do
  if grep -q "publishing wind" "$LOG/env-sim.log"; then break; fi
  sleep 0.1
done

$NATS_BOX nats sub -s nats://127.0.0.1:4222 'env.time' --count=3 \
  > "$LOG/sniff.log" 2>&1

echo
echo "=== sniffed payloads ==="
grep -E '^\{' "$LOG/sniff.log" | tee "$LOG/payloads.jsonl"

python3 - "$LOG/payloads.jsonl" <<'PYEOF'
import json, sys

payloads = [json.loads(line) for line in open(sys.argv[1]) if line.strip().startswith("{")]
fail = 0

if len(payloads) < 3:
    print(f"FAIL: got {len(payloads)} payloads (expected >= 3)")
    sys.exit(1)

# Pairwise monotonic world_time_s
for i in range(1, len(payloads)):
    if payloads[i]["world_time_s"] <= payloads[i-1]["world_time_s"]:
        print(f"FAIL: world_time_s not monotonic at i={i}: {payloads[i-1]['world_time_s']} -> {payloads[i]['world_time_s']}")
        fail = 1
print(f"PASS: world_time_s is monotonic across {len(payloads)} samples")

# day_fraction in [0, 1)
for i, p in enumerate(payloads):
    df = p["day_fraction"]
    if not (0.0 <= df < 1.0):
        print(f"FAIL: payload {i} day_fraction={df} not in [0,1)")
        fail = 1
print(f"PASS: all day_fraction values in [0, 1)")

# Consecutive delta should be ~ 1.0 / day_length_s = 0.1 per tick.
# Allow scheduler slop: accept [0.05, 0.20] per second.
for i in range(1, len(payloads)):
    delta = payloads[i]["day_fraction"] - payloads[i-1]["day_fraction"]
    # If the fraction wrapped (very short day + fast iter), ignore.
    if delta < 0:
        delta += 1.0
    if not (0.05 <= delta <= 0.20):
        print(f"FAIL: day_fraction delta at i={i} = {delta:.3f} (expected ~0.1, tolerance 0.05-0.20)")
        fail = 1
    else:
        print(f"PASS: day_fraction delta at i={i} = {delta:.3f}")

sys.exit(fail)
PYEOF
fail=$?

echo
echo ">>> logs in $LOG/."
exit "$fail"
