---
name: dev nats broker uses --network host
description: Why the podman recipe for the dev NATS broker uses host networking instead of port mapping. Avoids re-debugging the same pasta failure.
type: project
originSessionId: 66fc34e7-0baa-4b1c-921e-326aaa61a1d8
---
The Makefile's `nats-up` recipe (and the matching `infra/compose.yml`) run nats with `--network host` (compose: `network_mode: host`).

**Why:** rootless pasta fails on the dev box (`Failed to set up tap device in namespace`) even though `/dev/net/tun` exists with 666 perms — pasta needs more setup than is currently in place, and `slirp4netns` isn't installed either. Plain `-p 4222:4222` therefore can't start the container. Host networking sidesteps the rootless network plumbing entirely.

**How to apply:** if you ever switch back to port-mapped networking ("ports: 4222:4222" in compose, or `-p` in the Makefile), expect that exact pasta error and either install `podman-compose`/`slirp4netns`, fix pasta's tun setup, or revert to host networking. Don't waste time on the symptom — it's an environmental thing, not a podman version issue.
