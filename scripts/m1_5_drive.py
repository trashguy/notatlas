#!/usr/bin/env python3
"""M1.5 stress-gate orchestrator.

Opens N TCP connections to the gateway and drains length-prefixed
frames as fast as possible for `measure_s` seconds, reporting per-
connection bandwidth. Pass criterion (docs/04 §M1.5):
max(per-conn bytes/sec) ≤ 1 Mbps (= 125000 B/s).

Two modes:
  - --multi-gateway (default): N gateway processes on consecutive
    ports starting at --port-base. Per-process-per-client workaround
    used during the original M1.5 gate run.
  - --single-gateway: one gateway process on --port-base, N
    concurrent JWT-authenticated connections. Validates the
    multi-client + JWT path that replaces the workaround.

Usage:
  python3 scripts/m1_5_drive.py --n-subs 50 --port-base 9000 --measure-s 20
  python3 scripts/m1_5_drive.py --n-subs 50 --port-base 9000 --measure-s 20 --single-gateway
"""
import argparse, socket, struct, threading, time, sys, statistics
import mint_jwt

ONE_MBPS_BYTES = 125_000  # 1 Mbps = 1_000_000 bits / 8

class Conn:
    __slots__ = ("idx", "sock", "frames", "bytes", "ents", "fail")

    def __init__(self, idx, sock):
        self.idx = idx
        self.sock = sock
        self.frames = 0
        self.bytes = 0
        self.ents = 0
        self.fail = None

def reader(c, deadline):
    """Frame format (gateway → client): [u32_le len][u8 kind][payload].
    `len` includes the 1-byte kind. kind=0 cmd (binary state/cluster),
    kind=1 fire (JSON). For M1.5 we count all frames toward the
    bandwidth gate but only inspect kind=0 payloads for the entity
    accounting (kind=1 fire frames are sparse).
    """
    s = c.sock
    s.settimeout(0.5)
    while time.monotonic() < deadline:
        try:
            hdr = s.recv(4, socket.MSG_WAITALL)
            if not hdr or len(hdr) < 4:
                continue
            (length,) = struct.unpack("<I", hdr)
            framed = s.recv(length, socket.MSG_WAITALL)
            if not framed or len(framed) < length:
                continue
            c.frames += 1
            c.bytes += 4 + length
            if length < 1:
                continue
            kind = framed[0]
            payload = framed[1:]
            if kind == 0 and len(payload) >= 8:
                ent_ct, _ = struct.unpack("<II", payload[:8])
                c.ents += ent_ct
        except socket.timeout:
            continue
        except OSError as e:
            c.fail = repr(e)
            return

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n-subs", type=int, default=50)
    ap.add_argument("--port-base", type=int, default=9000)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--measure-s", type=int, default=20)
    ap.add_argument("--single-gateway", action="store_true",
                    help="all conns target one gateway on port-base; sends JWT hello per conn")
    ap.add_argument("--client-id-base", type=int, default=256)
    args = ap.parse_args()

    import os
    secret = os.environ.get("NOTATLAS_JWT_SECRET", mint_jwt.DEV_SECRET)

    mode = "single-gateway+JWT" if args.single_gateway else "multi-gateway+JWT"
    if args.single_gateway:
        print(f">>> opening {args.n_subs} TCP conns to {args.host}:{args.port_base} ({mode})")
    else:
        print(f">>> opening {args.n_subs} TCP conns to {args.host}:{args.port_base}..{args.port_base+args.n_subs-1} ({mode})")
    conns = []
    fail_open = 0
    for i in range(args.n_subs):
        port = args.port_base if args.single_gateway else args.port_base + i
        client_id = args.client_id_base + i
        player_id = i + 1
        try:
            s = socket.create_connection((args.host, port), timeout=5)
            # JWT hello is required by the multi-client gateway in
            # both modes — gateway speaks one protocol regardless of
            # how many TCP ports are exposed.
            tok = mint_jwt.mint(client_id, player_id, exp_secs=3600, secret=secret).encode()
            s.sendall(struct.pack("<I", len(tok)) + tok)
            conns.append(Conn(i, s))
        except OSError as e:
            print(f"  conn {i} (port {port}) FAILED to open: {e}")
            fail_open += 1
    print(f">>> {len(conns)}/{args.n_subs} conns open; {fail_open} failed")
    if not conns:
        sys.exit(1)

    print(f">>> warming up 2 s, measuring for {args.measure_s} s")
    time.sleep(2)
    # Drain warmup data so it doesn't pollute the measurement window.
    for c in conns:
        c.frames = 0
        c.bytes = 0
        c.ents = 0

    deadline = time.monotonic() + args.measure_s
    threads = [threading.Thread(target=reader, args=(c, deadline), daemon=True) for c in conns]
    for t in threads: t.start()
    measure_start = time.monotonic()
    for t in threads: t.join(timeout=args.measure_s + 2)
    measure_end = time.monotonic()
    elapsed = measure_end - measure_start
    print(f">>> measurement window {elapsed:.2f} s")

    # Per-conn rates.
    rates_bps = []
    rates_fps = []
    rates_ent_per_s = []
    fails = []
    for c in conns:
        if c.fail:
            fails.append(f"conn {c.idx}: {c.fail}")
        rates_bps.append(c.bytes / elapsed)
        rates_fps.append(c.frames / elapsed)
        rates_ent_per_s.append(c.ents / elapsed)

    if not rates_bps:
        print("no data")
        sys.exit(1)

    bps_min = min(rates_bps)
    bps_max = max(rates_bps)
    bps_mean = statistics.mean(rates_bps)
    bps_median = statistics.median(rates_bps)
    bps_p95 = sorted(rates_bps)[int(0.95 * len(rates_bps))]

    print()
    print("=== M1.5 per-conn TCP outbound bandwidth ===")
    print(f"conns measured: {len(conns)}")
    print(f"  min     : {bps_min:>10.0f} B/s = {bps_min*8/1000:.1f} kbps")
    print(f"  median  : {bps_median:>10.0f} B/s = {bps_median*8/1000:.1f} kbps")
    print(f"  mean    : {bps_mean:>10.0f} B/s = {bps_mean*8/1000:.1f} kbps")
    print(f"  p95     : {bps_p95:>10.0f} B/s = {bps_p95*8/1000:.1f} kbps")
    print(f"  max     : {bps_max:>10.0f} B/s = {bps_max*8/1000:.1f} kbps")
    print()
    print(f"frames/s mean: {statistics.mean(rates_fps):.1f} (target ~90 = 60 fast + 30 slow)")
    print(f"ents/s mean  : {statistics.mean(rates_ent_per_s):.1f} (target ~1800 = 30 ships × 60 Hz)")
    print()
    over_budget = [c for c, r in zip(conns, rates_bps) if r > ONE_MBPS_BYTES]
    print(f"=== gate: per-conn ≤ 1 Mbps ({ONE_MBPS_BYTES} B/s) ===")
    if over_budget:
        print(f"  FAIL — {len(over_budget)} of {len(conns)} conns exceeded budget")
        for c in over_budget[:10]:
            r = next(r for cc, r in zip(conns, rates_bps) if cc.idx == c.idx)
            print(f"    conn {c.idx}: {r:.0f} B/s = {r*8/1000:.1f} kbps")
        sys.exit(2)
    print(f"  PASS — max {bps_max*8/1000:.1f} kbps is {bps_max/ONE_MBPS_BYTES*100:.1f}% of 1 Mbps budget")

    if fails:
        print()
        print(f"=== {len(fails)} reader thread fail(s) ===")
        for f in fails[:5]:
            print(f"  {f}")

if __name__ == "__main__":
    main()
