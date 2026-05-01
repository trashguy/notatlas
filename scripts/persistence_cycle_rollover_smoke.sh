#!/usr/bin/env bash
# persistence-writer cycle-rollover smoke. Verifies that publishing
# `admin.cycle.changed` causes pwriter to re-probe the DB and use the
# new cycle_id on subsequent inserts WITHOUT a service restart.
#
# Flow:
#   1. Seed cycle 1 (S0-dev, already there) + an account/character.
#   2. Start pwriter — boots on cycle 1.
#   3. Publish 3 damage events → assert all land with cycle_id=1.
#   4. Close cycle 1, open cycle 2 in wipe_cycles.
#   5. Publish admin.cycle.changed (payload arbitrary; pwriter re-
#      probes the DB rather than trusting the message).
#   6. Publish 3 more damage events → assert these land with cycle_id=2.
#   7. Stop pwriter.
#
# Pass criteria:
#   - 3 rows with cycle_id=1, 3 rows with cycle_id=2, no other rows.
#   - pwriter's stdout shows "cycle rolled 1 -> 2".

set -euo pipefail
cd "$(dirname "$0")/.."

LOG=/tmp/notatlas-persistence-cycle
mkdir -p "$LOG"
rm -f "$LOG"/*.log

if ! ss -lnt 2>/dev/null | grep -q :4222 || ! ss -lnt 2>/dev/null | grep -q :5432; then
  echo ">>> starting services (make services-up)"
  make services-up
  sleep 2
fi

zig build install

NATS_BOX="podman run --rm --network host docker.io/natsio/nats-box:latest"
PSQL="podman exec -i notatlas-pg psql -U notatlas -d notatlas -tA"

# ---------------------------------------------------------------------------
# Reset to a known cycle-1-only state. Truncating wipe_cycles cascades
# through every wipe-scoped table (intended), so we re-seed afterwards.
# ---------------------------------------------------------------------------
echo ">>> resetting cycle state"
$PSQL >/dev/null <<'SQL'
TRUNCATE wipe_cycles RESTART IDENTITY CASCADE;
INSERT INTO wipe_cycles (id, label, started_at) VALUES (1, 'S0-dev', NOW());
SELECT setval('wipe_cycles_id_seq', 1);
INSERT INTO accounts (id, username, pass_hash) VALUES (1, 'cycle_smoke', E'\\x00')
ON CONFLICT (id) DO NOTHING;
INSERT INTO characters (id, account_id, cycle_id, name) VALUES (1, 1, 1, 'cycle_smoke_char')
ON CONFLICT (id) DO NOTHING;
SELECT setval('accounts_id_seq', GREATEST((SELECT MAX(id) FROM accounts), 1));
SELECT setval('characters_id_seq', GREATEST((SELECT MAX(id) FROM characters), 1));
SQL

for s in events_damage events_market_trade events_handoff_cell events_inventory_change; do
  $NATS_BOX nats stream rm "$s" -f >/dev/null 2>&1 || true
done

PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do
    kill -INT "$pid" 2>/dev/null || true
  done
  wait "${PIDS[@]}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Start pwriter on cycle 1.
# ---------------------------------------------------------------------------
echo ">>> starting pwriter"
zig-out/bin/persistence-writer > "$LOG/pwriter.log" 2>&1 &
PIDS+=($!)
PWRITER_PID=$!

# Wait for stream attach.
for _ in $(seq 1 50); do
  if grep -q 'events_inventory_change.*ready' "$LOG/pwriter.log"; then break; fi
  sleep 0.1
done
if ! grep -q 'events_inventory_change.*ready' "$LOG/pwriter.log"; then
  echo "FAIL: pwriter didn't attach in 5 s"
  exit 1
fi

# Use handoff events as the cycle-id witness — pwriter writes
# cell_handoffs.cycle_id from its cached value, so a flip is observable.
# (Damage no longer goes through pwriter; handoff is the simplest
# stand-in with no FK requirements.)

# ---------------------------------------------------------------------------
# Phase A: 3 handoff events while on cycle 1.
# ---------------------------------------------------------------------------
echo ">>> phase A: publishing 3 handoff events on cycle 1"
for i in 1 2 3; do
  $NATS_BOX nats pub "events.handoff.cell" \
    "$(printf '{"entity_id":%d,"from_cell_x":0,"from_cell_y":0,"to_cell_x":1,"to_cell_y":0,"pos_x":%d.0,"pos_y":0.0,"pos_z":0.0}' "$((16777217+i))" "$((200+i))")" >/dev/null 2>&1
done
sleep 1

# ---------------------------------------------------------------------------
# Phase B: close cycle 1, open cycle 2, notify pwriter.
# ---------------------------------------------------------------------------
echo ">>> phase B: rolling cycle 1 -> 2"
$PSQL >/dev/null <<'SQL'
UPDATE wipe_cycles SET ends_at = NOW() WHERE id = 1;
INSERT INTO wipe_cycles (id, label, started_at) VALUES (2, 'S1-test', NOW());
SELECT setval('wipe_cycles_id_seq', 2);
SQL

$NATS_BOX nats pub "admin.cycle.changed" '{"cycle_id":2,"label":"S1-test"}' >/dev/null 2>&1
sleep 0.5  # let pwriter dispatch the cycle-changed message

# ---------------------------------------------------------------------------
# Phase C: 3 handoff events that should land on cycle 2.
# ---------------------------------------------------------------------------
echo ">>> phase C: publishing 3 handoff events on cycle 2"
for i in 4 5 6; do
  $NATS_BOX nats pub "events.handoff.cell" \
    "$(printf '{"entity_id":%d,"from_cell_x":0,"from_cell_y":0,"to_cell_x":1,"to_cell_y":0,"pos_x":%d.0,"pos_y":0.0,"pos_z":0.0}' "$((16777217+i))" "$((200+i))")" >/dev/null 2>&1
done
sleep 1

kill -INT "$PWRITER_PID"
wait "$PWRITER_PID" 2>/dev/null || true
PIDS=()

# ---------------------------------------------------------------------------
# Verdict.
# ---------------------------------------------------------------------------
cycle1_count=$($PSQL -c "SELECT count(*) FROM cell_handoffs WHERE cycle_id=1;")
cycle2_count=$($PSQL -c "SELECT count(*) FROM cell_handoffs WHERE cycle_id=2;")
total_count=$($PSQL -c "SELECT count(*) FROM cell_handoffs;")

echo
echo "=== row distribution ==="
$PSQL -c "SELECT cycle_id, count(*) FROM cell_handoffs GROUP BY cycle_id ORDER BY cycle_id;"
echo
echo "=== pwriter cycle-roll log ==="
grep -E 'cycle rolled|current cycle' "$LOG/pwriter.log" || echo "(no cycle log lines!)"
echo

fail=0
check() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $label = $actual"
  else
    echo "FAIL: $label = $actual (expected $expected)"
    fail=1
  fi
}
check "cycle 1 rows" "$cycle1_count" "3"
check "cycle 2 rows" "$cycle2_count" "3"
check "total rows"   "$total_count"  "6"
if grep -q 'cycle rolled 1 -> 2' "$LOG/pwriter.log"; then
  echo "PASS: pwriter logged the cycle roll"
else
  echo "FAIL: pwriter did not log 'cycle rolled 1 -> 2'"
  fail=1
fi

echo
echo ">>> logs in $LOG/."
exit "$fail"
