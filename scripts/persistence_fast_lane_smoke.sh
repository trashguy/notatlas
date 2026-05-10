#!/usr/bin/env bash
# persistence-writer fast-lane priority smoke.
#
# Verifies the tier=fast streams drain BEFORE tier=slow streams when
# both have backlog. Concretely: pre-fill a large backlog of slow-tier
# events (market_trades) plus a small batch of fast-tier events
# (sessions), then start pwriter and watch which stream fully drains
# first.
#
# Architectural property under test: per-iteration, pwriter drains the
# ENTIRE fast-lane backlog before touching slow streams. So fast-lane
# committed[N] should hit its target while slow-lane is still partially
# drained.
#
# Usage:
#   ./scripts/persistence_fast_lane_smoke.sh [fast_n] [slow_n]
#     fast_n default 50, slow_n default 5000.

set -euo pipefail
cd "$(dirname "$0")/.."

FAST_N="${1:-50}"
SLOW_N="${2:-5000}"
LOG=/tmp/notatlas-persistence-fast-lane
mkdir -p "$LOG"
rm -f "$LOG"/*.log

echo ">>> fast-lane smoke: fast=$FAST_N session events, slow=$SLOW_N market events"

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

echo ">>> resetting tables + streams"
$PSQL -c "TRUNCATE sessions, market_trades, cell_handoffs, inventories RESTART IDENTITY CASCADE;" >/dev/null
for s in events_session events_market_trade events_handoff_cell events_inventory_change; do
  $NATS_BOX nats stream rm "$s" -f >/dev/null 2>&1 || true
done

# Pre-create the streams without pwriter running, so messages buffer up
# while the consumer is offline. Easiest way: run pwriter briefly to
# declare streams + consumer, then kill it.
echo ">>> declaring streams (run pwriter briefly)"
zig-out/bin/persistence-writer > "$LOG/declare.log" 2>&1 &
DECLARE_PID=$!
for _ in $(seq 1 50); do
  if grep -q 'events_inventory_change.*ready' "$LOG/declare.log"; then break; fi
  sleep 0.1
done
kill -INT "$DECLARE_PID"
wait "$DECLARE_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Pre-fill: slow backlog first, then small fast batch on top.
# ---------------------------------------------------------------------------
echo ">>> pre-filling $SLOW_N market events (tier=slow)"
# Single nats-box container for the whole pre-fill — per-event podman
# spawn cost would dominate ($SLOW_N × ~1s) and the smoke would take
# tens of minutes. nats pub --count repeats internally with no
# per-event cost; payload templating uses {{Count}} for the unique-id
# fields so each row is distinct.
$NATS_BOX nats pub events.market.trade \
  '{"buy_order_id":0,"sell_order_id":0,"buyer_id":1,"seller_id":1,"item_def_id":{{Count}},"quantity":1,"price":{{Count}}}' \
  --count "$SLOW_N" --quiet >/dev/null 2>&1

echo ">>> pre-filling $FAST_N session events (tier=fast)"
$NATS_BOX nats pub events.session \
  '{"account_id":1,"character_id":1,"kind":"login"}' \
  --count "$FAST_N" --quiet >/dev/null 2>&1

PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do
    kill -INT "$pid" 2>/dev/null || true
  done
  wait "${PIDS[@]}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Start pwriter, poll PG row counts every 100 ms, record when each
# stream reaches its target count.
# ---------------------------------------------------------------------------
echo ">>> starting pwriter, polling row counts"
zig-out/bin/persistence-writer > "$LOG/pwriter.log" 2>&1 &
PIDS+=($!)
PWRITER_PID=$!

start_ms=$(date +%s%3N)
session_done_ms=""
market_done_ms=""
deadline_ms=$((start_ms + 60000))  # 60 s budget

while true; do
  now_ms=$(date +%s%3N)
  if [ -z "$session_done_ms" ]; then
    s=$($PSQL -c "SELECT count(*) FROM sessions;")
    if [ "$s" -ge "$FAST_N" ]; then
      session_done_ms=$((now_ms - start_ms))
      echo ">>> session count = $s at ${session_done_ms} ms"
    fi
  fi
  if [ -z "$market_done_ms" ]; then
    m=$($PSQL -c "SELECT count(*) FROM market_trades;")
    if [ "$m" -ge "$SLOW_N" ]; then
      market_done_ms=$((now_ms - start_ms))
      echo ">>> market count = $m at ${market_done_ms} ms"
    fi
  fi
  if [ -n "$session_done_ms" ] && [ -n "$market_done_ms" ]; then break; fi
  if [ "$now_ms" -ge "$deadline_ms" ]; then
    echo ">>> deadline reached at ${now_ms} ms"
    break
  fi
  sleep 0.1
done

kill -INT "$PWRITER_PID"
wait "$PWRITER_PID" 2>/dev/null || true
PIDS=()

# ---------------------------------------------------------------------------
# Verdict.
# ---------------------------------------------------------------------------
echo
fail=0

if [ -z "$session_done_ms" ]; then
  echo "FAIL: session never reached $FAST_N within 60 s"; fail=1
elif [ -z "$market_done_ms" ]; then
  echo "FAIL: market never reached $SLOW_N within 60 s"; fail=1
elif [ "$session_done_ms" -lt "$market_done_ms" ]; then
  delta=$((market_done_ms - session_done_ms))
  echo "PASS: fast lane drained first — session done @ ${session_done_ms} ms, market @ ${market_done_ms} ms (Δ ${delta} ms)"
else
  echo "FAIL: slow lane drained first — session @ ${session_done_ms} ms, market @ ${market_done_ms} ms"
  fail=1
fi

# Sanity-check final counts.
final_session=$($PSQL -c "SELECT count(*) FROM sessions;")
final_market=$($PSQL -c "SELECT count(*) FROM market_trades;")
if [ "$final_session" = "$FAST_N" ]; then
  echo "PASS: session count = $final_session"
else
  echo "FAIL: session count = $final_session (expected $FAST_N)"; fail=1
fi
if [ "$final_market" = "$SLOW_N" ]; then
  echo "PASS: market count = $final_market"
else
  echo "FAIL: market count = $final_market (expected $SLOW_N)"; fail=1
fi

echo
echo ">>> logs in $LOG/."
exit "$fail"
