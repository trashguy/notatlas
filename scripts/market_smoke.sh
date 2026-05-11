#!/usr/bin/env bash
# market-sim end-to-end smoke. Verifies the third real SLA-arc producer:
#
#   1. services-up + start persistence-writer (consumes
#      events.market.trade → market_trades PG).
#   2. start market-sim (subscribes to market.order.submit).
#   3. seed two characters; publish a buy and a matching sell.
#   4. assert: exactly one market_trades row with the right
#      buyer/seller/item/quantity/price. Resting wins on price.
#
# Also verifies partial fill: a second wave submits a buy of 5
# against a resting sell of 3 — expect one extra row of qty=3,
# leftover 2 rests as a bid.
#
# Pass criterion (PG, hard-asserted): 2 market_trades rows total
# (one simple fill + one partial-fill chunk), distinct stream_seq.
#
# Usage:
#   ./scripts/market_smoke.sh

set -euo pipefail
cd "$(dirname "$0")/.."

LOG=/tmp/notatlas-market
mkdir -p "$LOG"
rm -f "$LOG"/*.log

BUYER_ID=101
SELLER_ID=102
ITEM_ID=42

echo ">>> market smoke: buyer=$BUYER_ID seller=$SELLER_ID item=$ITEM_ID"

if ! ss -lnt 2>/dev/null | grep -q :4222 || ! ss -lnt 2>/dev/null | grep -q :5432; then
  echo ">>> starting services (make services-up)"
  make services-up
  sleep 2
fi

zig build install

NATS_BOX="podman run --rm --network host docker.io/natsio/nats-box:latest"
PSQL="podman exec -i notatlas-pg psql -U notatlas -d notatlas -tA"

# Seed two characters (one per account — characters has
# UNIQUE(account_id, cycle_id), v0 = one character per account
# per cycle) against the current cycle (ends_at IS NULL).
echo ">>> seeding accounts + characters in current cycle"
CYCLE_ID=$($PSQL -c "SELECT id FROM wipe_cycles WHERE ends_at IS NULL;")
echo "    current cycle_id=$CYCLE_ID"
$PSQL >/dev/null <<SQL
INSERT INTO accounts (id, username, pass_hash) VALUES
  (200, 'market_smoke_buyer',  E'\\\\x00'),
  (201, 'market_smoke_seller', E'\\\\x00')
  ON CONFLICT (id) DO NOTHING;
INSERT INTO characters (id, account_id, cycle_id, name) VALUES
  ($BUYER_ID,  200, $CYCLE_ID, 'buyer_$CYCLE_ID'),
  ($SELLER_ID, 201, $CYCLE_ID, 'seller_$CYCLE_ID')
  ON CONFLICT (id) DO NOTHING;
SELECT setval('accounts_id_seq',   GREATEST((SELECT MAX(id) FROM accounts), 1));
SELECT setval('characters_id_seq', GREATEST((SELECT MAX(id) FROM characters), 1));
SQL

echo ">>> resetting market_trades + events_market_trade stream"
$PSQL -c "TRUNCATE market_trades RESTART IDENTITY CASCADE;" >/dev/null
$NATS_BOX nats stream rm events_market_trade -f >/dev/null 2>&1 || true

PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do
    kill -INT "$pid" 2>/dev/null || true
  done
  wait "${PIDS[@]}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo ">>> starting persistence-writer"
zig-out/bin/persistence-writer > "$LOG/pwriter.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do
  if grep -q 'events_market_trade.*ready' "$LOG/pwriter.log"; then break; fi
  sleep 0.1
done
if ! grep -q 'events_market_trade.*ready' "$LOG/pwriter.log"; then
  echo "FAIL: pwriter didn't attach events_market_trade in 5s"; cat "$LOG/pwriter.log"; exit 1
fi

echo ">>> starting market-sim"
zig-out/bin/market-sim > "$LOG/market-sim.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do
  if grep -q 'subscribed to market.order.submit' "$LOG/market-sim.log"; then break; fi
  sleep 0.1
done
if ! grep -q 'subscribed to market.order.submit' "$LOG/market-sim.log"; then
  echo "FAIL: market-sim didn't subscribe in 5s"; cat "$LOG/market-sim.log"; exit 1
fi

# ---------------------------------------------------------------------------
# Scenario 1 — simple full-cross at resting price.
#   Resting sell @95 of 5, aggressor buy @100 of 5 → trade at 95.
# ---------------------------------------------------------------------------
echo ">>> scenario 1: full cross (resting sell @95 vs aggressor buy @100)"
publish_order() {
  local char="$1" side="$2" qty="$3" price="$4"
  local payload
  payload=$(printf '{"character_id":%d,"side":%d,"item_def_id":%d,"quantity":%d,"price":%d,"cell_x":0,"cell_y":0}' \
    "$char" "'$side'" "$ITEM_ID" "$qty" "$price")
  $NATS_BOX nats pub -s nats://127.0.0.1:4222 'market.order.submit' "$payload" >/dev/null 2>&1
}

publish_order $SELLER_ID S 5 95
sleep 0.2
publish_order $BUYER_ID  B 5 100
sleep 0.5  # let pwriter drain

# ---------------------------------------------------------------------------
# Scenario 2 — partial fill.
#   Resting sell of 3 @100, aggressor buy of 5 @100 → trade for 3.
#   Leftover 2 rests as a bid; no further trades.
# ---------------------------------------------------------------------------
echo ">>> scenario 2: partial fill (resting sell qty=3 vs aggressor buy qty=5)"
publish_order $SELLER_ID S 3 100
sleep 0.2
publish_order $BUYER_ID  B 5 100
sleep 0.5  # let pwriter drain

# ---------------------------------------------------------------------------
# Assertions.
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

total=$($PSQL -c "SELECT count(*) FROM market_trades;")
check_eq "market_trades total row count" "$total" "2"

# Scenario 1 — the @95 fill.
s1_count=$($PSQL -c \
  "SELECT count(*) FROM market_trades WHERE buyer_id=$BUYER_ID AND seller_id=$SELLER_ID \
   AND item_def_id=$ITEM_ID AND quantity=5 AND price=95;")
check_eq "scenario 1 row (qty=5 @95)" "$s1_count" "1"

# Scenario 2 — the @100 partial fill of 3.
s2_count=$($PSQL -c \
  "SELECT count(*) FROM market_trades WHERE buyer_id=$BUYER_ID AND seller_id=$SELLER_ID \
   AND item_def_id=$ITEM_ID AND quantity=3 AND price=100;")
check_eq "scenario 2 row (qty=3 @100)" "$s2_count" "1"

# Order ids are 0 in v0 → NULL via pwriter's order_id==0 → NULL map.
null_orders=$($PSQL -c \
  "SELECT count(*) FROM market_trades WHERE buy_order_id IS NULL AND sell_order_id IS NULL;")
check_eq "both rows have NULL order ids (v0 doesn't persist orders)" "$null_orders" "2"

# stream_seq UNIQUE invariant.
distinct_seq=$($PSQL -c "SELECT count(DISTINCT stream_seq) FROM market_trades;")
check_eq "distinct stream_seq" "$distinct_seq" "$total"

echo
echo ">>> logs in $LOG/."
exit "$fail"
