#!/usr/bin/env bash
# persistence-writer SLA-arc multi-stream stress smoke.
#
# Drives all four SLA-arc streams concurrently at peak gameplay-scale
# rates for ${DUR}s. Headline question: does pwriter hold each tier's
# per-stream SLA when every producer is firing at once?
#
# This is the multi-stream successor to persistence_sla_load_smoke.sh
# (single-stream, session only). That smoke proves correctness for one
# isolated load source; this one proves it under the full mesh — the
# realistic configuration once gateway / spatial-index / market-sim /
# inventory-sim are all live.
#
# Default rates (override via env):
#   SESSION_EPS=100      fast tier — mass login burst after restart.
#   HANDOFF_EPS=100      slow tier — fleet rotation across cells.
#   MARKET_EPS=200       slow tier — auction-hour churn.
#   INV_EPS=1000         slow tier — crafting / loot peak. The
#                        sustainable rate after the slow/fast
#                        interleave fix landed in pwriter (see
#                        docs/research/sla_arc_stress.md). 1500/s
#                        starts queuing; that's the new ceiling.
#
# Total at defaults: ~42 000 events over 30 s.
#
# Asserts:
#   1. committed[stream] = sent[stream] for all four streams.
#   2. sla_breach=false on all streams in the end-of-run snapshot AND
#      0 events on admin.pwriter.breach during the run. The breach
#      detector is the canonical SLA gate (30 s sustained-over-SLA
#      window — transient spikes above SLA are tolerated by design).
#   3. lag_ms_p99[stream] within a loose regression margin:
#        fast (session):    <  400 ms (2× the 200 ms SLA)
#        slow (others):     < 5000 ms (50 % of the 10 s SLA)
#      These are NOT SLA gates; they catch perf regressions that
#      double end-to-end latency under contended-mesh load. Setting
#      them tighter than that flakes — session p99 routinely sits
#      just above its 200 ms SLA during a slow-lane batch wait, and
#      the architecture explicitly accepts that (see breach detector).
#   4. PG row counts:
#        sessions / market_trades / cell_handoffs = sent count
#        inventories rows = N_INV_CHARS
#        inventories SUM(version) = inventory sent count
#        (inventory upserts on character_id PK; each pub bumps that
#         character's version once. Summed bumps = total pubs.)
#
# Usage:
#   ./scripts/persistence_sla_arc_stress_smoke.sh [duration_s]
#     DUR / SESSION_EPS / HANDOFF_EPS / MARKET_EPS / INV_EPS env-tunable.

set -euo pipefail
cd "$(dirname "$0")/.."

DUR="${1:-${DUR:-30}}"
SESSION_EPS="${SESSION_EPS:-100}"
HANDOFF_EPS="${HANDOFF_EPS:-100}"
MARKET_EPS="${MARKET_EPS:-200}"
# Default = 1000/s sustained — pwriter's new comfortable ceiling
# after the fast/slow interleave + 1 ms fast timeout fix. Pre-fix
# this rate breached the session 200 ms SLA; post-fix session p99
# stays at ~120 ms. 1500/s starts to queue (slow-lane backlog
# grows over the run). See docs/research/sla_arc_stress.md.
INV_EPS="${INV_EPS:-1000}"
# 1 → pass --trace-batches to pwriter for per-stream fetch/process
# timing. Cheap; emits one line per stream per second.
TRACE_BATCHES="${TRACE_BATCHES:-1}"
# Inventory is split across N_INV_CHARS distinct characters because the
# inventories table upserts on character_id PK. Hitting one PK
# serialises PG UPDATEs on the same row; in production the load is
# spread across the live character roster.
N_INV_CHARS="${N_INV_CHARS:-10}"

LOG=/tmp/notatlas-sla-arc-stress
mkdir -p "$LOG"
rm -f "$LOG"/*.log

echo ">>> sla-arc stress: ${DUR}s @ session=$SESSION_EPS handoff=$HANDOFF_EPS market=$MARKET_EPS inv=$INV_EPS"

if ! ss -lnt 2>/dev/null | grep -q :4222 || ! ss -lnt 2>/dev/null | grep -q :5432; then
  echo ">>> starting services (make services-up)"
  make services-up
  sleep 2
fi

zig build install

NATS_BOX="podman run --rm --network host docker.io/natsio/nats-box:latest"
PSQL="podman exec -i notatlas-pg psql -U notatlas -d notatlas -tA"

# ---------------------------------------------------------------------------
# Seed: one account + one character is enough; the test exercises pwriter
# throughput, not entity-diversity. Sessions / market FK to character 1;
# inventory upserts to character 1's row; handoffs have no FK on entity_id.
# ---------------------------------------------------------------------------
echo ">>> seeding fixtures ($N_INV_CHARS characters)"
# One account; one character per (acct,cycle) tuple is the UNIQUE
# constraint, so we make N_INV_CHARS accounts and pair them 1:1 with
# characters. Cheaper than reworking the constraint.
$PSQL >/dev/null <<SQL
INSERT INTO accounts (id, username, pass_hash)
  SELECT g, 'stress_'||g, E'\\\\x00' FROM generate_series(1, $N_INV_CHARS) g
  ON CONFLICT (id) DO NOTHING;
INSERT INTO characters (id, account_id, cycle_id, name)
  SELECT g, g, 1, 'stress_char_'||g FROM generate_series(1, $N_INV_CHARS) g
  ON CONFLICT (id) DO NOTHING;
SELECT setval('accounts_id_seq', GREATEST((SELECT MAX(id) FROM accounts), 1));
SELECT setval('characters_id_seq', GREATEST((SELECT MAX(id) FROM characters), 1));
SQL

echo ">>> resetting tables + streams"
$PSQL -c "TRUNCATE sessions, market_trades, cell_handoffs, inventories RESTART IDENTITY CASCADE;" >/dev/null
for s in events_session events_market_trade events_handoff_cell events_inventory_change; do
  $NATS_BOX nats stream rm "$s" -f >/dev/null 2>&1 || true
done

PIDS=()
# BG_PIDS = long-lived observer/polling processes (status sub, jsz
# poller) that must outlive the main pwriter handle but should still
# die on script exit. Kept separate from PIDS because the main flow
# does `kill PWRITER_PID; PIDS=()` to avoid double-kill, which would
# wipe the observer pids if they shared the array.
BG_PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do
    kill -INT "$pid" 2>/dev/null || true
  done
  # Background observers run inside `while true; do ... sleep 1; done`
  # subshells — SIGINT only interrupts the sleep, the while loop keeps
  # looping. SIGKILL the subshell + any curl/podman child so nothing
  # is left waiting on the next `sleep 1`.
  for pid in "${BG_PIDS[@]}"; do
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  # Explicit list to wait on — `wait` with no args waits for ALL jobs
  # which deadlocks if any BG_PIDS subshell is still wedged.
  for pid in "${PIDS[@]}" "${BG_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Start pwriter + long-lived breach watcher.
# ---------------------------------------------------------------------------
echo ">>> starting pwriter (trace-batches=$TRACE_BATCHES)"
PWRITER_ARGS=()
if [ "$TRACE_BATCHES" = "1" ]; then PWRITER_ARGS+=("--trace-batches"); fi
zig-out/bin/persistence-writer "${PWRITER_ARGS[@]}" > "$LOG/pwriter.log" 2>&1 &
PIDS+=($!)
PWRITER_PID=$!

# pwriter logs `stream=<name> subject=<subject> consumer=pwriter ready`
# for each of the 4 streams. Wait for the last one (alphabetically the
# inventory stream is the latest in the array order, but any reliable
# fixed-line wait works — the existing single-stream smoke watches the
# same string).
for _ in $(seq 1 50); do
  if grep -q 'events_inventory_change.*ready' "$LOG/pwriter.log"; then break; fi
  sleep 0.1
done

# Breach watcher in background. Lives ${DUR}+60s so it overlaps the
# whole run plus the drain window. Empty file at the end = no breach.
($NATS_BOX nats sub admin.pwriter.breach --timeout "$((DUR + 60))s" > "$LOG/breach.log" 2>&1 &)
sleep 0.3

# Status snapshot timeline — one line per status emission (0.2 Hz),
# captured for the full run + drain. Lets us see how lag_p99 / pending
# evolved instead of relying on a single end-of-run snapshot.
($NATS_BOX nats sub admin.pwriter.status --timeout "$((DUR + 60))s" > "$LOG/status_timeline.log" 2>&1 &)
sleep 0.3

# NATS monitor poll — per-consumer pending / delivered / ack_floor view
# at 1 Hz from NATS' own perspective. Independent of pwriter's
# self-reported numbers; disagreement between the two reveals whether
# the bottleneck is in fetch or in PG.
(
  while true; do
    ts=$(date +%s.%3N)
    curl -fsS "http://127.0.0.1:8222/jsz?consumers=true&streams=true" \
      | awk -v ts="$ts" '{print ts" "$0}' >> "$LOG/jsz_timeline.log" 2>/dev/null || true
    sleep 1
  done
) &
BG_PIDS+=($!)

# ---------------------------------------------------------------------------
# Compute per-stream message counts + nats-pub sleep gaps. gap_ms is
# integer ms — at INV_EPS=1000 it's exactly 1 ms which is the floor of
# `nats pub --sleep`'s useful precision. Sub-ms rates would need a
# different driver.
# ---------------------------------------------------------------------------
SESSION_N=$(( DUR * SESSION_EPS ))
HANDOFF_N=$(( DUR * HANDOFF_EPS ))
MARKET_N=$(( DUR * MARKET_EPS ))
INV_N=$(( DUR * INV_EPS ))

gap() { awk -v eps="$1" 'BEGIN{printf "%.0f", 1000/eps}'; }
SESSION_GAP=$(gap "$SESSION_EPS")
HANDOFF_GAP=$(gap "$HANDOFF_EPS")
MARKET_GAP=$(gap "$MARKET_EPS")
INV_GAP=$(gap "$INV_EPS")

total_sent=$(( SESSION_N + HANDOFF_N + MARKET_N + INV_N ))
echo ">>> sent budget: session=$SESSION_N handoff=$HANDOFF_N market=$MARKET_N inv=$INV_N (total $total_sent)"

# ---------------------------------------------------------------------------
# Drive load: four parallel nats-box containers, one per stream. Each
# pub takes ~DUR seconds because --sleep gates the loop. Fire-and-forget
# (no --reply), so per-message overhead is one TCP write.
# ---------------------------------------------------------------------------
start_ms=$(date +%s%3N)

$NATS_BOX nats pub "events.session" \
  '{"account_id":1,"character_id":1,"kind":"login"}' \
  --count "$SESSION_N" --sleep "${SESSION_GAP}ms" --quiet \
  > "$LOG/pub_session.log" 2>&1 &
PUB_SESSION_PID=$!

$NATS_BOX nats pub "events.handoff.cell" \
  '{"entity_id":16777217,"from_cell_x":0,"from_cell_y":0,"to_cell_x":1,"to_cell_y":0,"pos_x":0.0,"pos_y":0.0,"pos_z":0.0}' \
  --count "$HANDOFF_N" --sleep "${HANDOFF_GAP}ms" --quiet \
  > "$LOG/pub_handoff.log" 2>&1 &
PUB_HANDOFF_PID=$!

$NATS_BOX nats pub "events.market.trade" \
  '{"buy_order_id":0,"sell_order_id":0,"buyer_id":1,"seller_id":1,"item_def_id":1,"quantity":10,"price":100}' \
  --count "$MARKET_N" --sleep "${MARKET_GAP}ms" --quiet \
  > "$LOG/pub_market.log" 2>&1 &
PUB_MARKET_PID=$!

# Inventory: N_INV_CHARS parallel pubs, one per character. Per-char
# rate = total target / N. This both matches realistic per-row PG
# update cadence AND lets pwriter's slow batch fetch ride larger
# combined batches (NATS doesn't care about subject when batching
# fetches on a wildcard consumer).
INV_PER_CHAR_EPS=$(( INV_EPS / N_INV_CHARS ))
INV_PER_CHAR_N=$(( DUR * INV_PER_CHAR_EPS ))
INV_PER_CHAR_GAP=$(gap "$INV_PER_CHAR_EPS")
PUB_INV_PIDS=()
for c in $(seq 1 "$N_INV_CHARS"); do
  $NATS_BOX nats pub "events.inventory.change.${c}" \
    '{"slots":[{"item_def_id":1,"quantity":10}]}' \
    --count "$INV_PER_CHAR_N" --sleep "${INV_PER_CHAR_GAP}ms" --quiet \
    > "$LOG/pub_inv_${c}.log" 2>&1 &
  PUB_INV_PIDS+=($!)
done
# True INV_N may differ from DUR×INV_EPS by integer-division remainder;
# use the actual product so the parity check is exact.
INV_N=$(( INV_PER_CHAR_N * N_INV_CHARS ))

# These pubs exit on their own when --count is hit; don't put them in
# PIDS or the cleanup trap will SIGINT them. Just wait().
wait "$PUB_SESSION_PID" "$PUB_HANDOFF_PID" "$PUB_MARKET_PID" "${PUB_INV_PIDS[@]}" 2>/dev/null || true

end_ms=$(date +%s%3N)
elapsed=$(( end_ms - start_ms ))
echo ">>> publish loops finished in ${elapsed}ms (target ${DUR}000ms)"

# ---------------------------------------------------------------------------
# Drain + capture latest status snapshot.
# pwriter emits admin.pwriter.status every 5 s. 10 s drain comfortably
# covers (slow-lane 75 ms wrap × buffered backlog) + (5 s status cadence).
# ---------------------------------------------------------------------------
echo ">>> draining + status snapshot"
sleep 10

status=$($NATS_BOX nats sub admin.pwriter.status --count=1 --timeout 8s 2>&1 | grep -E '^\{' | head -1)
echo "    $status"

kill -INT "$PWRITER_PID"
wait "$PWRITER_PID" 2>/dev/null || true
PIDS=()

# ---------------------------------------------------------------------------
# Extract counters from status JSON. The same "$field":N + grep-by-name
# trick the single-stream smoke uses, generalised to all 4 streams.
# ---------------------------------------------------------------------------
extract_field() {
  local label="$1" field="$2"
  echo "$status" | grep -oE "\"name\":\"$label\"[^}]*" \
    | grep -oE "\"$field\":-?[0-9]+" \
    | sed -E 's/.*://'
}
extract_breach() {
  local label="$1"
  echo "$status" | grep -oE "\"name\":\"$label\"[^}]*" \
    | grep -oE '"sla_breach":(true|false)' | cut -d: -f2
}

# Status-snapshot labels — see stream_specs[].label in
# services/persistence_writer/main.zig. Not the PG table name.
streams=(session market handoff inv)

declare -A sent committed lag breach
sent[session]=$SESSION_N
sent[market]=$MARKET_N
sent[handoff]=$HANDOFF_N
sent[inv]=$INV_N

for s in "${streams[@]}"; do
  committed[$s]=$(extract_field "$s" committed)
  committed[$s]=${committed[$s]:-0}
  lag[$s]=$(extract_field "$s" lag_ms_p99)
  lag[$s]=${lag[$s]:-999999}
  breach[$s]=$(extract_breach "$s")
  breach[$s]=${breach[$s]:-unknown}
done

if [ -f "$LOG/breach.log" ]; then
  breach_events=$(grep -cE '"stream":"' "$LOG/breach.log" || true)
else
  breach_events=0
fi

pg_sessions=$($PSQL -c "SELECT count(*) FROM sessions;")
pg_market=$($PSQL -c "SELECT count(*) FROM market_trades;")
pg_handoffs=$($PSQL -c "SELECT count(*) FROM cell_handoffs;")
# Inventory writes upsert on character_id PK; expected end state is one
# row per touched character, with versions summing to INV_N (each pub is
# one bump). SUM(version) is the parity check.
inv_rows=$($PSQL -c "SELECT count(*) FROM inventories;")
inv_version_sum=$($PSQL -c "SELECT COALESCE(SUM(version), 0) FROM inventories;")

# ---------------------------------------------------------------------------
# Pretty-print + verdict.
# ---------------------------------------------------------------------------
echo
printf '%-10s  %9s  %9s  %9s  %s\n' stream sent committed lag_p99_ms sla_breach
printf '%-10s  %9s  %9s  %9s  %s\n' ---------- --------- --------- --------- ----------
for s in "${streams[@]}"; do
  printf '%-10s  %9d  %9d  %9s  %s\n' "$s" "${sent[$s]}" "${committed[$s]}" "${lag[$s]}" "${breach[$s]}"
done
echo
echo "PG rows: sessions=$pg_sessions market_trades=$pg_market cell_handoffs=$pg_handoffs inventories=$inv_rows"
echo "PG inv version sum (across $inv_rows rows): $inv_version_sum"
echo "breach events on admin.pwriter.breach: $breach_events"

echo
fail=0

# Committed parity.
for s in "${streams[@]}"; do
  if [ "${committed[$s]}" = "${sent[$s]}" ]; then
    echo "PASS: $s committed = ${sent[$s]}"
  else
    echo "FAIL: $s committed = ${committed[$s]} (expected ${sent[$s]})"; fail=1
  fi
done

# Lag regression gates. Loose by design — see header comment. SLA is
# enforced by the breach detector + sla_breach assertions above; these
# fire if pwriter end-to-end latency doubles versus expected.
fast_margin_ms=400
slow_margin_ms=5000
if [ "${lag[session]:-999999}" -lt "$fast_margin_ms" ]; then
  echo "PASS: session lag_p99 = ${lag[session]}ms (< $fast_margin_ms)"
else
  echo "FAIL: session lag_p99 = ${lag[session]}ms (>= $fast_margin_ms)"; fail=1
fi
for s in market handoff inv; do
  if [ "${lag[$s]:-999999}" -lt "$slow_margin_ms" ]; then
    echo "PASS: $s lag_p99 = ${lag[$s]}ms (< $slow_margin_ms)"
  else
    echo "FAIL: $s lag_p99 = ${lag[$s]}ms (>= $slow_margin_ms)"; fail=1
  fi
done

# sla_breach flag in snapshot.
for s in "${streams[@]}"; do
  if [ "${breach[$s]}" = "false" ]; then
    echo "PASS: $s sla_breach=false"
  else
    echo "FAIL: $s sla_breach=${breach[$s]}"; fail=1
  fi
done

# Breach events on admin.pwriter.breach.
if [ "$breach_events" = "0" ]; then
  echo "PASS: 0 breach events fired during run"
else
  echo "FAIL: $breach_events breach events fired during run"; fail=1
fi

# PG row parity (3 streams unique-stream-seq inserts).
if [ "$pg_sessions" = "${sent[session]}" ]; then
  echo "PASS: PG sessions = ${sent[session]}"
else
  echo "FAIL: PG sessions = $pg_sessions (expected ${sent[session]})"; fail=1
fi
if [ "$pg_market" = "${sent[market]}" ]; then
  echo "PASS: PG market_trades = ${sent[market]}"
else
  echo "FAIL: PG market_trades = $pg_market (expected ${sent[market]})"; fail=1
fi
if [ "$pg_handoffs" = "${sent[handoff]}" ]; then
  echo "PASS: PG cell_handoffs = ${sent[handoff]}"
else
  echo "FAIL: PG cell_handoffs = $pg_handoffs (expected ${sent[handoff]})"; fail=1
fi

# Inventory upserts across N_INV_CHARS PKs: row count = N_INV_CHARS,
# SUM(version) = total upserts = sent count.
if [ "$inv_rows" = "$N_INV_CHARS" ]; then
  echo "PASS: PG inventories rows = $N_INV_CHARS"
else
  echo "FAIL: PG inventories rows = $inv_rows (expected $N_INV_CHARS)"; fail=1
fi
if [ "$inv_version_sum" = "${sent[inv]}" ]; then
  echo "PASS: PG inventories SUM(version) = ${sent[inv]}"
else
  echo "FAIL: PG inventories SUM(version) = $inv_version_sum (expected ${sent[inv]})"; fail=1
fi

echo
echo ">>> logs in $LOG/."
exit "$fail"
