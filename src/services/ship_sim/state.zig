//! In-memory authoritative entity table for one ship-sim instance.
//!
//! Per docs/08 §2A ship-sim owns ALL 60 Hz rigid-body authority —
//! ships AND free-agent players. Sub-step 3 grew the table from a
//! placeholder into a real ECS-style registry: each entity carries
//! its Jolt body handle and a cached publish subject so the per-tick
//! loop is tight (no per-tick allocation).
//!
//! Sub-step 6 adds a parallel `passengers` table for aboard players
//! (see docs/08 §2A.1). Aboard players own no body of their own —
//! they're attached to a ship and travel as a ship-local pose. The
//! board / disembark transition mints / destroys the capsule body
//! and moves the player between the two tables.
//!
//! Pure data — no I/O. The NATS-side glue (main.zig) drives the
//! tick and publishes on each entity's `sim.entity.<id>.state`.

const std = @import("std");
const replication = @import("notatlas").replication;
const pose_codec = @import("notatlas").pose_codec;
const physics = @import("physics");

const EntityId = replication.EntityId;
const Pose = pose_codec.Pose;

/// Ship vs free-agent player. Ships own a Jolt rigid body + buoyancy
/// + sail/cannon component state. Free-agent players own a capsule-
/// proxy box controller + water sampling. Both publish to
/// `sim.entity.<id>.state` at the tier-1 visual rate (60 Hz).
pub const Kind = enum { ship, free_agent };

/// Latched input state — most recent (thrust, steer) values from
/// `sim.entity.<id>.input`. Re-applied every tick until a newer
/// input msg overwrites it; defaults to zero so a ship with no
/// connected client just bobs in place.
pub const LatchedInput = struct {
    thrust: f32 = 0,
    steer: f32 = 0,
    fire: bool = false,
};

/// One authoritative entity owned by this ship-sim. `body_id` is the
/// Jolt handle for the rigid body; `state_subj` is the pre-formatted
/// `sim.entity.<id>.state` subject the tick loop publishes to.
/// `input` carries the latched-most-recent thrust/steer the tick
/// loop applies before stepping. All resources owned by this table —
/// `deinit` destroys the body and frees the subject.
pub const Entity = struct {
    id: EntityId,
    kind: Kind,
    pose: Pose,
    body_id: physics.BodyId,
    state_subj: []const u8,
    input: LatchedInput = .{},
    /// Earliest world-time the entity may fire its cannon again.
    /// 0 = ready to fire on the first input. Updated to
    /// `world_time_s + cannon_cooldown_s` after each shot. Only
    /// ships actually fire at the moment; free-agent players carry
    /// the field for shape uniformity.
    next_fire_allowed_s: f64 = 0,

    pub fn deinit(
        self: *Entity,
        allocator: std.mem.Allocator,
        phys: *physics.System,
    ) void {
        phys.destroyBody(self.body_id);
        allocator.free(self.state_subj);
    }
};

/// One aboard player — no Jolt body, just a ship-local pose recorded
/// against the ship they're attached to. Per docs/08 §2A.1 aboard
/// players are part of the ship's "passenger list"; the v1 list is
/// flat per-player so a single AutoHashMap keyed by `player_id`
/// suffices. Walking the deck is future work — for now `local_pose`
/// is set once at board time and stays fixed.
pub const Passenger = struct {
    player_id: u32,
    ship_id: u32,
    /// Ship-local frame. World pose is reconstructed at disembark
    /// time as `ship_pose ⊗ local_pose` (docs/08 §2A.2 step 2).
    local_pose: Pose,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    /// Authoritative entities this ship-sim owns. Per docs/08 §7.4
    /// ship-sim is currently a single-process unit; sharding by
    /// entity-id range across multiple ship-sim instances is a Phase
    /// 2+ scaling story.
    entities: std.AutoHashMap(u32, Entity),
    /// Players currently aboard a ship — no body, ship-local pose
    /// only. A given `player_id` is in `entities` (free-agent) XOR
    /// `passengers` (aboard); never both.
    passengers: std.AutoHashMap(u32, Passenger),

    pub fn init(allocator: std.mem.Allocator) State {
        return .{
            .allocator = allocator,
            .entities = std.AutoHashMap(u32, Entity).init(allocator),
            .passengers = std.AutoHashMap(u32, Passenger).init(allocator),
        };
    }

    /// Free per-entity owned resources (Jolt body + cached subject)
    /// then the maps. `phys` must still be live; caller owns shutdown
    /// ordering. Passengers carry no owned resources beyond the slot.
    pub fn deinit(self: *State, phys: *physics.System) void {
        var it = self.entities.valueIterator();
        while (it.next()) |e| e.deinit(self.allocator, phys);
        self.entities.deinit();
        self.passengers.deinit();
    }

    pub fn entityCount(self: *const State) usize {
        return self.entities.count();
    }

    pub fn passengerCount(self: *const State) usize {
        return self.passengers.count();
    }
};

const testing = std.testing;

test "state: skeleton init/deinit" {
    physics.init();
    defer physics.shutdown();
    var phys = try physics.System.init(.{});
    defer phys.deinit();

    var s = State.init(testing.allocator);
    defer s.deinit(&phys);
    try testing.expectEqual(@as(usize, 0), s.entityCount());
    try testing.expectEqual(@as(usize, 0), s.passengerCount());
}

test "state: entity add + deinit frees body and subject" {
    physics.init();
    defer physics.shutdown();
    var phys = try physics.System.init(.{});
    defer phys.deinit();

    var s = State.init(testing.allocator);
    defer s.deinit(&phys);

    const body = try phys.createBox(.{
        .half_extents = .{ 1, 1, 1 },
        .position = .{ 0, 5, 0 },
        .motion = .dynamic,
    });
    const subj = try testing.allocator.dupe(u8, "sim.entity.42.state");
    try s.entities.put(42, .{
        .id = .{ .id = 42, .generation = 0 },
        .kind = .ship,
        .pose = .{ .pos = .{ 0, 5, 0 }, .rot = .{ 0, 0, 0, 1 }, .vel = .{ 0, 0, 0 } },
        .body_id = body,
        .state_subj = subj,
    });
    try testing.expectEqual(@as(usize, 1), s.entityCount());
}

test "state: passenger add" {
    physics.init();
    defer physics.shutdown();
    var phys = try physics.System.init(.{});
    defer phys.deinit();

    var s = State.init(testing.allocator);
    defer s.deinit(&phys);

    try s.passengers.put(0x0200_0001, .{
        .player_id = 0x0200_0001,
        .ship_id = 0x0100_0003,
        .local_pose = .{ .pos = .{ 0, 2, 0 }, .rot = .{ 0, 0, 0, 1 }, .vel = .{ 0, 0, 0 } },
    });
    try testing.expectEqual(@as(usize, 1), s.passengerCount());
}
