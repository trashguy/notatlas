#!/usr/bin/env bash
# inventory-sim end-to-end smoke. Verifies the fourth (and final)
# SLA-arc producer + the three durability protections in v0:
#
#   - Batching at the wire: one inv.mutate carries N mutations for
#     one character. A 1000-slot transfer = 1 NATS msg + 1 PG write.
#   - Coalescing at the service: configurable flush tick caps PG
#     writes at ~1/tick/character regardless of mutation rate.
#     Production default is 60 s (--flush-interval-ms 60000); this
#     smoke uses 300 ms so assertions don't take a minute.
#   - PG hydration on boot: service reads inventories+characters for
#     the current cycle at startup. Without this, a post-crash
#     restart starts empty and the next mutation overwrites the full
#     PG blob with a 1-slot partial. With it, the first mutation
#     merges into the rehydrated full state.
#
# Pass criterion (PG, hard-asserted):
#   Scenario 1 (bulk batch on fresh char):
#     - 1 inventories row with version >= 1
#     - blob.slots length >= 1000
#   Scenario 2 (coalescing on same char):
#     - 50 rapid 1-mutation batches in ~0 ms collapse to ≤2 emits
#   Scenario 3 (hydration on pre-seeded char):
#     - Pre-existing slot 99 survives the post-mutation flush
#     - New slot 0 mutation lands alongside it (NOT replacing)
#
# Usage:
#   ./scripts/inventory_smoke.sh

set -euo pipefail
cd "$(dirname "$0")/.."

LOG=/tmp/notatlas-inventory
mkdir -p "$LOG"
rm -f "$LOG"/*.log

CHAR_ID=301
ACCOUNT_ID=300
HYDRATE_CHAR_ID=311
HYDRATE_ACCOUNT_ID=310
FLUSH_MS=300

echo ">>> inventory smoke: char=$CHAR_ID hydrate_char=$HYDRATE_CHAR_ID flush_interval=${FLUSH_MS}ms"

if ! ss -lnt 2>/dev/null | grep -q :4222 || ! ss -lnt 2>/dev/null | grep -q :5432; then
  echo ">>> starting services (make services-up)"
  make services-up
  sleep 2
fi

zig build install

NATS_BOX="podman run --rm --network host docker.io/natsio/nats-box:latest"
PSQL="podman exec -i notatlas-pg psql -U notatlas -d notatlas -tA"

# Seed 2 accounts + 2 characters in the current cycle (UNIQUE(account_id,
# cycle_id) means one character per account per cycle).
echo ">>> seeding accounts + characters in current cycle"
CYCLE_ID=$($PSQL -c "SELECT id FROM wipe_cycles WHERE ends_at IS NULL;")
echo "    current cycle_id=$CYCLE_ID"
$PSQL >/dev/null <<SQL
INSERT INTO accounts (id, username, pass_hash) VALUES
  ($ACCOUNT_ID,         'inv_smoke',         E'\\\\x00'),
  ($HYDRATE_ACCOUNT_ID, 'inv_smoke_hydrate', E'\\\\x00')
  ON CONFLICT (id) DO NOTHING;
INSERT INTO characters (id, account_id, cycle_id, name) VALUES
  ($CHAR_ID,         $ACCOUNT_ID,         $CYCLE_ID, 'inv_char_$CYCLE_ID'),
  ($HYDRATE_CHAR_ID, $HYDRATE_ACCOUNT_ID, $CYCLE_ID, 'hydrate_char_$CYCLE_ID')
  ON CONFLICT (id) DO NOTHING;
SELECT setval('accounts_id_seq',   GREATEST((SELECT MAX(id) FROM accounts), 1));
SELECT setval('characters_id_seq', GREATEST((SELECT MAX(id) FROM characters), 1));
SQL

echo ">>> resetting inventories + events_inventory_change stream"
$PSQL -c "TRUNCATE inventories RESTART IDENTITY CASCADE;" >/dev/null
$NATS_BOX nats stream rm events_inventory_change -f >/dev/null 2>&1 || true

# Pre-seed inventories row for the hydration character so the
# service has something to load on boot. NB: this happens BEFORE
# inventory-sim starts, so the SELECT in hydrateFromPg picks it up.
echo ">>> pre-seeding hydrate-char inventory row (slot 99 / item 42 / qty 10)"
$PSQL >/dev/null <<SQL
INSERT INTO inventories (character_id, version, blob)
VALUES ($HYDRATE_CHAR_ID, 5, '{"slots":[{"slot":99,"item_def_id":42,"quantity":10}]}'::jsonb);
SQL

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
  if grep -q 'events_inventory_change.*ready' "$LOG/pwriter.log"; then break; fi
  sleep 0.1
done
if ! grep -q 'events_inventory_change.*ready' "$LOG/pwriter.log"; then
  echo "FAIL: pwriter didn't attach events_inventory_change in 5s"; cat "$LOG/pwriter.log"; exit 1
fi

echo ">>> starting inventory-sim --flush-interval-ms $FLUSH_MS"
zig-out/bin/inventory-sim --flush-interval-ms "$FLUSH_MS" > "$LOG/inventory-sim.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do
  if grep -q 'subscribed to inv.mutate' "$LOG/inventory-sim.log"; then break; fi
  sleep 0.1
done
if ! grep -q 'subscribed to inv.mutate' "$LOG/inventory-sim.log"; then
  echo "FAIL: inventory-sim didn't subscribe in 5s"; cat "$LOG/inventory-sim.log"; exit 1
fi

# Hydration check from the service log itself — we pre-seeded one
# row so the hydration count should be >= 1.
if ! grep -q 'hydrated [1-9][0-9]* characters' "$LOG/inventory-sim.log"; then
  echo "FAIL: inventory-sim didn't hydrate any characters"; cat "$LOG/inventory-sim.log"; exit 1
fi

# ---------------------------------------------------------------------------
# Scenario 1 — bulk batch: 1000 set-mutations in one NATS message.
# ---------------------------------------------------------------------------
echo ">>> scenario 1: 1000-slot bulk transfer in one message"
python3 - "$CHAR_ID" <<'PYEOF'
import json, subprocess, sys
char = int(sys.argv[1])
muts = [
    {"op": ord('S'), "slot": i, "item_def_id": (i % 16) + 1, "quantity": 1}
    for i in range(1000)
]
payload = json.dumps({"character_id": char, "mutations": muts})
subprocess.run(
    ["podman", "run", "--rm", "--network", "host", "-i", "docker.io/natsio/nats-box:latest",
     "nats", "pub", "-s", "nats://127.0.0.1:4222", "inv.mutate", payload],
    check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
)
PYEOF
sleep $(awk -v f="$FLUSH_MS" 'BEGIN{printf "%.2f", (f/1000.0) + 0.4}')  # one flush + pwriter drain

# ---------------------------------------------------------------------------
# Scenario 2 — coalescing: 50 single-mutation batches in rapid fire.
#   At 100 ms flush tick, 50 batches over ~200 ms must collapse to
#   ≤3 PG version bumps.
# ---------------------------------------------------------------------------
echo ">>> scenario 2: 50 chatty 1-mutation batches in ~200 ms (coalescing)"
VERSION_BEFORE=$($PSQL -c "SELECT version FROM inventories WHERE character_id=$CHAR_ID;")
echo "    version before scenario 2: $VERSION_BEFORE"

python3 - "$CHAR_ID" <<'PYEOF'
import json, socket, struct, sys, time
# nats-box has too much startup overhead for 50 calls — fall back to
# a raw NATS PUB on the protocol port. Format per
# https://docs.nats.io/reference/reference-protocols/nats-protocol.
char = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(("127.0.0.1", 4222))
# Consume INFO + send a minimal CONNECT so the server doesn't drop us.
s.recv(4096)
s.sendall(b'CONNECT {"verbose":false,"pedantic":false}\r\n')
start = time.monotonic()
for i in range(50):
    body = json.dumps({
        "character_id": char,
        "mutations": [{"op": ord('A'), "slot": 2000 + i, "item_def_id": 99, "quantity": 1}],
    }).encode()
    pub = b"PUB inv.mutate " + str(len(body)).encode() + b"\r\n" + body + b"\r\n"
    s.sendall(pub)
elapsed_ms = (time.monotonic() - start) * 1000
print(f"    50 PUBs sent in {elapsed_ms:.0f} ms", flush=True)
s.close()
PYEOF
sleep $(awk -v f="$FLUSH_MS" 'BEGIN{printf "%.2f", (f/1000.0) + 0.5}')  # next flush + drain

# ---------------------------------------------------------------------------
# Scenario 3 — hydration: pre-seeded slot 99 must survive a new
# mutation. If hydration is broken, slot 99 gets blown away because
# the service published a partial blob built from empty state +
# the new mutation only.
# ---------------------------------------------------------------------------
echo ">>> scenario 3: hydration (pre-seeded slot 99 must survive new mutation)"
python3 - "$HYDRATE_CHAR_ID" <<'PYEOF'
import json, subprocess, sys
char = int(sys.argv[1])
payload = json.dumps({
    "character_id": char,
    "mutations": [{"op": ord('A'), "slot": 0, "item_def_id": 7, "quantity": 3}],
})
subprocess.run(
    ["podman", "run", "--rm", "--network", "host", "-i", "docker.io/natsio/nats-box:latest",
     "nats", "pub", "-s", "nats://127.0.0.1:4222", "inv.mutate", payload],
    check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
)
PYEOF
sleep $(awk -v f="$FLUSH_MS" 'BEGIN{printf "%.2f", (f/1000.0) + 0.4}')

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
check_le() {
  local label="$1" actual="$2" max="$3"
  if [ "$actual" -le "$max" ]; then
    echo "PASS: $label = $actual (<= $max)"
  else
    echo "FAIL: $label = $actual (expected <= $max)"
    fail=1
  fi
}
check_ge() {
  local label="$1" actual="$2" min="$3"
  if [ "$actual" -ge "$min" ]; then
    echo "PASS: $label = $actual (>= $min)"
  else
    echo "FAIL: $label = $actual (expected >= $min)"
    fail=1
  fi
}

rows=$($PSQL -c "SELECT count(*) FROM inventories WHERE character_id=$CHAR_ID;")
check_eq "fresh char inventories row count" "$rows" "1"

# Scenario 1: blob has all 1000 seeded slots.
slot_count=$($PSQL -c "SELECT jsonb_array_length(blob->'slots') FROM inventories WHERE character_id=$CHAR_ID;")
check_ge "blob.slots length after scenario 1+2" "$slot_count" "1000"

# Spot-check slot 0 item_def_id (seeded as (0 % 16) + 1 = 1).
slot0_item=$($PSQL -c \
  "SELECT (slot->>'item_def_id')::int FROM inventories, \
   jsonb_array_elements(blob->'slots') slot \
   WHERE character_id=$CHAR_ID AND (slot->>'slot')::int = 0;")
check_eq "slot 0 item_def_id" "$slot0_item" "1"

# Scenario 2: coalescing — 50 rapid batches in ~0 ms.
VERSION_AFTER=$($PSQL -c "SELECT version FROM inventories WHERE character_id=$CHAR_ID;")
COALESCED=$((VERSION_AFTER - VERSION_BEFORE))
echo "    version after scenario 2: $VERSION_AFTER (delta: $COALESCED)"
# 50 PUBs landing inside one flush_interval should collapse to 1
# emit. Allow up to 2 in case of timing slop around the flush tick
# boundary — anything higher means the coalescer didn't fire.
check_le "coalesced flush count (50 batches → ≤2 emits)" "$COALESCED" "2"
check_ge "coalesced flush count (50 batches → ≥1 emit)" "$COALESCED" "1"

# Scenario 3 (hydration): pre-seeded slot 99 must still be in the
# blob, AND the new slot 0 must have landed alongside it. If the
# service started empty (no hydration), slot 99 is gone because the
# published blob was built from {slot 0 only}.
echo
echo "--- hydration check (HYDRATE_CHAR_ID=$HYDRATE_CHAR_ID) ---"
hydrate_rows=$($PSQL -c "SELECT count(*) FROM inventories WHERE character_id=$HYDRATE_CHAR_ID;")
check_eq "hydrate char inventories row count" "$hydrate_rows" "1"

slot99_qty=$($PSQL -c \
  "SELECT (slot->>'quantity')::int FROM inventories, \
   jsonb_array_elements(blob->'slots') slot \
   WHERE character_id=$HYDRATE_CHAR_ID AND (slot->>'slot')::int = 99;")
check_eq "pre-seeded slot 99 quantity survived" "$slot99_qty" "10"

new_slot0=$($PSQL -c \
  "SELECT (slot->>'quantity')::int FROM inventories, \
   jsonb_array_elements(blob->'slots') slot \
   WHERE character_id=$HYDRATE_CHAR_ID AND (slot->>'slot')::int = 0;")
check_eq "new slot 0 added (qty 3)" "$new_slot0" "3"

echo
echo ">>> logs in $LOG/."
exit "$fail"
