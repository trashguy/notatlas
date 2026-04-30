#!/usr/bin/env python3
"""Mint an HS256 JWT for the notatlas gateway.

Reads NOTATLAS_JWT_SECRET from the environment (matching the gateway's
default-resolution path) or falls back to the dev default.

Usage:
  python3 scripts/mint_jwt.py --client-id 256 --player-id 0x02000001 [--exp-secs 3600]

`player-id` accepts hex (0x02000001) or decimal. The top-byte tag is
the EntityKind discriminator (0x02 = player). See
src/shared/entity_kind.zig and memory architecture_entity_id_kind_tag.md.
"""
import argparse, base64, hashlib, hmac, json, os, sys, time

DEV_SECRET = "notatlas-dev-secret-do-not-deploy"


def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def mint(client_id: int, player_id: int, exp_secs: int, secret: str) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    claims = {
        "client_id": client_id,
        "player_id": player_id,
        "exp": int(time.time()) + exp_secs,
    }
    h = b64url(json.dumps(header, separators=(",", ":")).encode())
    p = b64url(json.dumps(claims, separators=(",", ":")).encode())
    signing = f"{h}.{p}".encode()
    sig = b64url(hmac.new(secret.encode(), signing, hashlib.sha256).digest())
    return f"{h}.{p}.{sig}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--client-id", type=lambda s: int(s, 0), required=True)
    ap.add_argument("--player-id", type=lambda s: int(s, 0), required=True)
    ap.add_argument("--exp-secs", type=int, default=3600)
    args = ap.parse_args()
    secret = os.environ.get("NOTATLAS_JWT_SECRET", DEV_SECRET)
    if secret == DEV_SECRET:
        print("warning: using dev-default JWT secret (NOTATLAS_JWT_SECRET unset)", file=sys.stderr)
    print(mint(args.client_id, args.player_id, args.exp_secs, secret))


if __name__ == "__main__":
    main()
