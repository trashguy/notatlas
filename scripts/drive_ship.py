#!/usr/bin/env python3
"""Interactive WASD driver for ship-sim — TCP→gateway→NATS.

Connects to the gateway's TCP port, sends a JWT hello frame, then
translates keypresses into length-prefixed JSON InputMsg frames
published to `sim.entity.<player_id>.input`. Use after starting
NATS, cell-mgr, ship-sim, and gateway (see scripts/drive_ship.sh).

Keys (no Enter required):
    W / S   — thrust forward / reverse (drives capsule when free-agent,
              the attached ship's helm when aboard)
    A / D   — steer left / right (same routing as thrust)
    F       — fire starboard cannon (only effective while aboard a ship;
              ~1.5 s reload)
    B       — board nearest ship within ~8 m (free-agent → passenger)
    G       — disembark (passenger → free-agent)
    space   — stop (thrust=0, steer=0)
    Q       — quit

Hold a key by tapping it repeatedly — thrust/steer are latched
server-side until the next tap. F is also latched but rate-limited
by the ship's cannon cooldown, so holding F sustains autoreload.
B and G are edge-triggered: ship-sim consumes the verb on the next
input msg and clears it.

Default --player-id is 0x02000001 (top-byte tag = EntityKind.player,
seq = 1). See docs/08 §2A and memory architecture_entity_id_kind_tag.md.
"""
import argparse, json, os, socket, struct, sys, termios, tty, threading, time, select
import mint_jwt

DEFAULT_PLAYER_ID = 0x02000001  # EntityKind.player | seq=1


def send_input(sock, thrust, steer, fire=False, board=False, disembark=False):
    msg = json.dumps({
        "thrust": thrust,
        "steer": steer,
        "fire": fire,
        "board": board,
        "disembark": disembark,
    }).encode()
    sock.sendall(struct.pack("<I", len(msg)) + msg)


def reader_thread(sock, stop_event):
    """Drain inbound frames so the gateway's send buffer doesn't fill
    up and stall the loop. Frame format: [u32_le len][u8 kind][payload].
    kind=0 state/cluster (count silently); kind=1 fire (print JSON
    so the user sees the cannonball flying)."""
    sock.settimeout(0.2)
    state_frames = 0
    fire_frames = 0
    last_print = time.monotonic()
    while not stop_event.is_set():
        try:
            hdr = sock.recv(4)
            if not hdr or len(hdr) < 4:
                continue
            (length,) = struct.unpack("<I", hdr)
            framed = b""
            remaining = length
            while remaining > 0:
                chunk = sock.recv(remaining)
                if not chunk:
                    return
                framed += chunk
                remaining -= len(chunk)
            if length < 1:
                continue
            kind = framed[0]
            payload = framed[1:]
            if kind == 0:
                state_frames += 1
            elif kind == 1:
                fire_frames += 1
                try:
                    sys.stderr.write(f"  [FIRE] {payload.decode(errors='replace')}\n")
                    sys.stderr.flush()
                except Exception:
                    pass
        except socket.timeout:
            pass
        except OSError:
            return
        now = time.monotonic()
        if now - last_print >= 1.0:
            sys.stderr.write(f"  [stream] {state_frames} state, {fire_frames} fire frames/s\n")
            sys.stderr.flush()
            state_frames = 0
            fire_frames = 0
            last_print = now


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=9000)
    ap.add_argument("--client-id", type=int, default=256)
    ap.add_argument("--player-id", type=lambda s: int(s, 0), default=DEFAULT_PLAYER_ID,
                    help=f"top-byte-tagged entity id; default 0x{DEFAULT_PLAYER_ID:08X}")
    args = ap.parse_args()

    secret = os.environ.get("NOTATLAS_JWT_SECRET", mint_jwt.DEV_SECRET)
    sock = socket.create_connection((args.host, args.port))
    # JWT hello — gateway requires this as the first frame.
    tok = mint_jwt.mint(args.client_id, args.player_id, 3600, secret).encode()
    sock.sendall(struct.pack("<I", len(tok)) + tok)
    print(f"connected to {args.host}:{args.port} as client_id={args.client_id} player_id=0x{args.player_id:08X}")
    print("controls: W/S thrust, A/D steer, F fire, B board, G disembark, space stop, Q quit")
    print("(ship-sim stdout shows ship#1 absolute position once per second)")

    stop_event = threading.Event()
    rx = threading.Thread(target=reader_thread, args=(sock, stop_event), daemon=True)
    rx.start()

    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    thrust, steer = 0.0, 0.0
    try:
        tty.setcbreak(fd)
        while True:
            ch = sys.stdin.read(1).lower()
            if ch == "q":
                break
            fire = False
            board = False
            disembark = False
            if ch == "w":
                thrust = 1.0
            elif ch == "s":
                thrust = -1.0
            elif ch == "a":
                steer = -1.0
            elif ch == "d":
                steer = 1.0
            elif ch == "f":
                # One-shot fire intent: send fire=true now; subsequent
                # WASD presses send fire=false (default arg).
                fire = True
            elif ch == "b":
                # Edge-triggered board verb: ship-sim picks the
                # nearest ship within ~8 m and transitions the
                # player to passenger.
                board = True
            elif ch == "g":
                # Edge-triggered disembark verb: passenger → free-
                # agent capsule at the ship-local pose lifted to
                # world.
                disembark = True
            elif ch == " ":
                thrust, steer = 0.0, 0.0
            else:
                continue
            send_input(sock, thrust, steer, fire=fire, board=board, disembark=disembark)
            verb_tag = ""
            if fire: verb_tag += " FIRE"
            if board: verb_tag += " BOARD"
            if disembark: verb_tag += " DISEMBARK"
            sys.stderr.write(f"  -> thrust={thrust:+.1f} steer={steer:+.1f}{verb_tag}\n")
            sys.stderr.flush()
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        stop_event.set()
        try:
            send_input(sock, 0.0, 0.0)
        except Exception:
            pass
        sock.close()
        print("disconnected")


if __name__ == "__main__":
    main()
