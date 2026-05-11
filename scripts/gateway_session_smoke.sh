#!/usr/bin/env bash
# Gateway events.session producer smoke.
#
# Verifies the producer side of the SLA arc — gateway emits login on
# successful JWT validation and disconnect on close. Two scenarios:
#
#   Scenario A — lobby session: JWT minted WITHOUT --character-id.
#     Gateway threads JWT.character_id=0 → publishSession emits
#     character_id=0 → pwriter maps to NULL. Both sessions rows have
#     NULL character_id.
#
#   Scenario B — character-bound session: JWT minted WITH --character-id
#     pointing at a seeded characters row. Gateway threads the value
#     through both login + disconnect. Both sessions rows carry the
#     real character_id (Path A character-select per
#     architecture_gateway_session_producer.md).
#
# Pass criterion: 4 sessions rows total. 2 NULL character_id rows
# (scenario A); 2 rows referencing the seeded character (scenario B).
# Each pair has login.occurred_at < disconnect.occurred_at and a
# non-null disconnect.reason.
#
# Usage:
#   ./scripts/gateway_session_smoke.sh

set -euo pipefail
cd "$(dirname "$0")/.."

ACCOUNT_A_ID=42
ACCOUNT_B_ID=43
PLAYER_A_ID=$((0x02000001))   # entity-kind tag = 0x02 (player), seq=1
PLAYER_B_ID=$((0x02000002))
CHARACTER_B_ID=4242
LOG=/tmp/notatlas-gateway-session
mkdir -p "$LOG"
rm -f "$LOG"/*.log

echo ">>> gateway events.session smoke (lobby: acct=$ACCOUNT_A_ID; char-bound: acct=$ACCOUNT_B_ID char=$CHARACTER_B_ID)"

if ! ss -lnt 2>/dev/null | grep -q :4222 || ! ss -lnt 2>/dev/null | grep -q :5432; then
  echo ">>> starting services (make services-up)"
  make services-up
  sleep 2
fi

zig build install

NATS_BOX="podman run --rm --network host docker.io/natsio/nats-box:latest"
PSQL="podman exec -i notatlas-pg psql -U notatlas -d notatlas -tA"

# Seed: two accounts (UNIQUE(account_id, cycle_id) means one char per
# account per cycle — scenario B needs its own account). Plus one
# characters row for scenario B in the current cycle.
echo ">>> seeding accounts + scenario-B character in current cycle"
CYCLE_ID=$($PSQL -c "SELECT id FROM wipe_cycles WHERE ends_at IS NULL;")
echo "    current cycle_id=$CYCLE_ID"
$PSQL >/dev/null <<SQL
INSERT INTO accounts (id, username, pass_hash) VALUES
  ($ACCOUNT_A_ID, 'gw_smoke_lobby', E'\\\\x00'),
  ($ACCOUNT_B_ID, 'gw_smoke_char',  E'\\\\x00')
  ON CONFLICT (id) DO NOTHING;
INSERT INTO characters (id, account_id, cycle_id, name) VALUES
  ($CHARACTER_B_ID, $ACCOUNT_B_ID, $CYCLE_ID, 'gw_smoke_char_$CYCLE_ID')
  ON CONFLICT (id) DO NOTHING;
SELECT setval('accounts_id_seq',   GREATEST((SELECT MAX(id) FROM accounts), 1));
SELECT setval('characters_id_seq', GREATEST((SELECT MAX(id) FROM characters), 1));
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

# Helper: open TCP, send JWT, hold 1.5 s, close. Triggers login+disconnect.
connect_with_jwt() {
  local jwt="$1"
  python3 - "$jwt" <<'PYEOF'
import socket, struct, sys, time
jwt = sys.argv[1].encode()
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(("127.0.0.1", 9000))
s.sendall(struct.pack("<I", len(jwt)) + jwt)
time.sleep(1.5)
s.close()
PYEOF
}

# ---------------------------------------------------------------------------
# Scenario A — lobby session, no character_id claim.
# ---------------------------------------------------------------------------
echo ">>> scenario A: lobby JWT (no --character-id)"
JWT_A=$(python3 scripts/mint_jwt.py --client-id "$ACCOUNT_A_ID" --player-id "$PLAYER_A_ID" 2>/dev/null)
connect_with_jwt "$JWT_A"
sleep 1.0

# ---------------------------------------------------------------------------
# Scenario B — JWT carries character_id binding the session.
# ---------------------------------------------------------------------------
echo ">>> scenario B: JWT with --character-id $CHARACTER_B_ID"
JWT_B=$(python3 scripts/mint_jwt.py --client-id "$ACCOUNT_B_ID" --player-id "$PLAYER_B_ID" --character-id "$CHARACTER_B_ID" 2>/dev/null)
connect_with_jwt "$JWT_B"
sleep 1.0

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

# --- Aggregate
total=$($PSQL -c "SELECT count(*) FROM sessions;")
check_eq "sessions total rows (2 per scenario)" "$total" "4"

# --- Scenario A (lobby — NULL character_id)
a_total=$($PSQL -c "SELECT count(*) FROM sessions WHERE account_id=$ACCOUNT_A_ID;")
check_eq "scenario A row count" "$a_total" "2"

a_null_char=$($PSQL -c "SELECT count(*) FROM sessions WHERE account_id=$ACCOUNT_A_ID AND character_id IS NULL;")
check_eq "scenario A both rows have NULL character_id" "$a_null_char" "2"

a_ordering=$($PSQL <<SQL
SELECT (
  (SELECT occurred_at FROM sessions WHERE account_id=$ACCOUNT_A_ID AND kind='login') <
  (SELECT occurred_at FROM sessions WHERE account_id=$ACCOUNT_A_ID AND kind='disconnect')
)
SQL
)
check_eq "scenario A login < disconnect timestamp" "$a_ordering" "t"

# --- Scenario B (character_id threaded from JWT)
b_total=$($PSQL -c "SELECT count(*) FROM sessions WHERE account_id=$ACCOUNT_B_ID;")
check_eq "scenario B row count" "$b_total" "2"

b_char_rows=$($PSQL -c "SELECT count(*) FROM sessions WHERE account_id=$ACCOUNT_B_ID AND character_id=$CHARACTER_B_ID;")
check_eq "scenario B both rows reference character $CHARACTER_B_ID" "$b_char_rows" "2"

# Login should have NULL reason; disconnect should have non-null reason.
b_login_reason=$($PSQL -c "SELECT COALESCE(reason, '__null__') FROM sessions WHERE account_id=$ACCOUNT_B_ID AND kind='login';")
check_eq "scenario B login reason is NULL" "$b_login_reason" "__null__"

b_disc_reason=$($PSQL -c "SELECT reason FROM sessions WHERE account_id=$ACCOUNT_B_ID AND kind='disconnect';")
if [ -n "$b_disc_reason" ] && [ "$b_disc_reason" != "__null__" ]; then
  echo "PASS: scenario B disconnect reason = '$b_disc_reason' (non-null)"
else
  echo "FAIL: scenario B disconnect reason missing"
  fail=1
fi

b_ordering=$($PSQL <<SQL
SELECT (
  (SELECT occurred_at FROM sessions WHERE account_id=$ACCOUNT_B_ID AND kind='login') <
  (SELECT occurred_at FROM sessions WHERE account_id=$ACCOUNT_B_ID AND kind='disconnect')
)
SQL
)
check_eq "scenario B login < disconnect timestamp" "$b_ordering" "t"

echo
echo ">>> logs in $LOG/."
exit "$fail"
