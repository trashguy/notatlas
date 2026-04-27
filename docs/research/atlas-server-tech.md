# R3 — Atlas Server Architecture (For Reference)

The original Atlas's server architecture as best as can be reconstructed
from public sources. Used to inform [02-architecture.md](../02-architecture.md)
— specifically what notatlas reuses (the seamless grid concept) and what
notatlas replaces (the implementation).

## Tech stack and origins

- **Engine:** Unreal Engine 4
- **Codebase:** Direct fork of ARK: Survival Evolved. Atlas was prototyped
  as a sublevel / mod of ARK before being spun out. Developed by Grapeshot
  Games, a Studio Wildcard sister company founded by ARK alumni (Jeremy
  Stieglitz, Jesse Rapczak) specifically to separate Atlas from Snail
  Games' grip on Wildcard.
- **Dedicated server binaries:** ARK-style `ShooterGameServer` reused —
  one process per grid cell, launched with
  `?ServerX=N?ServerY=M?SeamlessIP=<external IP>` command-line args.
- **State store:** Redis. Single Redis instance acts as the cross-server
  state layer; every cell server in the cluster connects to it.
  Configured via `ServerGrid.ServerOnly.json` (`DatabaseConnections`
  block).
- **Configuration tooling:** Open-source ServerGridEditor — a desktop app
  that produces `ServerGrid.json` (cluster topology),
  `ServerGrid.ServerOnly.json` (Redis creds, gridSize), and per-cell map
  images (`CellImg_X-Y.png`).

## Grid system

- **Launch topology:** 15×15 = 225 servers, one UE4 dedicated process
  per cell.
- **Cell unit:** Each cell is 1×1 in grid space; `gridSize` is in Unreal
  units, recommended max ~1,400,000 UU per side (limited by UE4 single-
  precision floats — the same `WORLD_MAX` issue ARK hit).
- **Coordinate addressing:** Letter-number (A1 .. O15). Cell indices
  double as time-zone offsets in single-player mode (one hour per
  longitude letter).
- **Advertised scale:** "1,200× larger than ARK", up to 40,000
  concurrent players across the world.
- **Actual peak:** 58,788 CCU (Steam, December 2018 launch); ~39 k
  average that month before steep decline.
- **Hardware footprint (private hosting community data):**
  - 1×1: 4 GB RAM, 2 cores
  - 2×2: 16 GB RAM, 8 cores
  - 4×4: ~50 GB RAM, 32 threads, 70-80% CPU sustained
  - Implication: each cell process consumed ~3-4 GB RAM and ~2 threads
    under load.
- **`WorldAtlasId`:** UUID baked into every cell's config; cells refuse
  to talk to peers with a different ID. Prevents cross-cluster
  contamination.

## Seamless server transitions

- Implemented via `SeamlessIP` launch param: each cell told the external
  IPs of its neighbors. When a player / ship's actor crossed the cell
  boundary, the origin server handed the actor (and its inventory,
  attached entities, passengers) to the destination server.
- **Not truly seamless in practice:** ~2 second hitch / black freeze;
  you couldn't see across the border until loaded into the new cell.
  Community consensus is "stutter-transition," not Eve-style or
  SpatialOS-style continuous space.
- Ships, dinos, players, and crew were all serialized through the
  transition. Bug history (offline players falling off ships into
  freeports, transient combat-state lockouts) confirms transition was
  implemented as a serialize / teleport handoff, not shared simulation.

## Zone / cell types

- **Freeports** (16 cells: M2, I3, E4, L5, A6, G7, M7, L8, D8, J9, M9,
  A10, E12, L12, H13, C14): starter / safe zones. No PvP, no base
  building on land, vendor NPCs, character spawn points (`HomeServer`
  flag in editor).
- **Lawless** zones: PvP enabled, no claim flags possible, structures
  decay in 4 days. Higher-tier resources, more aggressive creature
  spawns.
- **Claimable** zones: standard land that supports company claim flags.
- **Golden Age Ruins** (7 cells: C6, H6, O7, F8, D12, M12, O14): endgame
  Power Stone islands with bosses (Hydra or Dragon per island).
- **Kraken's Maw**: A11 — endgame raid cell.

## Biomes / climate

- 6 biome templates assigned per cell via the editor's "Template"
  dropdown: Polar, Tundra, Temperate, Tropical, Desert, Equatorial.
- Distribution mimics Earth: poles cold (top / bottom rows), equator hot
  (middle rows). Climate is per-cell config, not procedurally derived.

## Claim and territory system

- **Original (Empires / launch) model:** Players plant a Claim Flag; it
  confers a sphere of building protection. No company-wide cap on flags.
  Caused the infamous **flag-spam meta** — small companies blanketed
  entire islands with flags then logged off, locking out new players.
- **Colonies rework (Mega-Update 1.5, April 11 2019):** Server wipe.
  Replaced flags with island-level Settlements. Each island a single
  ownable unit; companies have Island Points that scale with member
  count. A 36-person company had ~115 Island Points. Owners pay
  periodic Gold Coin upkeep.

## Game modes (post-1.5)

- **Colonies PvP** (NA & EU): smaller companies, time-windowed combat
  phase, settlement system.
- **Empires PvP** (NA): legacy unrestricted-claim mode for large
  companies / wars.
- **PvE** (EU): Colonies rules with PvP combat disabled.
- **Single Player** mode runs the same 15×15 grid locally, swapping
  cells as the player moves.

## Networking / state layer summary

- Per-cell UE4 server: simulates physics, replication, AI, structures
  within its 1,400,000 UU box.
- Redis: holds player records, tribe / company data, claim / settlement
  ownership, flag positions, ship registry, cross-cell handoff
  envelopes, Discovery progression. Effectively the only globally-
  consistent store.
- Cluster start order: Redis first, then any cell process; cells re-
  register on boot. Add / remove cells without rebuilding the world by
  editing `ServerGrid.json` and restarting affected processes.
- No sharded simulation, no spatial-partition magic, no SpatialOS — a
  flat grid of independent UE4 dedicated servers stitched together by
  IP-list handoffs and a shared Redis.

## Why this matters for notatlas

The original architecture was conceptually simple but operationally
heavy. The interesting bits were:

1. The cross-cell actor handoff protocol over UE replication boundaries
2. Redis as the single source of truth for anything crossing cell
   boundaries
3. Per-cell biome / climate / spawn config driven entirely from a
   single editor-generated JSON

The unsolved bits were:

1. Real seamlessness (their handoff stuttered)
2. Claim system design (took a wipe + total redesign to fix)
3. Graceful scale-down (idle cells still cost full RAM / CPU because UE4
   dedicated servers don't hibernate well)

notatlas's [02-architecture.md](../02-architecture.md) addresses each
of these with a different model — entity-keyed NATS subjects with cells
as interest managers, JetStream-backed event log instead of Redis-
pinned state, cells that subscribe to nothing when idle (and thus cost
nothing).

## Postmortem availability

There is no formal GDC talk or written postmortem from Grapeshot. Public
technical info comes from:

- The open-sourced ServerGridEditor repo + wiki:
  https://github.com/GrapeshotGames/ServerGridEditor
- AtlasTerritoryMap source:
  https://github.com/GrapeshotGames/AtlasTerritoryMap
- Atlas Wiki (Fandom): https://atlas.fandom.com/wiki/Server_setup
- Steam patch notes archive (esp. Mega-Update 1.5, April 11 2019)
- Massively Overpowered coverage of Colonies/Empires split
- Jat (Jatheish, community manager) tweets / forum posts during the
  troubled launch
