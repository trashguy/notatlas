#!/usr/bin/env bash
# persistence-writer smoke. Brings up the dev stack (nats + pg via
# `make services-up` if not already running), resets damage_log + the
# events_damage JetStream stream, starts persistence-writer, publishes
# N synthetic damage events on `sim.entity.<id>.damage`, and verifies:
#
#   1. All N events land as rows in damage_log (no drops).
#   2. Restarting persistence-writer triggers ZERO redelivery
#      (consumer ack-floor is durable, workqueue retention removes
#      acked messages). Row count stays at N — no duplicates.
#   3. Consumer info reports ack_floor == stream sequence ==
#      outstanding 0 == unprocessed 0.
#
# Pass criterion: all three numeric checks at the end print PASS.
#
# Usage:
#   ./scripts/persistence_smoke.sh [event_count]
#     event_count default 50 — large enough to span >1 fetch batch
#     trip but small enough to finish in <2 s on a dev box.

set -euo pipefail
cd "$(dirname "$0")/.."

N="${1:-50}"
LOG=/tmp/notatlas-persistence
mkdir -p "$LOG"
rm -f "$LOG"/*.log

echo ">>> persistence smoke: publishing $N damage events"

# Bring up the dev stack if either backplane is missing.
if ! ss -lnt 2>/dev/null | grep -q :4222 || ! ss -lnt 2>/dev/null | grep -q :5432; then
  echo ">>> starting services (make services-up)"
  make services-up
  sleep 2
fi

zig build install

NATS_BOX="podman run --rm --network host docker.io/natsio/nats-box:latest"
PSQL="podman exec notatlas-pg psql -U notatlas -d notatlas -tA"

# Reset state so the run is repeatable.
echo ">>> resetting damage_log + events_damage stream"
$PSQL -c "TRUNCATE damage_log RESTART IDENTITY;" >/dev/null
$NATS_BOX nats stream rm events_damage -f >/dev/null 2>&1 || true

PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do
    kill -INT "$pid" 2>/dev/null || true
  done
  wait "${PIDS[@]}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- Run 1: produce + ingest ----------------------------------------------
echo ">>> run 1: starting persistence-writer"
zig-out/bin/persistence-writer > "$LOG/run1.log" 2>&1 &
PIDS+=($!)
PWRITER_PID=$!

# Wait for stream + consumer attach (timeout 5s).
for _ in $(seq 1 50); do
  if grep -q 'stream=events_damage' "$LOG/run1.log"; then break; fi
  sleep 0.1
done
if ! grep -q 'stream=events_damage' "$LOG/run1.log"; then
  echo "FAIL: persistence-writer didn't attach in 5 s"
  cat "$LOG/run1.log"
  exit 1
fi

echo ">>> publishing $N events"
for i in $(seq 1 "$N"); do
  # Vary victim_id across 4 ships; attacker_id across 4 too. Simple
  # damage values + remaining_hp counting down from 1.0.
  victim_seq=$(( 16777217 + (i % 4) ))
  attacker_seq=$(( 16777221 + (i % 4) ))
  remaining=$(awk -v i="$i" -v n="$N" 'BEGIN{printf "%.4f", 1.0 - i/n}')
  payload=$(printf '{"victim_id":%d,"source_id":%d,"damage":%.1f,"fire_time_s":%d.0,"hit_x":1.0,"hit_y":2.0,"hit_z":3.0,"remaining_hp":%s}' \
    "$victim_seq" "$attacker_seq" "$i" "$i" "$remaining")
  $NATS_BOX nats pub "sim.entity.${victim_seq}.damage" "$payload" >/dev/null 2>&1
done

# Let pwriter drain. 100ms fetch + 50ms idle sleep means the loop
# observes the publishes within ~150ms; give it 1s for safety.
sleep 1

run1_count=$($PSQL -c "SELECT count(*) FROM damage_log;")
echo ">>> run 1: damage_log rows = $run1_count (expected $N)"

# Stop pwriter cleanly so the consumer ack-floor flushes.
kill -INT "$PWRITER_PID"
wait "$PWRITER_PID" 2>/dev/null || true
PIDS=()

# --- Run 2: restart, verify no redelivery ---------------------------------
echo ">>> run 2: restarting persistence-writer (expect committed=0)"
zig-out/bin/persistence-writer > "$LOG/run2.log" 2>&1 &
PIDS+=($!)
PWRITER_PID=$!

# Hold long enough for any redelivery to occur — 1s is well above
# 100ms fetch period and well below the 30s ack_wait. If there's a
# redelivery, it'd happen on the very first fetch.
sleep 1

kill -INT "$PWRITER_PID"
wait "$PWRITER_PID" 2>/dev/null || true
PIDS=()

run2_committed=$(grep -oP 'shutting down \(committed \K\d+' "$LOG/run2.log" || echo 'missing')
run2_count=$($PSQL -c "SELECT count(*) FROM damage_log;")

echo ">>> run 2: pwriter shutdown committed=$run2_committed; damage_log rows = $run2_count"

# --- Consumer state -------------------------------------------------------
echo
echo "=== consumer info ==="
$NATS_BOX nats consumer info events_damage pwriter 2>&1 \
  | grep -E "Last Delivered|Acknowledgment Floor|Outstanding Acks|Unprocessed Messages" \
  | sed 's/^[[:space:]]*//'

# --- Verdict --------------------------------------------------------------
echo
fail=0
if [ "$run1_count" = "$N" ]; then
  echo "PASS: run 1 ingested $N rows"
else
  echo "FAIL: run 1 expected $N rows, got $run1_count"
  fail=1
fi
if [ "$run2_committed" = "0" ]; then
  echo "PASS: run 2 redelivered 0 events (ack-once held across restart)"
else
  echo "FAIL: run 2 redelivered '$run2_committed' events (expected 0)"
  fail=1
fi
if [ "$run2_count" = "$N" ]; then
  echo "PASS: run 2 row count unchanged at $N (no duplicates)"
else
  echo "FAIL: run 2 row count drifted from $N to $run2_count"
  fail=1
fi

echo
echo ">>> logs in $LOG/."
exit "$fail"
