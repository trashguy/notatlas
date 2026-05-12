#!/usr/bin/env bash
# Gateway raid-window gate smoke. Verifies the env.time consumer
# path closes the SLA-arc loop on env-sim:
#
#   Scenario A — always-open window: yaml with [(0.0, 1.0)]. Login
#                MUST succeed; gateway log shows gate OPEN.
#   Scenario B — narrow closed window: yaml with [(0.9, 1.0)] and
#                day_length=1200 s. ~1.5 s after boot day_fraction is
#                near 0, outside the window → login MUST be rejected
#                with reason raid_window_closed.
#
# The fail-open-until-first-env.time behavior (graceful degradation)
# is what makes gateway_session_smoke.sh unaffected; this smoke
# explicitly boots env-sim so the gate enforces.
#
# Usage:
#   ./scripts/raid_window_smoke.sh

set -euo pipefail
cd "$(dirname "$0")/.."

ACCOUNT_ID=44
PLAYER_ID=$((0x02000010))
LOG=/tmp/notatlas-raid-window
mkdir -p "$LOG"
rm -f "$LOG"/*.log

echo ">>> gateway raid-window smoke (acct=$ACCOUNT_ID, player=0x$(printf '%x' $PLAYER_ID))"

if ! ss -lnt 2>/dev/null | grep -q :4222; then
  echo ">>> starting NATS"
  make nats-up
  sleep 1
fi

zig build install

PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do
    kill -INT "$pid" 2>/dev/null || true
  done
  wait "${PIDS[@]}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Helper: open TCP, send JWT, wait, close. Returns gateway's response
# behavior implicitly via the gateway log.
connect_with_jwt() {
  local jwt="$1"
  python3 - "$jwt" <<'PYEOF'
import socket, struct, sys, time
jwt = sys.argv[1].encode()
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(("127.0.0.1", 9000))
s.sendall(struct.pack("<I", len(jwt)) + jwt)
time.sleep(1.0)
s.close()
PYEOF
}

# ---------------------------------------------------------------------------
# Scenario A — always-open
# ---------------------------------------------------------------------------
echo
echo "=== Scenario A: always-open window [(0.0, 1.0)] ==="
WIN_A="$LOG/raid_windows_A.yaml"
cat > "$WIN_A" <<EOF
windows:
  - start: 0.0
    end: 1.0
EOF

zig-out/bin/env-sim --day-length-s 1200 > "$LOG/env-sim-A.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do
  if grep -q "publishing wind" "$LOG/env-sim-A.log"; then break; fi
  sleep 0.1
done

zig-out/bin/gateway --raid-windows "$WIN_A" > "$LOG/gateway-A.log" 2>&1 &
GW_A=$!
PIDS+=($GW_A)
for _ in $(seq 1 50); do
  if grep -q 'gateway: connected' "$LOG/gateway-A.log"; then break; fi
  sleep 0.1
done

# Wait for at least one env.time receipt so the gate has a day_fraction.
sleep 1.5

JWT=$(python3 scripts/mint_jwt.py --client-id "$ACCOUNT_ID" --player-id "$PLAYER_ID" 2>/dev/null)
connect_with_jwt "$JWT"
sleep 0.5

# Tear down scenario A.
kill -INT "$GW_A" 2>/dev/null || true
wait "$GW_A" 2>/dev/null || true
PIDS=("${PIDS[@]/$GW_A/}")
# env-sim too — clean slate for B.
for pid in "${PIDS[@]}"; do
  if [ -n "$pid" ]; then kill -INT "$pid" 2>/dev/null || true; fi
done
wait 2>/dev/null || true
PIDS=()

# ---------------------------------------------------------------------------
# Scenario B — closed window
# ---------------------------------------------------------------------------
echo
echo "=== Scenario B: closed window [(0.9, 1.0)] @ day_length=1200s ==="
WIN_B="$LOG/raid_windows_B.yaml"
cat > "$WIN_B" <<EOF
windows:
  - start: 0.9
    end: 1.0
EOF

zig-out/bin/env-sim --day-length-s 1200 > "$LOG/env-sim-B.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do
  if grep -q "publishing wind" "$LOG/env-sim-B.log"; then break; fi
  sleep 0.1
done

zig-out/bin/gateway --raid-windows "$WIN_B" > "$LOG/gateway-B.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do
  if grep -q 'gateway: connected' "$LOG/gateway-B.log"; then break; fi
  sleep 0.1
done

# Wait for at least one env.time receipt.
sleep 1.5

JWT_B=$(python3 scripts/mint_jwt.py --client-id "$ACCOUNT_ID" --player-id "$PLAYER_ID" 2>/dev/null)
connect_with_jwt "$JWT_B"
sleep 0.5

# ---------------------------------------------------------------------------
# Assertions.
# ---------------------------------------------------------------------------
echo
fail=0

# Scenario A: gateway logged a successful conn (client_id) AND no raid-window reject.
if grep -q "conn .* from .* → client_id=$ACCOUNT_ID" "$LOG/gateway-A.log"; then
  echo "PASS: scenario A login accepted (gate OPEN; day in [0.0, 1.0])"
else
  echo "FAIL: scenario A login NOT logged as accepted"
  tail -20 "$LOG/gateway-A.log"
  fail=1
fi
if grep -q "raid window closed" "$LOG/gateway-A.log"; then
  echo "FAIL: scenario A unexpectedly rejected for raid-window"
  fail=1
else
  echo "PASS: scenario A had zero raid-window rejections"
fi

# Scenario B: gateway logged a raid-window reject AND zero successful logins.
if grep -q "raid window closed" "$LOG/gateway-B.log"; then
  echo "PASS: scenario B login rejected (gate CLOSED; day outside [0.9, 1.0])"
else
  echo "FAIL: scenario B did NOT log a raid-window rejection"
  tail -20 "$LOG/gateway-B.log"
  fail=1
fi
if grep -q "conn .* from .* → client_id=" "$LOG/gateway-B.log"; then
  echo "FAIL: scenario B unexpectedly accepted a login"
  fail=1
else
  echo "PASS: scenario B accepted zero logins"
fi

echo
echo ">>> logs in $LOG/."
exit "$fail"
