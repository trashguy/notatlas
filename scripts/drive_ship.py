#!/usr/bin/env python3
"""Interactive WASD driver for ship-sim — TCP→gateway→NATS.

Connects to the gateway's TCP port, sends a JWT hello frame, then
translates keypresses into length-prefixed JSON InputMsg frames
published to `sim.entity.<player_id>.input`. Use after starting
NATS, cell-mgr, ship-sim, and gateway (see scripts/drive_ship.sh).

Keys (no Enter required):
    W / S   — thrust forward / reverse
    A / D   — steer left / right
    F       — fire starboard cannon (one shot per tap, ~1.5 s reload)
    space   — stop (thrust=0, steer=0)
    Q       — quit

Hold a key by tapping it repeatedly — thrust/steer are latched
server-side until the next tap. F is also latched but rate-limited
by the ship's cannon cooldown, so holding F sustains autoreload.
"""
import argparse, json, os, socket, struct, sys, termios, tty, threading, time, select
import mint_jwt


def send_input(sock, thrust, steer, fire=False):
    msg = json.dumps({"thrust": thrust, "steer": steer, "fire": fire}).encode()
    sock.sendall(struct.pack("<I", len(msg)) + msg)


def reader_thread(sock, stop_event):
    """Drain inbound state frames so the gateway's send buffer doesn't
    fill up and stall the loop. We don't decode positions — ship-sim's
    stdout is the authoritative source for that — just count frames so
    the user can see traffic is flowing."""
    sock.settimeout(0.2)
    frames = 0
    last_print = time.monotonic()
    while not stop_event.is_set():
        try:
            hdr = sock.recv(4)
            if not hdr or len(hdr) < 4:
                continue
            (length,) = struct.unpack("<I", hdr)
            remaining = length
            while remaining > 0:
                chunk = sock.recv(remaining)
                if not chunk:
                    return
                remaining -= len(chunk)
            frames += 1
        except socket.timeout:
            pass
        except OSError:
            return
        now = time.monotonic()
        if now - last_print >= 1.0:
            sys.stderr.write(f"  [stream] {frames} state frames/s in last 1s\n")
            sys.stderr.flush()
            frames = 0
            last_print = now


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=9000)
    ap.add_argument("--client-id", type=int, default=256)
    ap.add_argument("--player-id", type=int, default=1)
    args = ap.parse_args()

    secret = os.environ.get("NOTATLAS_JWT_SECRET", mint_jwt.DEV_SECRET)
    sock = socket.create_connection((args.host, args.port))
    # JWT hello — gateway requires this as the first frame.
    tok = mint_jwt.mint(args.client_id, args.player_id, 3600, secret).encode()
    sock.sendall(struct.pack("<I", len(tok)) + tok)
    print(f"connected to {args.host}:{args.port} as client_id={args.client_id} player_id={args.player_id}")
    print("controls: W/S thrust, A/D steer, space stop, Q quit")
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
            elif ch == " ":
                thrust, steer = 0.0, 0.0
            else:
                continue
            send_input(sock, thrust, steer, fire=fire)
            sys.stderr.write(f"  -> thrust={thrust:+.1f} steer={steer:+.1f}{' FIRE' if fire else ''}\n")
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
