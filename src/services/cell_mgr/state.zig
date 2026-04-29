//! In-memory entity + subscriber tables for one cell-mgr instance.
//!
//! Pure data structure — no I/O. The NATS-side glue (main.zig)
//! parses messages and calls applyDelta / applySubscribe; the
//! producer of the deltas trusts this module to apply them in order
//! without recomputing membership.

const std = @import("std");
const replication = @import("notatlas").replication;

const EntityId = replication.EntityId;
const Subscriber = replication.Subscriber;

const wire = @import("wire.zig");

pub const EntityState = struct {
    id: EntityId,
    pos: [3]f32,
    /// Ship the entity is aboard, if any. `null` for free agents and
    /// for ships themselves.
    aboard_ship: ?EntityId,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    /// id → state. Generation lives inside the value; a stale exit
    /// for an old generation is rejected against the current entry.
    entities: std.AutoHashMap(u32, EntityState),
    /// client_id → subscriber.
    subscribers: std.AutoHashMap(u64, Subscriber),

    pub fn init(allocator: std.mem.Allocator) State {
        return .{
            .allocator = allocator,
            .entities = std.AutoHashMap(u32, EntityState).init(allocator),
            .subscribers = std.AutoHashMap(u64, Subscriber).init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        self.entities.deinit();
        self.subscribers.deinit();
    }

    pub fn entityCount(self: *const State) usize {
        return self.entities.count();
    }

    pub fn subscriberCount(self: *const State) usize {
        return self.subscribers.count();
    }

    /// Apply a membership delta. Returns whether state actually changed
    /// (false on stale-generation exit, etc.) for logging.
    pub fn applyDelta(self: *State, msg: wire.DeltaMsg) !bool {
        const new_id: EntityId = .{ .id = msg.id, .generation = msg.generation };
        switch (msg.op) {
            .enter => {
                const aboard: ?EntityId = if (msg.ship_id != 0)
                    .{ .id = msg.ship_id, .generation = msg.ship_gen }
                else
                    null;
                // Idempotent: re-enter with same id+gen overwrites pose;
                // newer generation supersedes older in-cell entry (the
                // exit for the older generation may have been dropped).
                try self.entities.put(msg.id, .{
                    .id = new_id,
                    .pos = .{ msg.x, msg.y, msg.z },
                    .aboard_ship = aboard,
                });
                return true;
            },
            .exit => {
                const existing = self.entities.get(msg.id) orelse return false;
                if (!existing.id.eq(new_id)) return false; // stale generation
                _ = self.entities.remove(msg.id);
                return true;
            },
        }
    }

    /// Apply a subscriber registration / deregistration.
    pub fn applySubscribe(self: *State, msg: wire.SubscribeMsg) !bool {
        switch (msg.op) {
            .enter => {
                const aboard: ?EntityId = if (msg.ship_id != 0)
                    .{ .id = msg.ship_id, .generation = msg.ship_gen }
                else
                    null;
                try self.subscribers.put(msg.client_id, .{
                    .client_id = msg.client_id,
                    .pos_world = .{ msg.x, msg.y, msg.z },
                    .aboard_ship = aboard,
                });
                return true;
            },
            .exit => {
                if (!self.subscribers.contains(msg.client_id)) return false;
                _ = self.subscribers.remove(msg.client_id);
                return true;
            },
        }
    }
};

const testing = std.testing;

test "state: enter populates entity, exit removes" {
    var s = State.init(testing.allocator);
    defer s.deinit();
    _ = try s.applyDelta(.{ .op = .enter, .id = 1, .generation = 0, .x = 10, .y = 0, .z = 20 });
    try testing.expectEqual(@as(usize, 1), s.entityCount());
    _ = try s.applyDelta(.{ .op = .exit, .id = 1, .generation = 0, .x = 0, .y = 0, .z = 0 });
    try testing.expectEqual(@as(usize, 0), s.entityCount());
}

test "state: stale-generation exit is rejected" {
    var s = State.init(testing.allocator);
    defer s.deinit();
    _ = try s.applyDelta(.{ .op = .enter, .id = 1, .generation = 5, .x = 0, .y = 0, .z = 0 });
    const changed = try s.applyDelta(.{ .op = .exit, .id = 1, .generation = 4, .x = 0, .y = 0, .z = 0 });
    try testing.expect(!changed);
    try testing.expectEqual(@as(usize, 1), s.entityCount());
}

test "state: re-enter with newer generation overwrites" {
    var s = State.init(testing.allocator);
    defer s.deinit();
    _ = try s.applyDelta(.{ .op = .enter, .id = 1, .generation = 5, .x = 0, .y = 0, .z = 0 });
    _ = try s.applyDelta(.{ .op = .enter, .id = 1, .generation = 6, .x = 100, .y = 0, .z = 200 });
    try testing.expectEqual(@as(usize, 1), s.entityCount());
    const e = s.entities.get(1).?;
    try testing.expectEqual(@as(u16, 6), e.id.generation);
    try testing.expectEqual(@as(f32, 100), e.pos[0]);
}

test "state: subscribe + unsubscribe" {
    var s = State.init(testing.allocator);
    defer s.deinit();
    _ = try s.applySubscribe(.{ .op = .enter, .client_id = 42, .x = 0, .y = 0, .z = 0 });
    _ = try s.applySubscribe(.{ .op = .enter, .client_id = 99, .x = 0, .y = 0, .z = 0, .ship_id = 7, .ship_gen = 1 });
    try testing.expectEqual(@as(usize, 2), s.subscriberCount());
    const free = s.subscribers.get(42).?;
    const aboard = s.subscribers.get(99).?;
    try testing.expect(free.aboard_ship == null);
    try testing.expectEqual(@as(u32, 7), aboard.aboard_ship.?.id);
    _ = try s.applySubscribe(.{ .op = .exit, .client_id = 42, .x = 0, .y = 0, .z = 0 });
    try testing.expectEqual(@as(usize, 1), s.subscriberCount());
}
