#!/usr/bin/env bash
# persistence-writer dedup-on-redelivery smoke.
#
# Verifies the stream_seq idempotency path: when JetStream redelivers a
# message that pwriter has already inserted, the second attempt MUST
# collapse to a no-op via INSERT ... ON CONFLICT (stream_seq) DO NOTHING.
# Row counts stay correct; dedup_skipped counter goes up.
#
# How we force redelivery deterministically (production redelivery is
# triggered by ack_wait expiry on un-acked messages, which is a 5-minute
# wait by default):
#
#   1. Run pwriter with `--no-ack --ack-wait-s 3`. Inserts land but
#      nothing gets acked, so every message stays "in-flight" with a
#      3-second timer.
#   2. Kill pwriter (graceful is fine — un-acked messages survive).
#   3. Sleep > 3s so the broker times out every in-flight ack.
#   4. Restart pwriter normally (no --no-ack). Broker redelivers all
#      previously-un-acked messages.
#   5. Assert: row counts unchanged, dedup_skipped covers every
#      redelivered message.
#
# This proves the dedup path under realistic conditions without racing
# pwriter's own ack code path.
#
# Usage:
#   ./scripts/persistence_dedup_smoke.sh [event_count]
#     event_count default 8.

set -euo pipefail
cd "$(dirname "$0")/.."

N="${1:-8}"
LOG=/tmp/notatlas-persistence-dedup
mkdir -p "$LOG"
rm -f "$LOG"/*.log

echo ">>> dedup smoke: $N events per stream"

if ! ss -lnt 2>/dev/null | grep -q :4222 || ! ss -lnt 2>/dev/null | grep -q :5432; then
  echo ">>> starting services (make services-up)"
  make services-up
  sleep 2
fi

zig build install

NATS_BOX="podman run --rm --network host docker.io/natsio/nats-box:latest"
PSQL="podman exec -i notatlas-pg psql -U notatlas -d notatlas -tA"

echo ">>> seeding fixtures"
$PSQL >/dev/null <<'SQL'
INSERT INTO accounts (id, username, pass_hash) VALUES (1, 'smoke', E'\\x00')
  ON CONFLICT (id) DO NOTHING;
INSERT INTO characters (id, account_id, cycle_id, name) VALUES (1, 1, 1, 'smoke_char')
  ON CONFLICT (id) DO NOTHING;
SELECT setval('accounts_id_seq', GREATEST((SELECT MAX(id) FROM accounts), 1));
SELECT setval('characters_id_seq', GREATEST((SELECT MAX(id) FROM characters), 1));
SQL

echo ">>> resetting tables + streams (consumer ack_wait will be re-declared @ 3s)"
$PSQL -c "TRUNCATE sessions, market_trades, cell_handoffs, inventories RESTART IDENTITY CASCADE;" >/dev/null
for s in events_session events_market_trade events_handoff_cell events_inventory_change; do
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
# Phase 1: ingest with --no-ack so messages stay outstanding.
# ---------------------------------------------------------------------------
echo ">>> phase 1: pwriter --no-ack --ack-wait-s 3 (inserts but doesn't ack)"
zig-out/bin/persistence-writer --no-ack --ack-wait-s 3 > "$LOG/run1.log" 2>&1 &
PIDS+=($!)
PWRITER_PID=$!

for _ in $(seq 1 50); do
  if grep -q 'events_inventory_change.*ready' "$LOG/run1.log"; then break; fi
  sleep 0.1
done
if ! grep -q 'events_inventory_change.*ready' "$LOG/run1.log"; then
  echo "FAIL: streams not attached"; cat "$LOG/run1.log"; exit 1
fi

echo ">>> publishing $N events per stream"
for i in $(seq 1 "$N"); do
  victim=$(( 16777217 + (i % 4) ))
  $NATS_BOX nats pub "events.session" \
    "$(printf '{"account_id":1,"character_id":1,"kind":"login"}')" >/dev/null 2>&1
  $NATS_BOX nats pub "events.market.trade" \
    "$(printf '{"buy_order_id":0,"sell_order_id":0,"buyer_id":1,"seller_id":1,"item_def_id":%d,"quantity":%d,"price":%d}' "$((100+i))" "$i" "$((i*50))")" >/dev/null 2>&1
  $NATS_BOX nats pub "events.handoff.cell" \
    "$(printf '{"entity_id":%d,"from_cell_x":0,"from_cell_y":0,"to_cell_x":1,"to_cell_y":0,"pos_x":%.1f,"pos_y":0.0,"pos_z":0.0}' "$victim" "$(awk -v i="$i" 'BEGIN{printf "%.1f", 200.0 + i}')")" >/dev/null 2>&1
  $NATS_BOX nats pub "events.inventory.change.1" \
    "$(printf '{"slots":[{"slot":0,"item_def_id":42,"quantity":%d}]}' "$i")" >/dev/null 2>&1
done

# Wait for inserts to land.
sleep 1.5

phase1_session=$($PSQL -c "SELECT count(*) FROM sessions;")
phase1_market=$($PSQL -c "SELECT count(*) FROM market_trades;")
phase1_handoff=$($PSQL -c "SELECT count(*) FROM cell_handoffs;")
phase1_inv=$($PSQL -c "SELECT count(*) FROM inventories;")

echo ">>> phase 1 row counts (should equal $N for relational, 1 for inv):"
echo "    sessions=$phase1_session market=$phase1_market handoff=$phase1_handoff inv=$phase1_inv"

# Kill pwriter cleanly. --no-ack means broker still has all 4*N messages outstanding.
kill -INT "$PWRITER_PID"
wait "$PWRITER_PID" 2>/dev/null || true
PIDS=()

# Sleep > ack_wait so broker times out every outstanding ack.
echo ">>> sleeping 5s for ack_wait expiry"
sleep 5

# ---------------------------------------------------------------------------
# Phase 2: restart normally; broker redelivers; dedup MUST hit.
# ---------------------------------------------------------------------------
echo ">>> phase 2: restart pwriter normally (broker will redeliver)"
zig-out/bin/persistence-writer > "$LOG/run2.log" 2>&1 &
PIDS+=($!)
PWRITER_PID=$!

for _ in $(seq 1 50); do
  if grep -q 'events_inventory_change.*ready' "$LOG/run2.log"; then break; fi
  sleep 0.1
done

# Wait for redelivery + drain. ack_wait was 3s; broker queues redeliveries
# rapidly once the consumer is alive. 6s is comfortable.
sleep 6

# Capture status snapshot to read the dedup_skipped counters.
echo ">>> capturing admin.pwriter.status snapshot"
status=$($NATS_BOX nats sub admin.pwriter.status --count=1 --timeout 8s 2>&1 | grep -E '^\{' | head -1)
echo "    $status"

kill -INT "$PWRITER_PID"
wait "$PWRITER_PID" 2>/dev/null || true
PIDS=()

post_session=$($PSQL -c "SELECT count(*) FROM sessions;")
post_market=$($PSQL -c "SELECT count(*) FROM market_trades;")
post_handoff=$($PSQL -c "SELECT count(*) FROM cell_handoffs;")
post_inv=$($PSQL -c "SELECT count(*) FROM inventories;")

echo ">>> phase 2 row counts (must be UNCHANGED from phase 1):"
echo "    sessions=$post_session market=$post_market handoff=$post_handoff inv=$post_inv"

# Extract dedup_skipped per stream from the JSON snapshot. Hand-roll
# rather than pull jq into the smoke deps.
extract_dedup() {
  local label="$1"
  echo "$status" | grep -oE "\"name\":\"$label\"[^}]*" | grep -oE '"dedup_skipped":[0-9]+' | grep -oE '[0-9]+'
}
dedup_session=$(extract_dedup "session" || echo 0)
dedup_market=$(extract_dedup "market" || echo 0)
dedup_handoff=$(extract_dedup "handoff" || echo 0)
dedup_inv=$(extract_dedup "inv" || echo 0)
dedup_session=${dedup_session:-0}
dedup_market=${dedup_market:-0}
dedup_handoff=${dedup_handoff:-0}
dedup_inv=${dedup_inv:-0}

echo ">>> dedup_skipped snapshot per stream:"
echo "    session=$dedup_session market=$dedup_market handoff=$dedup_handoff inv=$dedup_inv"

# ---------------------------------------------------------------------------
# Verdict.
# ---------------------------------------------------------------------------
echo
fail=0
check_eq() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $label = $actual"
  else
    echo "FAIL: $label = $actual (expected $expected)"
    fail=1
  fi
}
check_ge() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" -ge "$expected" ]; then
    echo "PASS: $label = $actual (≥ $expected)"
  else
    echo "FAIL: $label = $actual (expected ≥ $expected)"
    fail=1
  fi
}

check_eq "phase 1 sessions"  "$phase1_session" "$N"
check_eq "phase 1 market"    "$phase1_market"  "$N"
check_eq "phase 1 handoff"   "$phase1_handoff" "$N"
check_eq "phase 1 inventories" "$phase1_inv"   "1"

# Row counts must NOT increase across phase 2 — every redelivery hit ON CONFLICT.
check_eq "phase 2 sessions unchanged" "$post_session"  "$phase1_session"
check_eq "phase 2 market unchanged"   "$post_market"   "$phase1_market"
check_eq "phase 2 handoff unchanged"  "$post_handoff"  "$phase1_handoff"
check_eq "phase 2 inv unchanged"      "$post_inv"      "$phase1_inv"

# dedup_skipped must equal N for relational streams (every message
# was redelivered and hit ON CONFLICT). Inventory uses UPSERT and
# always returns .inserted, so its dedup_skipped is 0 regardless.
check_eq "session dedup_skipped" "$dedup_session" "$N"
check_eq "market dedup_skipped"  "$dedup_market"  "$N"
check_eq "handoff dedup_skipped" "$dedup_handoff" "$N"
check_eq "inv dedup_skipped (upsert is content-idempotent, 0 expected)" "$dedup_inv" "0"

echo
echo ">>> logs in $LOG/."
exit "$fail"
