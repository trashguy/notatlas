#!/usr/bin/env bash
# persistence-writer smoke. Exercises the 3 streams the service drains:
#
#   events_market_trade     events.market.trade         → market_trades
#   events_handoff_cell     events.handoff.cell         → cell_handoffs
#   events_inventory_change events.inventory.change.*   → inventories
#
# (Damage is intentionally NOT in pwriter — too volume-heavy for
# row-per-event PG, only useful queries are aggregates. See memory
# architecture_damage_not_in_pg.md.)
#
# For each stream: publish N synthetic events, verify N rows land,
# restart pwriter, verify ZERO redelivery (workqueue ack-once held).
# Inventory is upsert (one row regardless of N publishes), so it has
# a separate assertion.
#
# Usage:
#   ./scripts/persistence_smoke.sh [event_count]
#     event_count default 10. Total publishes = N * 2 (market +
#     handoff) + N inventory updates that all collapse to 1 row.

set -euo pipefail
cd "$(dirname "$0")/.."

N="${1:-10}"
LOG=/tmp/notatlas-persistence
mkdir -p "$LOG"
rm -f "$LOG"/*.log

echo ">>> persistence smoke: $N events per stream"

if ! ss -lnt 2>/dev/null | grep -q :4222 || ! ss -lnt 2>/dev/null | grep -q :5432; then
  echo ">>> starting services (make services-up)"
  make services-up
  sleep 2
fi

zig build install

NATS_BOX="podman run --rm --network host docker.io/natsio/nats-box:latest"
PSQL="podman exec -i notatlas-pg psql -U notatlas -d notatlas -tA"

# ---------------------------------------------------------------------------
# Setup test fixtures.
# ---------------------------------------------------------------------------
echo ">>> seeding fixtures (account + character)"
$PSQL >/dev/null <<'SQL'
INSERT INTO accounts (id, username, pass_hash)
VALUES (1, 'smoke', E'\\x00')
ON CONFLICT (id) DO NOTHING;
INSERT INTO characters (id, account_id, cycle_id, name)
VALUES (1, 1, 1, 'smoke_char')
ON CONFLICT (id) DO NOTHING;
SELECT setval('accounts_id_seq', GREATEST((SELECT MAX(id) FROM accounts), 1));
SELECT setval('characters_id_seq', GREATEST((SELECT MAX(id) FROM characters), 1));
SQL

echo ">>> resetting tables + streams"
$PSQL -c "TRUNCATE market_trades, cell_handoffs, inventories RESTART IDENTITY CASCADE;" >/dev/null
for s in events_market_trade events_handoff_cell events_inventory_change; do
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
# Run 1: produce + ingest.
# ---------------------------------------------------------------------------
echo ">>> run 1: starting persistence-writer"
zig-out/bin/persistence-writer > "$LOG/run1.log" 2>&1 &
PIDS+=($!)
PWRITER_PID=$!

# Wait for all 3 streams to attach.
for _ in $(seq 1 50); do
  if grep -q 'events_inventory_change.*ready' "$LOG/run1.log"; then break; fi
  sleep 0.1
done
if ! grep -q 'events_inventory_change.*ready' "$LOG/run1.log"; then
  echo "FAIL: not all streams attached in 5 s"
  cat "$LOG/run1.log"
  exit 1
fi

echo ">>> publishing $N events per stream"
for i in $(seq 1 "$N"); do
  victim=$(( 16777217 + (i % 4) ))

  $NATS_BOX nats pub "events.market.trade" \
    "$(printf '{"buy_order_id":0,"sell_order_id":0,"buyer_id":1,"seller_id":1,"item_def_id":%d,"quantity":%d,"price":%d}' "$((100+i))" "$i" "$((i*50))")" >/dev/null 2>&1

  $NATS_BOX nats pub "events.handoff.cell" \
    "$(printf '{"entity_id":%d,"from_cell_x":0,"from_cell_y":0,"to_cell_x":1,"to_cell_y":0,"pos_x":%.1f,"pos_y":0.0,"pos_z":0.0}' "$victim" "$(awk -v i="$i" 'BEGIN{printf "%.1f", 200.0 + i}')")" >/dev/null 2>&1

  # Inventory: every publish updates the SAME character row. Final
  # state should be the last blob written (slots field = $i).
  $NATS_BOX nats pub "events.inventory.change.1" \
    "$(printf '{"slots":[{"slot":0,"item_def_id":42,"quantity":%d}]}' "$i")" >/dev/null 2>&1
done

# Drain time. 3 streams × 25 ms fetch ≈ 75 ms round-robin; allow 1.5 s.
sleep 1.5

market_count=$($PSQL -c "SELECT count(*) FROM market_trades;")
handoff_count=$($PSQL -c "SELECT count(*) FROM cell_handoffs;")
inv_count=$($PSQL -c "SELECT count(*) FROM inventories;")
inv_version=$($PSQL -c "SELECT COALESCE(version, 0) FROM inventories WHERE character_id=1;")

echo ">>> run 1 row counts:"
echo "    market_trades: $market_count (expected $N)"
echo "    cell_handoffs: $handoff_count (expected $N)"
echo "    inventories:   $inv_count (expected 1, version $inv_version expected $N)"

# Stop pwriter so the consumer ack-floor flushes.
kill -INT "$PWRITER_PID"
wait "$PWRITER_PID" 2>/dev/null || true
PIDS=()

# ---------------------------------------------------------------------------
# Run 2: restart, verify no redelivery on ANY stream.
# ---------------------------------------------------------------------------
echo ">>> run 2: restarting persistence-writer (expect all-zero committed)"
zig-out/bin/persistence-writer > "$LOG/run2.log" 2>&1 &
PIDS+=($!)
PWRITER_PID=$!

sleep 1

kill -INT "$PWRITER_PID"
wait "$PWRITER_PID" 2>/dev/null || true
PIDS=()

run2_line=$(grep "shutting down" "$LOG/run2.log" || echo "missing")
echo ">>> run 2 final: $run2_line"

post_market=$($PSQL -c "SELECT count(*) FROM market_trades;")
post_handoff=$($PSQL -c "SELECT count(*) FROM cell_handoffs;")
post_inv=$($PSQL -c "SELECT count(*) FROM inventories;")

# ---------------------------------------------------------------------------
# Verdict.
# ---------------------------------------------------------------------------
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
check "run 1 market_trades" "$market_count" "$N"
check "run 1 cell_handoffs" "$handoff_count" "$N"
check "run 1 inventories"   "$inv_count"    "1"
check "run 1 inv version"   "$inv_version"  "$N"

# Run 2: redelivered counters all zero.
if echo "$run2_line" | grep -qE 'market=0 handoff=0 inv=0'; then
  echo "PASS: run 2 redelivered 0 events on all 3 streams"
else
  echo "FAIL: run 2 redelivered events: $run2_line"
  fail=1
fi
check "run 2 market_trades unchanged" "$post_market"  "$N"
check "run 2 cell_handoffs unchanged" "$post_handoff" "$N"
check "run 2 inventories unchanged"   "$post_inv"     "1"

echo
echo ">>> logs in $LOG/."
exit "$fail"
