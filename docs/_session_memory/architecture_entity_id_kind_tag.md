---
name: EntityId top-byte = kind tag
description: Locked 2026-04-30. notatlas EntityId.id (u32) is split as (kind:u8 << 24) | seq:u24. Top byte = kind, lower 24 bits = sequence. 16M ids per kind, 256 kinds. Decoded by every service that routes by entity kind.
type: project
originSessionId: 1db61b4b-4308-48b3-88c8-aea4bd15b6a5
---
EntityId.id is `u32` and is split top-byte as kind tag: `id = (kind:u8 << 24) | seq:u24`.

| Kind byte | Range | Use |
|---|---|---|
| `0x00` | 1..16M | world / static / unspecified |
| `0x01` | `0x01000000..0x01FFFFFF` | ships (player + NPC, anchored + sailing) |
| `0x02` | `0x02000000..0x02FFFFFF` | players |
| `0x03` | `0x03000000..0x03FFFFFF` | projectiles |
| `0x04+` | reserved | future (corpses, deployables, mounts, structures, NPCs, sea creatures, env hazards) |

`kind = id >> 24` is one shift — no hashmap lookup. Lives in `src/shared/entity_kind.zig` (or wherever the module lands; grep `EntityKind` to find it).

**Why:** prior plan was to start players at id=1000, leaving ships in 1..999 — caps ships at 999, breaks the moment we have a fleet event or many anchored small craft. Top-byte tagging gives 16M per kind for the same cost (one shift) and 256 kind slots forever. User specifically called out "1000s of players in a brawl mode" as a future scenario — top byte handles 4000-player single-cell brawls × 200 cells comfortably.

**How to apply:** when spawning entities in any service, OR with the kind constant: `id = EntityKind.ship | seq` not `id = seq`. When routing input/state by kind in ship-sim or spatial-index, switch on `id >> 24`. Wire format (`sim.entity.<id>.*`) doesn't change — the id just carries the tag bits in its top byte. Smaller per-kind ranges (top nibble, top 16 bits) are strictly worse: more bits to the tag, less per-kind headroom, same arithmetic cost.
