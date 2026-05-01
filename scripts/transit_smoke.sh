#!/usr/bin/env bash
# Cross-cell ship transit smoke. Brings up spatial-index + two
# cell-mgrs (0_0 and 1_0) + ship-sim, kicks ship#1 along +X with
# --init-vel-x, and watches the cell-handoff path:
#
#   1. spatial-index emits exit on cell.0_0 + enter on cell.1_0 at
#      the x=200 boundary (one event each, no thrash thanks to
#      cell hysteresis).
#   2. cell-mgr 0_0's entity table shows the ship until handoff,
#      then drops it; cell-mgr 1_0 picks it up.
#   3. A synthetic subscriber registered with cell 1_0 ONLY
#      (its primary/home cell, per the cell-mgr design — see
#      fanout.zig relayState docstring + docs/08 §2A) receives
#      ship state continuously across the boundary, including
#      while the ship is still in cell 0_0. The cell-mgr that
#      owns the sub forwards every entity within visual tier of
#      the sub's pose, regardless of which cell the entity is in.
#
# Pass criterion (visual): the dumped deltas show exactly one
# exit on 0_0 followed by one enter on 1_0, both near x=201
# (1 m past the boundary, per `cell_hysteresis_m`). cell-mgr 0_0
# reports `0 subs` throughout (sub is on 1_0). cell-mgr 1_0
# reports `1 subs` and pushes ~2 state-msgs/tick the entire run.
# Frame count to client_id=999 stays > 0.
#
# Usage:
#   ./scripts/transit_smoke.sh [init_vel_mps]
#     init_vel_mps default 600 — high enough that drag doesn't
#     stop the ship before it reaches cell 1_0.

set -euo pipefail
cd "$(dirname "$0")/.."

INIT_VEL="${1:-600}"
LOG=/tmp/notatlas-transit
mkdir -p "$LOG"
rm -f "$LOG"/*.log

echo ">>> transit smoke: init_vel=$INIT_VEL m/s"

if ! ss -lnt 2>/dev/null | grep -q :4222; then
  echo ">>> starting NATS"
  make nats-up
fi

zig build

PIDS=()
cleanup() {
  echo ">>> stopping ${#PIDS[@]} processes"
  for pid in "${PIDS[@]}"; do
    kill -INT "$pid" 2>/dev/null || true
  done
  wait "${PIDS[@]}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Backbone.
zig-out/bin/spatial-index            > "$LOG/spatial-index.log" 2>&1 &
PIDS+=($!)
zig-out/bin/cell-mgr --cell 0_0      > "$LOG/cm-0_0.log" 2>&1 &
PIDS+=($!)
zig-out/bin/cell-mgr --cell 1_0      > "$LOG/cm-1_0.log" 2>&1 &
PIDS+=($!)
sleep 1

# Start the delta + fanout sniffers BEFORE ship-sim so we don't
# miss the spawn-time enter delta.
NATS_BOX="podman run --rm --network host docker.io/natsio/nats-box:latest"
$NATS_BOX nats sub -s nats://127.0.0.1:4222 'idx.spatial.cell.*.delta' \
  > "$LOG/deltas.log" 2>&1 &
PIDS+=($!)
$NATS_BOX nats sub -s nats://127.0.0.1:4222 'gw.client.999.cmd' \
  > "$LOG/fanout.log" 2>&1 &
PIDS+=($!)

# Register the synthetic subscriber with its PRIMARY cell only,
# per the cell-mgr design (docs/08 §2A + fanout.zig relayState
# docstring): the cell-mgr that owns the sub forwards every
# entity within visual tier of the sub's pose, regardless of
# which cell the entity itself is in. So a sub at (300, 0, 0)
# registered solely with cell 1_0 still receives state for ships
# in cell 0_0 or 2_0 if they're close enough — cross-cell
# visibility is a (sub × entity-pose) geometry computation, not a
# per-cell subscription. The earlier version of this smoke
# registered the sub with BOTH cells and counted duplicate
# forwards; that's a misuse of the API, not a relayState bug.
SUB_PAYLOAD='{"op":"enter","client_id":999,"x":300,"y":0,"z":0}'
$NATS_BOX nats pub -s nats://127.0.0.1:4222 'cm.cell.1_0.subscribe' "$SUB_PAYLOAD" >/dev/null 2>&1

# Kick the ship.
zig-out/bin/ship-sim --shard a --ships 1 --players 0 \
  --ship-max-hp 9999 --wind-speed 0 --init-vel-x "$INIT_VEL" \
  > "$LOG/ship-sim.log" 2>&1 &
PIDS+=($!)

# Watch the transit happen (~1 s at v=600 to cross x=200, plus
# a few seconds of post-transit fanout).
sleep 5

echo
echo "=== spatial-index deltas ==="
grep -E 'Received on|"op"' "$LOG/deltas.log" | head -20
echo
echo "=== cell-mgr 0_0 (no sub registered here — should report 0 subs) ==="
echo "ent>0 lines (sample):"
grep -E '[1-9][0-9]* ents' "$LOG/cm-0_0.log" | tail -3
echo "max subs seen: $(awk -F'ents, ' '/ents/ {split($2, a, " subs"); print a[1]}' "$LOG/cm-0_0.log" | sort -nu | tail -1)"
echo
echo "=== cell-mgr 1_0 (primary cell for sub at x=300) ==="
echo "ent>0 lines (sample):"
grep -E '[1-9][0-9]* ents' "$LOG/cm-1_0.log" | tail -3
echo "max subs seen: $(awk -F'ents, ' '/ents/ {split($2, a, " subs"); print a[1]}' "$LOG/cm-1_0.log" | sort -nu | tail -1)"
echo
echo "=== fanout delivery for client_id=999 ==="
# fanout.log is mostly binary (PayloadHeader + pose codec); count
# the text frame banners nats-box prints between msgs.
echo "frames received: $(grep -ac '^\[#' "$LOG/fanout.log" || true)"
echo "(should be > 0 the entire transit; ~450 frames over 5 s on dev box)"
echo
echo "=== ship#1 final state ==="
$NATS_BOX nats sub -s nats://127.0.0.1:4222 'sim.entity.16777217.state' --count 1 2>/dev/null \
  | grep -E '^\{' | head -1

echo
echo ">>> done. Logs in $LOG/."
