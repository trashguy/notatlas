#!/usr/bin/env bash
# persistence-writer SLA-under-load smoke.
#
# Drives a sustained burst of fast-tier (session) events at ~100/s for
# 10 s and asserts:
#   1. Every session row lands in PG.
#   2. lag_ms_p99 reported on admin.pwriter.status stays under 1000 ms.
#   3. No SLA breach published on admin.pwriter.breach during the run.
#
# This is the headline correctness assertion for the SLA arc: under
# steady gameplay-scale load (sessions are human-cadence, ~10-100/s
# typical), pwriter holds the tier=fast SLA without breach. The 1 s
# threshold is comfortably above the 200 ms default sla_p99_ms but
# tight enough that any actual queueing pathology would breach it.
#
# Usage:
#   ./scripts/persistence_sla_load_smoke.sh [n_events] [duration_s]
#     n_events default 1000, duration_s default 10.

set -euo pipefail
cd "$(dirname "$0")/.."

N="${1:-1000}"
DUR="${2:-10}"
LOG=/tmp/notatlas-persistence-sla
mkdir -p "$LOG"
rm -f "$LOG"/*.log

echo ">>> sla-load smoke: $N session events over $DUR s"

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

PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do
    kill -INT "$pid" 2>/dev/null || true
  done
  wait "${PIDS[@]}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Start pwriter + breach watcher.
# ---------------------------------------------------------------------------
echo ">>> starting pwriter"
zig-out/bin/persistence-writer > "$LOG/pwriter.log" 2>&1 &
PIDS+=($!)
PWRITER_PID=$!

for _ in $(seq 1 50); do
  if grep -q 'events_inventory_change.*ready' "$LOG/pwriter.log"; then break; fi
  sleep 0.1
done

# Breach watcher in background — captures any admin.pwriter.breach
# emitted during the load. If file ends up empty, no breach was raised.
($NATS_BOX nats sub admin.pwriter.breach --timeout "$((DUR + 30))s" > "$LOG/breach.log" 2>&1 &)
BREACH_WATCH_PID=$!
sleep 0.3  # let the subscription register

# ---------------------------------------------------------------------------
# Drive load: $N events spread evenly over $DUR seconds. Single
# nats-box container with `nats pub --count N --sleep DURms` rather
# than one podman spawn per event — per-spawn cost dominates otherwise.
# ---------------------------------------------------------------------------
gap_ms=$(awk -v n="$N" -v d="$DUR" 'BEGIN{printf "%.0f", (d * 1000) / n}')
echo ">>> driving $N events at ~$(awk -v g="$gap_ms" 'BEGIN{printf "%.0f", 1000/g}')/s for ${DUR}s (gap ${gap_ms}ms)"
start_ms=$(date +%s%3N)
$NATS_BOX nats pub "events.session" \
  "{\"account_id\":1,\"character_id\":1,\"kind\":\"login\"}" \
  --count "$N" --sleep "${gap_ms}ms" --quiet >/dev/null 2>&1
end_ms=$(date +%s%3N)
echo ">>> publish loop took $(( end_ms - start_ms )) ms wallclock"

# Drain time after publish ends.
echo ">>> letting pwriter drain + emit one more status snapshot"
sleep 8

# Capture latest status snapshot.
echo ">>> capturing admin.pwriter.status snapshot"
status=$($NATS_BOX nats sub admin.pwriter.status --count=1 --timeout 8s 2>&1 | grep -E '^\{' | head -1)
echo "    $status"

kill -INT "$PWRITER_PID"
wait "$PWRITER_PID" 2>/dev/null || true
PIDS=()

# ---------------------------------------------------------------------------
# Read counters from the status snapshot (and PG for a sanity row count).
# ---------------------------------------------------------------------------
extract_field() {
  local label="$1" field="$2"
  # `grep -oE '-?[0-9]+'` would also match digits embedded in field names
  # (e.g. the "99" in "sla_p99_ms" or "lag_ms_p99"). Take the value only.
  echo "$status" | grep -oE "\"name\":\"$label\"[^}]*" \
    | grep -oE "\"$field\":-?[0-9]+" \
    | sed -E 's/.*://'
}
session_committed=$(extract_field session committed)
session_committed=${session_committed:-0}
session_lag=$(extract_field session lag_ms_p99)
session_lag=${session_lag:-999999}
session_breach=$(echo "$status" | grep -oE '"name":"session"[^}]*' | grep -oE '"sla_breach":(true|false)' | cut -d: -f2)

# Count breach lines in the captured log. A clean run has zero.
# `grep -c` already prints 0 on no-match (with exit 1), so don't add an
# extra `|| echo 0` — that would double-print and break integer compare.
if [ -f "$LOG/breach.log" ]; then
  breach_count=$(grep -cE '"stream":"session"' "$LOG/breach.log" || true)
else
  breach_count=0
fi

session_pg=$($PSQL -c "SELECT count(*) FROM sessions;")

echo ">>> session committed (status) = $session_committed"
echo ">>> session lag_ms_p99 (status) = $session_lag"
echo ">>> session sla_breach (status) = $session_breach"
echo ">>> session breach events (admin.pwriter.breach) = $breach_count"
echo ">>> session row count (PG) = $session_pg"

# ---------------------------------------------------------------------------
# Verdict.
# ---------------------------------------------------------------------------
echo
fail=0

if [ "$session_pg" = "$N" ]; then
  echo "PASS: every event landed in PG ($session_pg = $N)"
else
  echo "FAIL: session_pg = $session_pg (expected $N)"; fail=1
fi
if [ "$session_committed" = "$N" ]; then
  echo "PASS: session committed counter = $N"
else
  echo "FAIL: session committed = $session_committed (expected $N)"; fail=1
fi
if [ "${session_lag:-999999}" -lt 1000 ]; then
  echo "PASS: lag_ms_p99 = $session_lag (< 1000 ms gate)"
else
  echo "FAIL: lag_ms_p99 = $session_lag (≥ 1000 ms gate)"; fail=1
fi
if [ "$session_breach" = "false" ]; then
  echo "PASS: sla_breach = false on session at end of run"
else
  echo "FAIL: sla_breach = $session_breach"; fail=1
fi
if [ "$breach_count" = "0" ]; then
  echo "PASS: 0 breach events on admin.pwriter.breach during run"
else
  echo "FAIL: $breach_count breach events fired during run"; fail=1
fi

echo
echo ">>> logs in $LOG/."
exit "$fail"
