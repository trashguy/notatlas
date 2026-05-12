# notatlas

A from-scratch clone of the 2018-2020 era of Atlas (Grapeshot's pirate
MMO), built on a custom Zig engine. The thing Atlas tried to build
before scope and tech failures killed it: smooth naval combat at
scale, harbor raids that don't tank FPS, and deep crafting with
global resource sourcing.

This is the **substrate** repo — engine subsystems (wave query,
buoyancy, wind, ship physics) and service mesh (gateway, ship-sim,
cell-mgr, spatial-index, env, persistence-writer, market-sim,
inventory-sim, ai-sim). The renderer side is a custom GPU-driven
Vulkan pipeline written from scratch.

## Status — 2026-05-12

Phase 2 (architectural payoff) is in progress. Phase 0 (engine water
lift) closed 2026-04-28; Phase 1 (networked ship combat) closed
2026-05-01. The SLA-arc persistence layer + env service are closed as
of 2026-05-12; the M10/M11/M12 client renderer milestones are next.

See [`docs/04-roadmap.md`](docs/04-roadmap.md) for the phase plan and
[`docs/README.md`](docs/README.md) for the documentation index.

## Repository map

```
data/        # YAML-driven content: hulls, ammo, waves, wind, raid
             # windows, AI archetypes (.yaml + .lua per archetype).
docs/        # Design + architecture docs. Start at docs/README.md.
infra/       # Local-dev NATS + PostgreSQL provisioning.
scripts/     # Smoke harnesses (one per producer/consumer), JWT mint,
             # driver scripts.
src/         # Zig sources.
  services/  # One subdir per service: gateway, ship-sim, cell-mgr,
             # spatial-index, env-sim, persistence-writer, market-sim,
             # inventory-sim, ai-sim.
  shared/    # Cross-service modules: BT runtime, Lua bind, replication
             # tier table, projectile model.
vendor/      # Vendored C deps (Lua 5.4, Jolt Physics).
```

## Quick start

Requires Zig 0.15.2, Podman (or Docker), and ~/Projects/fallen-runes
checked out at the same level as the reference for shared patterns.

```bash
# Build all binaries (sandbox client + services).
zig build install

# Start NATS + PostgreSQL in the background.
make services-up

# Run the sandbox player loop (5 ships at x=0..240, WASD walk, B board,
# G disembark, F fire). Spins up the service mesh under the hood.
./scripts/drive_ship.sh

# Run individual service mesh by hand:
./zig-out/bin/env-sim &
./zig-out/bin/spatial-index &
./zig-out/bin/cell-mgr --cell 0_0 &
./zig-out/bin/ship-sim --shard a --ships 5 &
./zig-out/bin/ai-sim &
./zig-out/bin/persistence-writer &
./zig-out/bin/gateway &
./zig-out/bin/market-sim &
./zig-out/bin/inventory-sim &
```

## Testing

```bash
zig build test              # All Zig unit tests
./scripts/*_smoke.sh        # Per-feature integration smokes
```

The smoke harnesses are the canonical regression check for the SLA
arc, env-service consumers, transit, and cross-service wires. Each
harness boots the minimum subset of the mesh it needs.

## Project orientation (for AI / new contributors)

- [`CLAUDE.md`](CLAUDE.md) — project-specific operating rules.
  Locked decisions; the engine substrate is committed (no UE5 / Godot
  / Bevy / Unity proposals).
- [`docs/02-architecture.md`](docs/02-architecture.md) — the ten locked
  architectural decisions. Don't relitigate.
- [`docs/04-roadmap.md`](docs/04-roadmap.md) — phased plan + stress
  gates between phases.
- [`docs/07-anti-patterns.md`](docs/07-anti-patterns.md) — Atlas
  failures we will not replicate.

## Why this exists

Atlas's design space remains underserved — Sea of Thieves is too
arcade, Skull and Bones flopped, and Atlas itself was abandoned by
Grapeshot. The opportunity is to build the same vision with the
lessons from Atlas's failures applied and a substantially better
technical substrate: HFT-style per-entity NATS subjects, a spatial
index that's an interest manager (not a state owner), a GPU-driven
renderer that scales to hundreds of structures, and a data-driven
content pipeline so designers can iterate without a full rebuild.

## License

Code: TBD. Third-party deps + their licenses listed in
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).
