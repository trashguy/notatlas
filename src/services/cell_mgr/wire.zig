//! cell-mgr ↔ {spatial-index, harness, gateway} wire format.
//!
//! M6.3 placeholder: JSON. The skeleton needs *something* on the wire
//! and JSON keeps the harness debuggable with `nats sub` / `nats pub`.
//! Binary encoding comes at M7 (pose codec + delta framing). Until
//! then this module is the only place wire types live; swapping JSON
//! for the M7 codec touches encode/decode and nothing else.

const std = @import("std");

/// Membership / subscription transition direction. `enter` = join the
/// cell or subscribe to it; `exit` = leave / unsubscribe.
pub const Op = enum {
    enter,
    exit,
};

/// `idx.spatial.cell.<x>_<y>.delta` payload — published by spatial-index
/// when an entity enters/exits a cell. M6.3 harness fakes these.
///
/// `ship_id` / `ship_gen` express boarding (entity is a passenger on
/// another ship). 0/0 = free agent. We carry boarding here rather than
/// on a separate subject so the cell-mgr's tier filter can compute the
/// boarded-tier gate without an extra round-trip.
pub const DeltaMsg = struct {
    op: Op,
    id: u32,
    generation: u16,
    x: f32,
    y: f32,
    z: f32,
    /// Unit quaternion (x, y, z, w). Defaulted to identity for
    /// harness scenarios that don't carry orientation.
    rot: [4]f32 = .{ 0, 0, 0, 1 },
    /// Linear velocity, m/s.
    vx: f32 = 0,
    vy: f32 = 0,
    vz: f32 = 0,
    ship_id: u32 = 0,
    ship_gen: u16 = 0,
};

/// `cm.cell.<x>_<y>.subscribe` / `.unsubscribe` payload.
///
/// In production these'd come from the gateway as a client tracks
/// which cells they care about. For M6.3 the harness publishes them
/// directly so we can exercise the per-tick fanout count.
pub const SubscribeMsg = struct {
    op: Op,
    client_id: u64,
    x: f32,
    y: f32,
    z: f32,
    ship_id: u32 = 0,
    ship_gen: u16 = 0,
};

pub fn encodeDelta(allocator: std.mem.Allocator, msg: DeltaMsg) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, msg, .{});
}

pub fn encodeSubscribe(allocator: std.mem.Allocator, msg: SubscribeMsg) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, msg, .{});
}

pub fn decodeDelta(allocator: std.mem.Allocator, payload: []const u8) !std.json.Parsed(DeltaMsg) {
    return std.json.parseFromSlice(DeltaMsg, allocator, payload, .{ .ignore_unknown_fields = true });
}

pub fn decodeSubscribe(allocator: std.mem.Allocator, payload: []const u8) !std.json.Parsed(SubscribeMsg) {
    return std.json.parseFromSlice(SubscribeMsg, allocator, payload, .{ .ignore_unknown_fields = true });
}

const testing = std.testing;

test "wire: delta roundtrip" {
    const orig: DeltaMsg = .{
        .op = .enter,
        .id = 42,
        .generation = 7,
        .x = 100,
        .y = 0,
        .z = -50,
        .ship_id = 0,
        .ship_gen = 0,
    };
    const buf = try encodeDelta(testing.allocator, orig);
    defer testing.allocator.free(buf);
    const parsed = try decodeDelta(testing.allocator, buf);
    defer parsed.deinit();
    try testing.expectEqual(orig, parsed.value);
}

test "wire: subscribe roundtrip with boarded ship" {
    const orig: SubscribeMsg = .{
        .op = .enter,
        .client_id = 0xDEADBEEF,
        .x = 1,
        .y = 2,
        .z = 3,
        .ship_id = 99,
        .ship_gen = 1,
    };
    const buf = try encodeSubscribe(testing.allocator, orig);
    defer testing.allocator.free(buf);
    const parsed = try decodeSubscribe(testing.allocator, buf);
    defer parsed.deinit();
    try testing.expectEqual(orig, parsed.value);
}
