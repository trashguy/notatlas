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
    /// Heading on the xz plane in radians (CCW from +x). Used by the
    /// cluster builder for mean-heading aggregation.
    heading_rad: f32 = 0,
    /// Silhouette class — 0 sloop, 1 schooner, 2 brigantine. JSON
    /// carries it as u8; state truncates to u3.
    silhouette: u8 = 0,
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

/// `sim.entity.<id>.state` payload — published by ship-sim (or the
/// M-stack harness) at high rate per entity. The id comes from the
/// subject path; the payload carries generation + the new pose. cell-
/// mgr's fast-lane callback (docs/08 §2.3 "callback-to-publish")
/// updates the entity table and forwards a single EntityRecord to
/// each visual+ subscriber without waiting for the slow-lane fanout
/// tick.
pub const StateMsg = struct {
    generation: u16,
    x: f32,
    y: f32,
    z: f32,
    rot: [4]f32 = .{ 0, 0, 0, 1 },
    vx: f32 = 0,
    vy: f32 = 0,
    vz: f32 = 0,
    heading_rad: f32 = 0,
};

pub fn encodeDelta(allocator: std.mem.Allocator, msg: DeltaMsg) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, msg, .{});
}

pub fn encodeState(allocator: std.mem.Allocator, msg: StateMsg) ![]u8 {
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

pub fn decodeState(allocator: std.mem.Allocator, payload: []const u8) !std.json.Parsed(StateMsg) {
    return std.json.parseFromSlice(StateMsg, allocator, payload, .{ .ignore_unknown_fields = true });
}

/// Extract the entity id encoded as the third token of a
/// `sim.entity.<id>.state` subject. Returns error if the subject
/// doesn't match that shape.
pub fn parseEntityIdFromSubject(subject: []const u8) !u32 {
    const prefix = "sim.entity.";
    const suffix = ".state";
    if (subject.len <= prefix.len + suffix.len) return error.BadSubject;
    if (!std.mem.startsWith(u8, subject, prefix)) return error.BadSubject;
    if (!std.mem.endsWith(u8, subject, suffix)) return error.BadSubject;
    const id_str = subject[prefix.len .. subject.len - suffix.len];
    if (id_str.len == 0) return error.BadSubject;
    return std.fmt.parseInt(u32, id_str, 10);
}

/// `sim.entity.<id>.input` payload — published by gateway from
/// length-prefixed TCP frames (gateway sub-step 3) and consumed by
/// ship-sim (sub-step 4) to drive the matching ship's Jolt body.
///
/// Sub-step 4 scope is thrust + steer for a ship; future sub-steps
/// add fire / aim / sail-trim / use-action. Keep this struct minimal
/// and additive — JSON ignores unknown fields, so a Phase 2 client
/// sending newer fields against an older ship-sim is graceful.
pub const InputMsg = struct {
    /// Forward thrust in [-1, 1]. Positive = forward (ship-local
    /// −Z), negative = reverse. Maps to a force along the ship's
    /// world-frame forward direction.
    thrust: f32 = 0,
    /// Steer in [-1, 1]. Positive = right turn (yaw clockwise from
    /// above), negative = left. Maps to a lateral force applied at
    /// the bow → torque around +y.
    steer: f32 = 0,
    /// Cannon trigger. Latched server-side: while true, the ship
    /// fires its starboard cannon every cooldown period. Client sets
    /// it to true on a fire input event and to false when releasing
    /// (one-shot fire = one InputMsg with `fire:true` followed by
    /// another with `fire:false` or omitted).
    fire: bool = false,
    /// Board verb. Edge-trigger: ship-sim consumes a single `true`
    /// per InputMsg and clears it. Routes to ship-sim's transition
    /// logic — picks the nearest ship within the board radius and
    /// flips the player from free-agent to passenger
    /// (docs/08 §2A.2).
    board: bool = false,
    /// Disembark verb. Edge-trigger. Inverse of `board`: ship-sim
    /// recreates the player's free-agent body at
    /// `ship_pose ⊗ local_pose` with inherited velocity and resumes
    /// `sim.entity.<player_id>.state` publishing.
    disembark: bool = false,
};

pub fn encodeInput(allocator: std.mem.Allocator, msg: InputMsg) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, msg, .{});
}

pub fn decodeInput(allocator: std.mem.Allocator, payload: []const u8) !std.json.Parsed(InputMsg) {
    return std.json.parseFromSlice(InputMsg, allocator, payload, .{ .ignore_unknown_fields = true });
}

/// Extract the entity id encoded in `sim.entity.<id>.input`. Same
/// shape as `parseEntityIdFromSubject` but for the `.input` suffix.
pub fn parseEntityIdFromInputSubject(subject: []const u8) !u32 {
    const prefix = "sim.entity.";
    const suffix = ".input";
    if (subject.len <= prefix.len + suffix.len) return error.BadSubject;
    if (!std.mem.startsWith(u8, subject, prefix)) return error.BadSubject;
    if (!std.mem.endsWith(u8, subject, suffix)) return error.BadSubject;
    const id_str = subject[prefix.len .. subject.len - suffix.len];
    if (id_str.len == 0) return error.BadSubject;
    return std.fmt.parseInt(u32, id_str, 10);
}

/// `sim.entity.<weapon_id>.fire` payload — broadcast at the moment
/// of firing per docs/03 §8. Both client and server reconstruct the
/// trajectory locally via `notatlas.projectile.predict`. Wire shape
/// is the JSON serialization of `projectile.FireEvent` minus the
/// weapon id (which lives in the subject).
pub const FireMsg = struct {
    /// Weapon's generation tag — id comes from the subject.
    generation: u16,
    /// Absolute world clock at fire time. f64 because the world
    /// clock is wipe-cycle long.
    fire_time_s: f64,
    /// Muzzle pose at fire time. JSON-friendly flat layout.
    mx: f32,
    my: f32,
    mz: f32,
    rx: f32 = 0,
    ry: f32 = 0,
    rz: f32 = 0,
    rw: f32 = 1,
    /// 0..1 charge fraction.
    charge: f32 = 1.0,
    /// Ammo params inline. Phase 2 may switch to an ammo-id ref +
    /// registry lookup, but for the broadcast model the per-event
    /// inline payload matches the receiver-doesn't-need-a-registry
    /// property of fire events.
    ammo_muzzle_velocity_mps: f32,
    ammo_mass_kg: f32,
    ammo_splash_radius_m: f32,
    ammo_splash_damage_hp: f32,
};

pub fn encodeFire(allocator: std.mem.Allocator, msg: FireMsg) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, msg, .{});
}

pub fn decodeFire(allocator: std.mem.Allocator, payload: []const u8) !std.json.Parsed(FireMsg) {
    return std.json.parseFromSlice(FireMsg, allocator, payload, .{ .ignore_unknown_fields = true });
}

/// Extract the weapon id from a `sim.entity.<id>.fire` subject. Same
/// shape as `parseEntityIdFromSubject` but for the `.fire` suffix.
pub fn parseWeaponIdFromFireSubject(subject: []const u8) !u32 {
    const prefix = "sim.entity.";
    const suffix = ".fire";
    if (subject.len <= prefix.len + suffix.len) return error.BadSubject;
    if (!std.mem.startsWith(u8, subject, prefix)) return error.BadSubject;
    if (!std.mem.endsWith(u8, subject, suffix)) return error.BadSubject;
    const id_str = subject[prefix.len .. subject.len - suffix.len];
    if (id_str.len == 0) return error.BadSubject;
    return std.fmt.parseInt(u32, id_str, 10);
}

/// `idx.spatial.attach.<player_id>` payload — published by ship-sim
/// on board / disembark transitions per docs/08 §2A.2 step 5. The
/// spatial-index subscribes and emits the synthetic enter/exit deltas
/// (cell-mgr unsubscribes on board, resubscribes on disembark).
///
/// `attached_ship_id == 0` means the player just transitioned to
/// free-agent (disembark side); a non-zero value means the player is
/// now aboard that ship (board side). u32 is sufficient — the ship
/// id is the top-byte-tagged entity id from the `ship` kind range.
///
/// The control subject is separate from the player's state subject
/// because spatial-index needs to act *before* the next state
/// publish — on board the player's state subject stops publishing,
/// so a heuristic "detect a gap" approach would race the cell-mgr's
/// tier filter for several ticks.
pub const AttachMsg = struct {
    player_id: u32,
    attached_ship_id: u32 = 0,
    /// Last-known world pose of the player at the moment of
    /// transition. On board this is the world pose at the instant the
    /// capsule body is destroyed; on disembark this is the world
    /// pose ship-sim hands the new capsule. spatial-index uses this
    /// to populate the synthetic exit/enter delta with a real
    /// position rather than a stale one.
    x: f32,
    y: f32,
    z: f32,
};

pub fn encodeAttach(allocator: std.mem.Allocator, msg: AttachMsg) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, msg, .{});
}

pub fn decodeAttach(allocator: std.mem.Allocator, payload: []const u8) !std.json.Parsed(AttachMsg) {
    return std.json.parseFromSlice(AttachMsg, allocator, payload, .{ .ignore_unknown_fields = true });
}

/// Extract the player id from `idx.spatial.attach.<id>`.
pub fn parsePlayerIdFromAttachSubject(subject: []const u8) !u32 {
    const prefix = "idx.spatial.attach.";
    if (subject.len <= prefix.len) return error.BadSubject;
    if (!std.mem.startsWith(u8, subject, prefix)) return error.BadSubject;
    const id_str = subject[prefix.len..];
    if (id_str.len == 0) return error.BadSubject;
    return std.fmt.parseInt(u32, id_str, 10);
}

/// `idx.spatial.query.radius` request payload — a NATS request/reply
/// roundtrip that returns every entity within `radius_m` of the
/// world-frame point `(x, y, z)`. spatial-index publishes the
/// reply on the request's `reply_to` inbox.
///
/// `max_results` caps the response payload; if more entities qualify,
/// the result's `truncated` flag is set and the caller can decide
/// whether to retry with a tighter filter or just live with the
/// partial answer. Default 256 is comfortable for the
/// 200-entity-per-cell soft target.
///
/// Kind filtering is intentionally absent in v1 — the entity id's
/// top byte names the kind already (memory
/// `architecture_entity_id_kind_tag.md`), so callers can filter
/// client-side off the returned `id` field with one shift. Adding
/// server-side filtering is a payload-shrink optimization for
/// future hot paths.
///
/// Distance compares 3D (Euclidean) so vertical separation matters —
/// a player on a 30 m mast is not "within 5 m" of someone at sea
/// level. Pure horizontal use cases can pass a generous radius and
/// post-filter on `y`.
pub const RadiusQueryMsg = struct {
    x: f32,
    y: f32,
    z: f32,
    radius_m: f32,
    max_results: u32 = 256,
};

/// One entry in the radius-query reply. `id` carries the top-byte
/// kind tag verbatim — callers route by `id >> 24`.
pub const QueryEntry = struct {
    id: u32,
    x: f32,
    y: f32,
    z: f32,
};

/// Reply payload for `idx.spatial.query.radius`. `truncated == true`
/// means the result was capped at the request's `max_results`;
/// `entries.len` reports the actual count returned.
pub const RadiusResultMsg = struct {
    truncated: bool,
    entries: []const QueryEntry,
};

pub fn encodeRadiusQuery(allocator: std.mem.Allocator, msg: RadiusQueryMsg) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, msg, .{});
}

pub fn decodeRadiusQuery(allocator: std.mem.Allocator, payload: []const u8) !std.json.Parsed(RadiusQueryMsg) {
    return std.json.parseFromSlice(RadiusQueryMsg, allocator, payload, .{ .ignore_unknown_fields = true });
}

pub fn encodeRadiusResult(allocator: std.mem.Allocator, msg: RadiusResultMsg) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, msg, .{});
}

pub fn decodeRadiusResult(allocator: std.mem.Allocator, payload: []const u8) !std.json.Parsed(RadiusResultMsg) {
    return std.json.parseFromSlice(RadiusResultMsg, allocator, payload, .{ .ignore_unknown_fields = true });
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

test "wire: state roundtrip" {
    const orig: StateMsg = .{
        .generation = 7,
        .x = 100,
        .y = 0,
        .z = -50,
        .rot = .{ 0, 0.7071, 0, 0.7071 },
        .vx = 1,
        .vy = 0,
        .vz = -2,
        .heading_rad = 1.5,
    };
    const buf = try encodeState(testing.allocator, orig);
    defer testing.allocator.free(buf);
    const parsed = try decodeState(testing.allocator, buf);
    defer parsed.deinit();
    try testing.expectEqual(orig.generation, parsed.value.generation);
    try testing.expectEqual(orig.x, parsed.value.x);
    try testing.expectEqual(orig.heading_rad, parsed.value.heading_rad);
}

test "wire: parseEntityIdFromSubject" {
    try testing.expectEqual(@as(u32, 42), try parseEntityIdFromSubject("sim.entity.42.state"));
    try testing.expectEqual(@as(u32, 1), try parseEntityIdFromSubject("sim.entity.1.state"));
    try testing.expectError(error.BadSubject, parseEntityIdFromSubject("sim.entity.state"));
    try testing.expectError(error.BadSubject, parseEntityIdFromSubject("sim.entity..state"));
    try testing.expectError(error.BadSubject, parseEntityIdFromSubject("idx.spatial.cell.0_0.delta"));
}

test "wire: fire roundtrip" {
    const orig: FireMsg = .{
        .generation = 7,
        .fire_time_s = 12345.678,
        .mx = 100,
        .my = 5,
        .mz = -50,
        .rx = 0,
        .ry = 0.7071,
        .rz = 0,
        .rw = 0.7071,
        .charge = 0.85,
        .ammo_muzzle_velocity_mps = 250,
        .ammo_mass_kg = 6,
        .ammo_splash_radius_m = 3,
        .ammo_splash_damage_hp = 50,
    };
    const buf = try encodeFire(testing.allocator, orig);
    defer testing.allocator.free(buf);
    const parsed = try decodeFire(testing.allocator, buf);
    defer parsed.deinit();
    try testing.expectEqual(orig.generation, parsed.value.generation);
    try testing.expectEqual(orig.fire_time_s, parsed.value.fire_time_s);
    try testing.expectEqual(orig.charge, parsed.value.charge);
    try testing.expectEqual(orig.ammo_muzzle_velocity_mps, parsed.value.ammo_muzzle_velocity_mps);
}

test "wire: parseWeaponIdFromFireSubject" {
    try testing.expectEqual(@as(u32, 42), try parseWeaponIdFromFireSubject("sim.entity.42.fire"));
    try testing.expectError(error.BadSubject, parseWeaponIdFromFireSubject("sim.entity.42.state"));
    try testing.expectError(error.BadSubject, parseWeaponIdFromFireSubject("sim.entity..fire"));
}

test "wire: input roundtrip" {
    const orig: InputMsg = .{ .thrust = 0.85, .steer = -0.30 };
    const buf = try encodeInput(testing.allocator, orig);
    defer testing.allocator.free(buf);
    const parsed = try decodeInput(testing.allocator, buf);
    defer parsed.deinit();
    try testing.expectEqual(orig.thrust, parsed.value.thrust);
    try testing.expectEqual(orig.steer, parsed.value.steer);
}

test "wire: parseEntityIdFromInputSubject" {
    try testing.expectEqual(@as(u32, 42), try parseEntityIdFromInputSubject("sim.entity.42.input"));
    try testing.expectEqual(@as(u32, 1), try parseEntityIdFromInputSubject("sim.entity.1.input"));
    try testing.expectError(error.BadSubject, parseEntityIdFromInputSubject("sim.entity.42.state"));
    try testing.expectError(error.BadSubject, parseEntityIdFromInputSubject("sim.entity..input"));
}

test "wire: input ignores unknown fields (forward-compat)" {
    // A future client sends fire + aim alongside thrust/steer; older
    // ship-sim should still parse the thrust/steer fields cleanly.
    const future = "{\"thrust\":0.5,\"steer\":0,\"fire\":true,\"aim_pitch\":0.2}";
    const parsed = try decodeInput(testing.allocator, future);
    defer parsed.deinit();
    try testing.expectEqual(@as(f32, 0.5), parsed.value.thrust);
}

test "wire: input board/disembark verbs round-trip" {
    const orig: InputMsg = .{ .board = true };
    const buf = try encodeInput(testing.allocator, orig);
    defer testing.allocator.free(buf);
    const parsed = try decodeInput(testing.allocator, buf);
    defer parsed.deinit();
    try testing.expectEqual(true, parsed.value.board);
    try testing.expectEqual(false, parsed.value.disembark);
}

test "wire: attach round-trip" {
    const orig: AttachMsg = .{
        .player_id = 0x0200_0001,
        .attached_ship_id = 0x0100_0003,
        .x = 50,
        .y = 4,
        .z = -10,
    };
    const buf = try encodeAttach(testing.allocator, orig);
    defer testing.allocator.free(buf);
    const parsed = try decodeAttach(testing.allocator, buf);
    defer parsed.deinit();
    try testing.expectEqual(orig, parsed.value);
}

test "wire: parsePlayerIdFromAttachSubject" {
    try testing.expectEqual(@as(u32, 33554433), try parsePlayerIdFromAttachSubject("idx.spatial.attach.33554433"));
    try testing.expectError(error.BadSubject, parsePlayerIdFromAttachSubject("idx.spatial.attach."));
    try testing.expectError(error.BadSubject, parsePlayerIdFromAttachSubject("sim.entity.1.input"));
}

test "wire: radius query roundtrip" {
    const orig: RadiusQueryMsg = .{ .x = 100, .y = 5, .z = -50, .radius_m = 250, .max_results = 64 };
    const buf = try encodeRadiusQuery(testing.allocator, orig);
    defer testing.allocator.free(buf);
    const parsed = try decodeRadiusQuery(testing.allocator, buf);
    defer parsed.deinit();
    try testing.expectEqual(orig, parsed.value);
}

test "wire: radius result roundtrip" {
    const entries = [_]QueryEntry{
        .{ .id = 0x0100_0001, .x = 10, .y = 0, .z = 0 },
        .{ .id = 0x0200_0001, .x = 0, .y = 0, .z = 5 },
    };
    const orig: RadiusResultMsg = .{ .truncated = false, .entries = &entries };
    const buf = try encodeRadiusResult(testing.allocator, orig);
    defer testing.allocator.free(buf);
    const parsed = try decodeRadiusResult(testing.allocator, buf);
    defer parsed.deinit();
    try testing.expectEqual(false, parsed.value.truncated);
    try testing.expectEqual(@as(usize, 2), parsed.value.entries.len);
    try testing.expectEqual(@as(u32, 0x0100_0001), parsed.value.entries[0].id);
    try testing.expectEqual(@as(u32, 0x0200_0001), parsed.value.entries[1].id);
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
