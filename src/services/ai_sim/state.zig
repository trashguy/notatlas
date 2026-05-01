//! ai-sim cohort state. Pure data — no NATS, no Lua, no BT logic.
//!
//! Two tables:
//!   - `entities` — latest pose / velocity snapshot for every entity
//!     ai-sim has heard about on `sim.entity.*.state`. Bounded by the
//!     firehose; v0 keeps everyone (no spatial cull) since the
//!     perception API filter (docs/09 §7) lands in step 6.
//!   - `ais` — the ai-sim-driven ships. One BT instance per AI plus a
//!     latched `pending_input` slot per docs/09 §3 ("pending-input
//!     pattern"): action leaves write into the slot, the tick
//!     dispatcher publishes once at the end of the tick.

const std = @import("std");
const notatlas = @import("notatlas");
const wire = @import("wire");
const bt = notatlas.bt;

pub const WorldEntity = struct {
    /// Top-byte-tagged entity id (see `notatlas.entity_kind`).
    id: u32,
    x: f32,
    y: f32,
    z: f32,
    vx: f32,
    vy: f32,
    vz: f32,
    heading_rad: f32,
    generation: u16,
    /// Normalized hull HP in [0, 1] from StateMsg.hp. Default 1.0 so
    /// publishers that don't yet emit hp (free-agent capsules, env
    /// fixtures) read as healthy. perception.nearestEnemy filters
    /// `hp <= 0` so a sunk ship in this table doesn't become a target
    /// before its row ages out of the firehose-driven snapshot.
    hp: f32 = 1.0,
    /// Y-axis angular velocity, rad/s — the derivative term for the
    /// PD heading controller. Defaults to 0 for publishers that
    /// pre-date the field.
    angvel_y: f32 = 0,
    /// Tick on which we last received a state msg for this entity.
    /// Step 6's perception build can use this to age out stale rows.
    last_seen_tick: u64,
};

pub const AiShip = struct {
    /// Top-byte-tagged ship id ai-sim is driving. Must be a `Kind.ship`
    /// id that's already been spawned in ship-sim — ai-sim doesn't
    /// allocate bodies, it only publishes inputs (docs/09 §1).
    id: u32,
    /// One Tree instance per AI. Shape is shared (Archetype.nodes), but
    /// per-node `NodeState` (cooldown timestamps, repeat counters) is
    /// per-AI and lives inside `tree.state`.
    tree: bt.Tree,
    /// Latched input set by action leaves during the tick. Published
    /// at the end of the tick on `sim.entity.<id>.input` if non-null,
    /// then cleared. One InputMsg per AI per tick max.
    pending_input: ?wire.InputMsg = null,
};

pub const Cohort = struct {
    allocator: std.mem.Allocator,
    entities: std.AutoHashMapUnmanaged(u32, WorldEntity) = .{},
    ais: std.ArrayListUnmanaged(AiShip) = .{},

    pub fn init(allocator: std.mem.Allocator) Cohort {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Cohort) void {
        // Trees own a state slice allocated against the cohort's
        // allocator. Free them before the list itself.
        for (self.ais.items) |*ai| ai.tree.deinit(self.allocator);
        self.ais.deinit(self.allocator);
        self.entities.deinit(self.allocator);
    }

    pub fn observeEntity(
        self: *Cohort,
        id: u32,
        msg: wire.StateMsg,
        tick: u64,
    ) !void {
        try self.entities.put(self.allocator, id, .{
            .id = id,
            .x = msg.x,
            .y = msg.y,
            .z = msg.z,
            .vx = msg.vx,
            .vy = msg.vy,
            .vz = msg.vz,
            .heading_rad = msg.heading_rad,
            .generation = msg.generation,
            .hp = msg.hp,
            .angvel_y = msg.angvel_y,
            .last_seen_tick = tick,
        });
    }

    pub fn addAi(self: *Cohort, id: u32, tree: bt.Tree) !void {
        try self.ais.append(self.allocator, .{ .id = id, .tree = tree });
    }

    pub fn entityCount(self: *const Cohort) usize {
        return self.entities.count();
    }

    pub fn aiCount(self: *const Cohort) usize {
        return self.ais.items.len;
    }
};

const testing = std.testing;

test "cohort: observe writes new entity" {
    var c = Cohort.init(testing.allocator);
    defer c.deinit();

    try c.observeEntity(0x01000001, .{
        .generation = 1,
        .x = 10,
        .y = 0,
        .z = 5,
    }, 1);
    try testing.expectEqual(@as(usize, 1), c.entityCount());
    const e = c.entities.get(0x01000001).?;
    try testing.expectEqual(@as(f32, 10), e.x);
    try testing.expectEqual(@as(u64, 1), e.last_seen_tick);
}

test "cohort: observe overwrites existing entity" {
    var c = Cohort.init(testing.allocator);
    defer c.deinit();

    try c.observeEntity(0x01000001, .{ .generation = 1, .x = 0, .y = 0, .z = 0 }, 1);
    try c.observeEntity(0x01000001, .{ .generation = 1, .x = 100, .y = 0, .z = 0 }, 7);
    try testing.expectEqual(@as(usize, 1), c.entityCount());
    const e = c.entities.get(0x01000001).?;
    try testing.expectEqual(@as(f32, 100), e.x);
    try testing.expectEqual(@as(u64, 7), e.last_seen_tick);
}

test "cohort: observe captures hp" {
    var c = Cohort.init(testing.allocator);
    defer c.deinit();

    try c.observeEntity(0x01000003, .{
        .generation = 0,
        .x = 0,
        .y = 0,
        .z = 0,
        .hp = 0.42,
    }, 1);
    const e = c.entities.get(0x01000003).?;
    try testing.expectEqual(@as(f32, 0.42), e.hp);
}

test "cohort: observe captures angvel_y" {
    var c = Cohort.init(testing.allocator);
    defer c.deinit();

    try c.observeEntity(0x01000003, .{
        .generation = 0,
        .x = 0,
        .y = 0,
        .z = 0,
        .angvel_y = -0.7,
    }, 1);
    const e = c.entities.get(0x01000003).?;
    try testing.expectEqual(@as(f32, -0.7), e.angvel_y);
}

test "cohort: addAi tracks ais" {
    var c = Cohort.init(testing.allocator);
    defer c.deinit();

    // Single-action tree — leaf name is irrelevant for this state-level test.
    const nodes = try testing.allocator.alloc(bt.Node, 1);
    defer testing.allocator.free(nodes);
    nodes[0] = .{ .action = .{ .name = "noop" } };
    const tree = try bt.build(testing.allocator, nodes, 0);
    try c.addAi(0x01000003, tree);
    try testing.expectEqual(@as(usize, 1), c.aiCount());
    try testing.expectEqual(@as(u32, 0x01000003), c.ais.items[0].id);
}
