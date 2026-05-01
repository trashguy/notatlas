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
    /// Absolute current hull HP. Spawned at `hp_max`. Cannonball
    /// impacts deduct via `applyDamage`. At 0 the entity is sunk
    /// and removed from the sim by the tick loop (see main.zig
    /// destroySunk).
    hp_current: f32 = 1.0,
    /// Absolute hull HP at full health. v0 is hardcoded per kind
    /// at spawn — Phase 2 lifts this into `data/ships/<hull>.yaml`
    /// alongside mass / extents.
    hp_max: f32 = 1.0,

    pub fn deinit(
        self: *Entity,
        allocator: std.mem.Allocator,
        phys: *physics.System,
    ) void {
        phys.destroyBody(self.body_id);
        allocator.free(self.state_subj);
    }

    /// Normalized HP in [0, 1]. Published in StateMsg.hp.
    pub fn hpFraction(self: *const Entity) f32 {
        if (self.hp_max <= 0) return 0;
        const f = self.hp_current / self.hp_max;
        if (f < 0) return 0;
        if (f > 1) return 1;
        return f;
    }

    /// Deduct `damage` HP, clamped to >= 0. Returns the post-deduct
    /// normalized HP fraction.
    pub fn applyDamage(self: *Entity, damage: f32) f32 {
        self.hp_current -= damage;
        if (self.hp_current < 0) self.hp_current = 0;
        return self.hpFraction();
    }

    pub fn isSunk(self: *const Entity) bool {
        return self.hp_current <= 0;
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

/// One in-flight cannonball, tracked server-side for impact
/// resolution. ship-sim's tick loop walks this list each step,
/// re-evaluates the deterministic trajectory at the current world
/// clock, and AABB-tests against every ship. The same FireMsg is
/// also published to clients for visual rendering — both server
/// and client read the same closed-form math (M8 deterministic
/// projectile gate), so client and server agree on the trajectory
/// even with no replication.
///
/// Lifetime is capped by the tick loop (see `projectile_lifetime_s`
/// in main.zig) so a cannonball that misses everything is reaped
/// rather than tracked forever. Splash damage is single-target in
/// v0 — the first ship the trajectory enters consumes the round;
/// area-of-effect splash falloff onto secondary ships lands when
/// damage tuning gets a polish pass.
pub const ProjectileTrack = struct {
    /// Top-byte-tagged id of the firing ship (the cannon's owner).
    /// Echoed into DamageMsg.source_id and used to suppress
    /// friendly-fire (a ship's own cannonball can't hit it on the
    /// fire-tick before it's cleared the muzzle).
    weapon_id: u32,
    fire_time_s: f64,
    muzzle_pos: [3]f32,
    muzzle_rot: [4]f32,
    charge: f32,
    ammo_muzzle_velocity_mps: f32,
    ammo_mass_kg: f32,
    ammo_splash_radius_m: f32,
    ammo_splash_damage_hp: f32,
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
    /// In-flight cannonballs awaiting impact resolution. Mutated
    /// each tick by `tickProjectiles` in main.zig; entries are
    /// removed on hit or when their lifetime expires.
    projectiles: std.ArrayListUnmanaged(ProjectileTrack) = .{},

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
        self.projectiles.deinit(self.allocator);
    }

    pub fn entityCount(self: *const State) usize {
        return self.entities.count();
    }

    pub fn passengerCount(self: *const State) usize {
        return self.passengers.count();
    }

    pub fn projectileCount(self: *const State) usize {
        return self.projectiles.items.len;
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

test "state: applyDamage clamps to zero and reports normalized hp" {
    physics.init();
    defer physics.shutdown();
    var phys = try physics.System.init(.{});
    defer phys.deinit();

    const body = try phys.createBox(.{
        .half_extents = .{ 1, 1, 1 },
        .position = .{ 0, 5, 0 },
        .motion = .dynamic,
    });
    var e: Entity = .{
        .id = .{ .id = 0x01000001, .generation = 0 },
        .kind = .ship,
        .pose = .{ .pos = .{ 0, 0, 0 }, .rot = .{ 0, 0, 0, 1 }, .vel = .{ 0, 0, 0 } },
        .body_id = body,
        .state_subj = "",
        .hp_current = 300,
        .hp_max = 300,
    };
    defer phys.destroyBody(e.body_id);

    try testing.expectEqual(@as(f32, 1.0), e.hpFraction());
    try testing.expectEqual(@as(f32, 0.5), e.applyDamage(150));
    try testing.expect(!e.isSunk());
    // Overkill clamps to zero, doesn't go negative.
    _ = e.applyDamage(1000);
    try testing.expectEqual(@as(f32, 0), e.hpFraction());
    try testing.expect(e.isSunk());
}

test "state: projectile track add and clear" {
    physics.init();
    defer physics.shutdown();
    var phys = try physics.System.init(.{});
    defer phys.deinit();

    var s = State.init(testing.allocator);
    defer s.deinit(&phys);
    try testing.expectEqual(@as(usize, 0), s.projectileCount());

    try s.projectiles.append(s.allocator, .{
        .weapon_id = 0x01000001,
        .fire_time_s = 1.234,
        .muzzle_pos = .{ 0, 1, 0 },
        .muzzle_rot = .{ 0, 0, 0, 1 },
        .charge = 1.0,
        .ammo_muzzle_velocity_mps = 250,
        .ammo_mass_kg = 6,
        .ammo_splash_radius_m = 3,
        .ammo_splash_damage_hp = 50,
    });
    try testing.expectEqual(@as(usize, 1), s.projectileCount());
    s.projectiles.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 0), s.projectileCount());
}
