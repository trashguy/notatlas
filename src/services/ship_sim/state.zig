//! In-memory authoritative entity table for one ship-sim instance.
//!
//! Per docs/08 §2A ship-sim owns ALL 60 Hz rigid-body authority —
//! ships AND free-agent players. The skeleton (this commit) holds
//! the table shape but nothing actually populates it yet; subsequent
//! commits wire in:
//!   - Jolt-driven ship pose integration
//!   - Free-agent player capsule controller + water sampling
//!   - Board / disembark transitions per docs/08 §2A.2
//!   - Player input subscription on `sim.entity.<player_id>.input`
//!
//! Pure data — no I/O. The NATS-side glue (main.zig) drives the
//! tick and publishes on `sim.entity.<id>.state`.

const std = @import("std");
const replication = @import("notatlas").replication;
const pose_codec = @import("notatlas").pose_codec;

const EntityId = replication.EntityId;
const Pose = pose_codec.Pose;

/// Ship vs free-agent player. Ships own a Jolt rigid body + buoyancy
/// + sail/cannon component state. Free-agent players own a capsule
/// controller + water sampling. Both publish to
/// `sim.entity.<id>.state` at the tier-1 visual rate (60 Hz).
pub const Kind = enum { ship, free_agent };

/// One authoritative entity owned by this ship-sim. Skeleton holds
/// kind + pose; the body handle (Jolt) and per-kind component state
/// land in the next sub-step.
pub const Entity = struct {
    id: EntityId,
    kind: Kind,
    pose: Pose,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    /// Authoritative entities this ship-sim owns. Per docs/08 §7.4
    /// ship-sim is currently a single-process unit; sharding by
    /// entity-id range across multiple ship-sim instances is a Phase
    /// 2+ scaling story.
    entities: std.AutoHashMap(u32, Entity),

    pub fn init(allocator: std.mem.Allocator) State {
        return .{
            .allocator = allocator,
            .entities = std.AutoHashMap(u32, Entity).init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        self.entities.deinit();
    }

    pub fn entityCount(self: *const State) usize {
        return self.entities.count();
    }
};

const testing = std.testing;

test "state: skeleton init/deinit" {
    var s = State.init(testing.allocator);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 0), s.entityCount());
}
