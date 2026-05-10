#!/usr/bin/env bash
# Gateway events.session producer smoke.
#
# Verifies the producer side of the SLA arc — gateway emits login on
# successful JWT validation and disconnect on close. Flow:
#
#   1. services-up + start persistence-writer (consumes events.session
#      via the events_session workqueue stream → sessions PG table).
#   2. start gateway.
#   3. mint a JWT, open a TCP connection, send the hello frame, wait
#      for pwriter to commit the login row.
#   4. close the TCP socket cleanly. pwriter commits a disconnect row.
#   5. assert: exactly two sessions rows for that account_id with
#      kinds {login, disconnect} and a non-null disconnect.reason.
#
# This is the end-to-end producer test the SLA arc was waiting for —
# real producer (gateway) → real consumer (pwriter) → real PG row.
#
# Usage:
#   ./scripts/gateway_session_smoke.sh

set -euo pipefail
cd "$(dirname "$0")/.."

ACCOUNT_ID=42
PLAYER_ID=$((0x02000001))   # entity-kind tag = 0x02 (player), seq=1
LOG=/tmp/notatlas-gateway-session
mkdir -p "$LOG"
rm -f "$LOG"/*.log

echo ">>> gateway events.session smoke (account_id=$ACCOUNT_ID)"

if ! ss -lnt 2>/dev/null | grep -q :4222 || ! ss -lnt 2>/dev/null | grep -q :5432; then
  echo ">>> starting services (make services-up)"
  make services-up
  sleep 2
fi

zig build install

NATS_BOX="podman run --rm --network host docker.io/natsio/nats-box:latest"
PSQL="podman exec -i notatlas-pg psql -U notatlas -d notatlas -tA"

# Seed an accounts row for the account_id our JWT will carry. pwriter's
# sessions table FKs to accounts(id) ON DELETE CASCADE — without this
# row, the INSERT would fail FK and the smoke would hit the producer-
# bug-redelivery loop.
echo ">>> seeding accounts row for id=$ACCOUNT_ID"
$PSQL >/dev/null <<SQL
INSERT INTO accounts (id, username, pass_hash)
VALUES ($ACCOUNT_ID, 'gw_smoke', E'\\\\x00')
  ON CONFLICT (id) DO NOTHING;
SELECT setval('accounts_id_seq', GREATEST((SELECT MAX(id) FROM accounts), 1));
SQL

echo ">>> resetting sessions table + events_session stream"
$PSQL -c "TRUNCATE sessions RESTART IDENTITY CASCADE;" >/dev/null
$NATS_BOX nats stream rm events_session -f >/dev/null 2>&1 || true

PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do
    kill -INT "$pid" 2>/dev/null || true
  done
  wait "${PIDS[@]}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Start pwriter, then gateway.
# ---------------------------------------------------------------------------
echo ">>> starting persistence-writer"
zig-out/bin/persistence-writer > "$LOG/pwriter.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do
  if grep -q 'events_session.*ready' "$LOG/pwriter.log"; then break; fi
  sleep 0.1
done
if ! grep -q 'events_session.*ready' "$LOG/pwriter.log"; then
  echo "FAIL: pwriter didn't attach events_session in 5s"; cat "$LOG/pwriter.log"; exit 1
fi

echo ">>> starting gateway on :9000"
zig-out/bin/gateway > "$LOG/gateway.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do
  if grep -q 'gateway: connected' "$LOG/gateway.log"; then break; fi
  sleep 0.1
done
if ! grep -q 'gateway: connected' "$LOG/gateway.log"; then
  echo "FAIL: gateway didn't connect to NATS in 5s"; cat "$LOG/gateway.log"; exit 1
fi

# ---------------------------------------------------------------------------
# Mint JWT, open TCP, send hello, wait for login row.
# ---------------------------------------------------------------------------
echo ">>> minting JWT (client_id=$ACCOUNT_ID, player_id=0x$(printf '%x' $PLAYER_ID))"
JWT=$(python3 scripts/mint_jwt.py --client-id "$ACCOUNT_ID" --player-id "$PLAYER_ID" 2>/dev/null)

echo ">>> connecting + sending hello frame"
python3 - "$JWT" <<'PYEOF'
import socket, struct, sys, time

jwt = sys.argv[1].encode()
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(("127.0.0.1", 9000))
# Hello frame: [u32_le len][JWT bytes]
s.sendall(struct.pack("<I", len(jwt)) + jwt)

# Hold the connection long enough that pwriter commits the login row.
# Then close cleanly — TCP EOF triggers gateway "client_close" disconnect.
time.sleep(1.5)
s.close()
PYEOF

# Drain time for the disconnect event to make it through pwriter.
sleep 1.5

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

total=$($PSQL -c "SELECT count(*) FROM sessions WHERE account_id=$ACCOUNT_ID;")
check_eq "sessions row count" "$total" "2"

login_count=$($PSQL -c "SELECT count(*) FROM sessions WHERE account_id=$ACCOUNT_ID AND kind='login';")
check_eq "login rows" "$login_count" "1"

disc_count=$($PSQL -c "SELECT count(*) FROM sessions WHERE account_id=$ACCOUNT_ID AND kind='disconnect';")
check_eq "disconnect rows" "$disc_count" "1"

# login should have NULL reason; disconnect should have a non-null reason.
login_reason=$($PSQL -c "SELECT COALESCE(reason, '__null__') FROM sessions WHERE account_id=$ACCOUNT_ID AND kind='login';")
check_eq "login reason is NULL" "$login_reason" "__null__"

disc_reason=$($PSQL -c "SELECT reason FROM sessions WHERE account_id=$ACCOUNT_ID AND kind='disconnect';")
if [ -n "$disc_reason" ] && [ "$disc_reason" != "__null__" ]; then
  echo "PASS: disconnect reason = '$disc_reason' (non-null)"
else
  echo "FAIL: disconnect reason missing"
  fail=1
fi

# Ordering: login must be timestamped before disconnect.
ordering=$($PSQL <<SQL
SELECT (
  (SELECT occurred_at FROM sessions WHERE account_id=$ACCOUNT_ID AND kind='login') <
  (SELECT occurred_at FROM sessions WHERE account_id=$ACCOUNT_ID AND kind='disconnect')
)
SQL
)
check_eq "login < disconnect timestamp" "$ordering" "t"

# character_id is 0 sentinel → NULL via gateway's nullable mapping.
char_nulls=$($PSQL -c "SELECT count(*) FROM sessions WHERE account_id=$ACCOUNT_ID AND character_id IS NULL;")
check_eq "both rows have NULL character_id (v0 pre-character-select)" "$char_nulls" "2"

echo
echo ">>> logs in $LOG/."
exit "$fail"
