#!/usr/bin/env bash
# env-sim storms-as-cover smoke. Verifies env.storms is published at
# 1 Hz with addressable storm entities (Kind.storm = 0x04 top-byte
# tag), positions drifting between snapshots, and the count matching
# data/wind.yaml.
#
# Approach:
#   1. Start env-sim. wind_params.storms loaded from data/wind.yaml
#      (4 storms at v0).
#   2. Sniff env.storms --count=2 via nats-box.
#   3. Assert:
#      - both payloads parse and carry exactly 4 storms.
#      - every storm_id has top-byte 0x04 (Kind.storm).
#      - per-storm radius/strength/vortex_mix match YAML.
#      - at least one storm's position changes between snapshot 1
#        and snapshot 2 (drift speed_mps=6 over ~1 s = ~6 m of motion,
#        well above float noise).
#
# Usage:
#   ./scripts/storms_smoke.sh

set -euo pipefail
cd "$(dirname "$0")/.."

LOG=/tmp/notatlas-storms
mkdir -p "$LOG"
rm -f "$LOG"/*.log

echo ">>> storms-as-cover smoke"

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

zig-out/bin/env-sim > "$LOG/env-sim.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do
  if grep -q "publishing wind" "$LOG/env-sim.log"; then break; fi
  sleep 0.1
done

# Sniff two snapshots ~1 second apart (1 Hz publish).
$NATS_BOX nats sub -s nats://127.0.0.1:4222 'env.storms' --count=2 \
  > "$LOG/sniff.log" 2>&1

echo
echo "=== sniffed payloads ==="
grep -E '^\{' "$LOG/sniff.log" | tee "$LOG/payloads.jsonl" | head -2

python3 - "$LOG/payloads.jsonl" <<'PYEOF'
import json, sys

payloads = [json.loads(line) for line in open(sys.argv[1]) if line.strip().startswith("{")]
fail = 0

if len(payloads) < 2:
    print(f"FAIL: got {len(payloads)} payloads (expected >= 2)")
    sys.exit(1)

EXPECTED_COUNT = 4  # data/wind.yaml has 4 storms in v0

for i, p in enumerate(payloads):
    n = len(p.get("storms", []))
    if n != EXPECTED_COUNT:
        print(f"FAIL: payload {i} has {n} storms (expected {EXPECTED_COUNT})")
        fail = 1
    else:
        print(f"PASS: payload {i} has {EXPECTED_COUNT} storms")

# Top-byte = 0x04 (Kind.storm) on every storm_id.
for i, p in enumerate(payloads):
    for j, s in enumerate(p["storms"]):
        top_byte = (s["storm_id"] >> 24) & 0xFF
        if top_byte != 0x04:
            print(f"FAIL: payload {i} storm {j} top-byte=0x{top_byte:02x} (expected 0x04)")
            fail = 1
print(f"PASS: all storm_ids carry Kind.storm (0x04) top-byte tag")

# Static fields match YAML (radius=300, strength=10, vortex_mix=0.2 for all 4).
for i, p in enumerate(payloads):
    for j, s in enumerate(p["storms"]):
        if abs(s["radius_m"] - 300.0) > 0.01:
            print(f"FAIL: payload {i} storm {j} radius_m={s['radius_m']} (expected 300.0)")
            fail = 1
        if abs(s["strength_mps"] - 10.0) > 0.01:
            print(f"FAIL: payload {i} storm {j} strength_mps={s['strength_mps']} (expected 10.0)")
            fail = 1
        if abs(s["vortex_mix"] - 0.2) > 0.001:
            print(f"FAIL: payload {i} storm {j} vortex_mix={s['vortex_mix']} (expected 0.2)")
            fail = 1
print(f"PASS: per-storm static params match data/wind.yaml")

# At least one storm moved between snapshots (drift ~6 m/s × ~1 s).
moved = False
by_id_0 = {s["storm_id"]: s for s in payloads[0]["storms"]}
by_id_1 = {s["storm_id"]: s for s in payloads[1]["storms"]}
for sid, s0 in by_id_0.items():
    s1 = by_id_1.get(sid)
    if s1 is None:
        continue
    dx = s1["pos_x"] - s0["pos_x"]
    dz = s1["pos_z"] - s0["pos_z"]
    dist = (dx*dx + dz*dz) ** 0.5
    if dist > 1.0:
        moved = True
        print(f"PASS: storm 0x{sid:08x} drifted {dist:.2f} m between snapshots")
        break
if not moved:
    print(f"FAIL: no storm drifted > 1 m between snapshots")
    fail = 1

sys.exit(fail)
PYEOF
fail=$?

echo
echo ">>> logs in $LOG/."
exit "$fail"
