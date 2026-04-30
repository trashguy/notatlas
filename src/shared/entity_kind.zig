//! Top-byte-tagged entity id space. `EntityId.id` is `u32` split as
//! `(kind:u8 << 24) | seq:u24` — top byte names the entity kind, low
//! 24 bits are the per-kind sequence. `kind = id >> 24` is one shift,
//! no hashmap lookup, so the per-tick router in ship-sim and
//! spatial-index can dispatch by kind in line.
//!
//! Locked 2026-04-30. See memory `architecture_entity_id_kind_tag.md`
//! for the rationale (16M ids/kind, 256 kind slots, tighter splits
//! are strictly worse).
//!
//! Wire format does not change — `sim.entity.<id>.*` carries the
//! tagged id verbatim, kind extraction is receiver-side.

const std = @import("std");

/// 256-slot kind enum. The `world` slot (0) is reserved for legacy /
/// untagged ids and the M3 hardcoded ship#1 fixtures — anything that
/// predates this tagging convention falls through as `world`.
pub const Kind = enum(u8) {
    world = 0x00,
    ship = 0x01,
    player = 0x02,
    projectile = 0x03,
    // 0x04+ reserved: corpses, deployables, mounts, structures,
    // npcs, sea_creatures, env_hazards. Add as needed.
    _,
};

pub const seq_mask: u32 = 0x00FF_FFFF;
pub const kind_shift: u5 = 24;

/// Compose a tagged id from a kind + seq. Asserts seq fits in 24 bits.
pub fn pack(kind: Kind, seq: u32) u32 {
    std.debug.assert(seq <= seq_mask);
    return (@as(u32, @intFromEnum(kind)) << kind_shift) | (seq & seq_mask);
}

/// Decode the kind byte from a tagged id. Untagged ids (top byte = 0)
/// return `Kind.world`.
pub fn kindOf(id: u32) Kind {
    return @enumFromInt(@as(u8, @intCast(id >> kind_shift)));
}

/// Extract the per-kind sequence from a tagged id.
pub fn seqOf(id: u32) u32 {
    return id & seq_mask;
}

const testing = std.testing;

test "entity_kind: pack/unpack roundtrip" {
    const id = pack(.ship, 42);
    try testing.expectEqual(@as(u32, 0x0100_002A), id);
    try testing.expectEqual(Kind.ship, kindOf(id));
    try testing.expectEqual(@as(u32, 42), seqOf(id));
}

test "entity_kind: player range" {
    const id = pack(.player, 1);
    try testing.expectEqual(@as(u32, 0x0200_0001), id);
    try testing.expectEqual(Kind.player, kindOf(id));
}

test "entity_kind: untagged id reads as world" {
    try testing.expectEqual(Kind.world, kindOf(1));
    try testing.expectEqual(Kind.world, kindOf(999_999));
}

test "entity_kind: max seq fits" {
    const id = pack(.projectile, seq_mask);
    try testing.expectEqual(Kind.projectile, kindOf(id));
    try testing.expectEqual(seq_mask, seqOf(id));
}
