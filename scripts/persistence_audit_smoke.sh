#!/usr/bin/env bash
# persistence-writer audit-mirror smoke. Verifies that workqueue
# events get materialized into PG (and ack-removed from the source
# stream), AND simultaneously land in the parallel audit_<source>
# mirror stream — which retains them under limits retention so they
# remain available for replay/forensics after the workqueue ack
# removes them from the source.
#
# Why this matters: workqueue retention is "remove on ack", so the
# moment pwriter commits + acks an event, it's gone from
# `events_damage`. If analytics later wants to replay the damage
# event log, the only durable source is the `audit_events_damage`
# mirror. ADR-60 (NATS 2.14) unblocked sourcing from a workqueue.
#
# Flow:
#   1. Reset state.
#   2. Start pwriter — declares 4 workqueue + 4 audit mirrors.
#   3. Publish N damage events (workqueue capture is synchronous —
#      mirror lag is bounded by replication latency, sub-ms locally).
#   4. Wait for pwriter to commit + ack.
#   5. Assert events_damage messages = 0 (workqueue ack-removed).
#   6. Assert audit_events_damage messages = N (limits retention held).
#   7. Same check for the other 3 streams.
#
# Pass criteria: per-stream "source = 0, audit = N" pair across all 4.

set -euo pipefail
cd "$(dirname "$0")/.."

N="${1:-5}"
LOG=/tmp/notatlas-persistence-audit
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

echo ">>> resetting state ($N events per stream)"
$PSQL >/dev/null <<'SQL'
TRUNCATE wipe_cycles RESTART IDENTITY CASCADE;
INSERT INTO wipe_cycles (id, label, started_at) VALUES (1, 'S0-dev', NOW());
SELECT setval('wipe_cycles_id_seq', 1);
INSERT INTO accounts (id, username, pass_hash) VALUES (1, 'audit_smoke', E'\\x00')
ON CONFLICT (id) DO NOTHING;
INSERT INTO characters (id, account_id, cycle_id, name) VALUES (1, 1, 1, 'audit_char')
ON CONFLICT (id) DO NOTHING;
SELECT setval('accounts_id_seq', GREATEST((SELECT MAX(id) FROM accounts), 1));
SELECT setval('characters_id_seq', GREATEST((SELECT MAX(id) FROM characters), 1));
SQL

# Wipe the broker streams BEFORE starting pwriter so the run starts
# from a clean slate (workqueue + mirror creation is idempotent;
# pwriter will re-declare them).
for s in events_damage events_market_trade events_handoff_cell events_inventory_change \
         audit_events_damage audit_events_market_trade audit_events_handoff_cell audit_events_inventory_change; do
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

echo ">>> starting pwriter"
zig-out/bin/persistence-writer > "$LOG/pwriter.log" 2>&1 &
PIDS+=($!)
PWRITER_PID=$!

# Wait for all 4 streams + 4 mirrors to attach.
for _ in $(seq 1 50); do
  if grep -q 'events_inventory_change.*ready' "$LOG/pwriter.log"; then break; fi
  sleep 0.1
done
if ! grep -q 'mirror=audit_events_inventory_change' "$LOG/pwriter.log"; then
  echo "FAIL: pwriter didn't declare all mirrors in 5 s"
  cat "$LOG/pwriter.log"
  exit 1
fi

echo ">>> publishing $N events on each of the 4 streams"
for i in $(seq 1 "$N"); do
  victim=$(( 16777217 + (i % 4) ))
  $NATS_BOX nats pub "sim.entity.${victim}.damage" \
    "$(printf '{"victim_id":%d,"source_id":%d,"damage":%d.0,"fire_time_s":%d.0,"hit_x":1.0,"hit_y":2.0,"hit_z":3.0,"remaining_hp":0.5}' "$victim" "$((victim+1))" "$i" "$i")" >/dev/null 2>&1
  $NATS_BOX nats pub "events.market.trade" \
    "$(printf '{"buy_order_id":0,"sell_order_id":0,"buyer_id":1,"seller_id":1,"item_def_id":%d,"quantity":%d,"price":%d}' "$((100+i))" "$i" "$((i*50))")" >/dev/null 2>&1
  $NATS_BOX nats pub "events.handoff.cell" \
    "$(printf '{"entity_id":%d,"from_cell_x":0,"from_cell_y":0,"to_cell_x":1,"to_cell_y":0,"pos_x":%d.5,"pos_y":0.0,"pos_z":0.0}' "$victim" "$i")" >/dev/null 2>&1
  $NATS_BOX nats pub "events.inventory.change.1" \
    "$(printf '{"slots":[{"slot":0,"item_def_id":42,"quantity":%d}]}' "$i")" >/dev/null 2>&1
done

# Drain time + mirror replication lag.
sleep 1.5

# Stop pwriter so the consumer ack-floor is fully flushed.
kill -INT "$PWRITER_PID"
wait "$PWRITER_PID" 2>/dev/null || true
PIDS=()

# ---------------------------------------------------------------------------
# Per-stream message counts. nats-box "stream info" exposes
# state.messages — use --json + jq for exact extraction.
# ---------------------------------------------------------------------------
get_msgs() {
  local stream="$1"
  $NATS_BOX nats stream info "$stream" --json 2>/dev/null | jq -r '.state.messages // 0'
}

src_damage=$(get_msgs events_damage)
src_market=$(get_msgs events_market_trade)
src_handoff=$(get_msgs events_handoff_cell)
src_inv=$(get_msgs events_inventory_change)
aud_damage=$(get_msgs audit_events_damage)
aud_market=$(get_msgs audit_events_market_trade)
aud_handoff=$(get_msgs audit_events_handoff_cell)
aud_inv=$(get_msgs audit_events_inventory_change)

echo
echo "=== source workqueue (post-ack) vs audit mirror (retained) ==="
printf '%-25s %10s %10s\n' 'stream' 'source' 'audit'
printf '%-25s %10s %10s\n' 'events_damage'           "$src_damage"  "$aud_damage"
printf '%-25s %10s %10s\n' 'events_market_trade'     "$src_market"  "$aud_market"
printf '%-25s %10s %10s\n' 'events_handoff_cell'     "$src_handoff" "$aud_handoff"
printf '%-25s %10s %10s\n' 'events_inventory_change' "$src_inv"     "$aud_inv"
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
check "events_damage source ack-removed"            "$src_damage"  "0"
check "audit_events_damage retained"                "$aud_damage"  "$N"
check "events_market_trade source ack-removed"      "$src_market"  "0"
check "audit_events_market_trade retained"          "$aud_market"  "$N"
check "events_handoff_cell source ack-removed"      "$src_handoff" "0"
check "audit_events_handoff_cell retained"          "$aud_handoff" "$N"
check "events_inventory_change source ack-removed"  "$src_inv"     "0"
check "audit_events_inventory_change retained"      "$aud_inv"     "$N"

echo
echo ">>> logs in $LOG/."
exit "$fail"
