//! Pure entity → cell membership oracle for spatial-index.
//!
//! Per docs/02 §1.4 / docs/08 §7.1 spatial-index is the global
//! membership owner. cell-mgr trusts spatial-index's deltas and
//! never recomputes membership itself.
//!
//! v1 scope (this commit): single-instance (no HA). Receives the
//! state firehose, classifies each entity into a cell by floor()
//! division, returns a transition descriptor when an entity's cell
//! changes (incl. first sighting → "enter, no exit").
//!
//! No I/O — main.zig drives the NATS side; this module is pure data
//! so the cell-math is unit-testable without a broker.

const std = @import("std");

/// Cell coordinates on the world grid. Grid is axis-aligned with
/// origin at (0, 0); cell (i, j) covers x ∈ [i × side, (i+1) × side),
/// z ∈ [j × side, (j+1) × side). y is irrelevant for cell membership
/// — naval entities live near sea level, vertical structure is per-
/// cell content.
pub const CellId = struct {
    x: i32,
    z: i32,

    pub fn eql(a: CellId, b: CellId) bool {
        return a.x == b.x and a.z == b.z;
    }
};

/// What spatial-index publishes to the NATS bus on each transition.
/// `old_cell == null` on first sighting → caller publishes only an
/// enter delta. Otherwise both an exit (on old) and enter (on new).
pub const Transition = struct {
    new_cell: CellId,
    old_cell: ?CellId,
};

/// `pos.x / cell_side_m` flooring to grid coords. Same convention
/// docs/06 §cell side discusses (4 km production default; smaller
/// values for Phase 2 dev to see transitions in a constrained
/// workspace).
pub fn posToCell(pos_x: f32, pos_z: f32, cell_side_m: f32) CellId {
    return .{
        .x = @intFromFloat(@floor(pos_x / cell_side_m)),
        .z = @intFromFloat(@floor(pos_z / cell_side_m)),
    };
}

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_side_m: f32,
    entity_cell: std.AutoHashMap(u32, CellId),

    pub fn init(allocator: std.mem.Allocator, cell_side_m: f32) State {
        std.debug.assert(cell_side_m > 0);
        return .{
            .allocator = allocator,
            .cell_side_m = cell_side_m,
            .entity_cell = std.AutoHashMap(u32, CellId).init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        self.entity_cell.deinit();
    }

    pub fn entityCount(self: *const State) usize {
        return self.entity_cell.count();
    }

    /// Record a new state observation for `ent_id` at world `pos`.
    /// Returns null when the entity stays in the same cell as its
    /// last observation (the steady-state case — most state msgs).
    /// Returns a `Transition` when:
    ///   - the entity is being observed for the first time
    ///     (`old_cell = null`, caller emits enter on `new_cell`)
    ///   - the entity moved to a different cell
    ///     (`old_cell = some`, caller emits exit on old + enter on new)
    pub fn observe(self: *State, ent_id: u32, pos_x: f32, pos_z: f32) !?Transition {
        const new_cell = posToCell(pos_x, pos_z, self.cell_side_m);
        const gop = try self.entity_cell.getOrPut(ent_id);
        if (gop.found_existing) {
            const old_cell = gop.value_ptr.*;
            if (old_cell.eql(new_cell)) return null;
            gop.value_ptr.* = new_cell;
            return .{ .new_cell = new_cell, .old_cell = old_cell };
        }
        gop.value_ptr.* = new_cell;
        return .{ .new_cell = new_cell, .old_cell = null };
    }

    /// Forget an entity (e.g. on explicit despawn). Returns the cell
    /// the entity was last seen in (so the caller can emit a final
    /// exit delta), or null if the entity wasn't tracked.
    pub fn forget(self: *State, ent_id: u32) ?CellId {
        const kv = self.entity_cell.fetchRemove(ent_id) orelse return null;
        return kv.value;
    }
};

const testing = std.testing;

test "posToCell: positive quadrant" {
    try testing.expectEqual(CellId{ .x = 0, .z = 0 }, posToCell(0, 0, 200));
    try testing.expectEqual(CellId{ .x = 0, .z = 0 }, posToCell(199.9, 0, 200));
    try testing.expectEqual(CellId{ .x = 1, .z = 0 }, posToCell(200, 0, 200));
    try testing.expectEqual(CellId{ .x = 1, .z = 1 }, posToCell(250, 350, 200));
}

test "posToCell: negative quadrant — floor goes more negative" {
    try testing.expectEqual(CellId{ .x = -1, .z = -1 }, posToCell(-0.1, -0.1, 200));
    try testing.expectEqual(CellId{ .x = -1, .z = 0 }, posToCell(-100, 50, 200));
    try testing.expectEqual(CellId{ .x = -2, .z = -1 }, posToCell(-201, -1, 200));
}

test "observe: first sighting returns enter with old=null" {
    var s = State.init(testing.allocator, 200);
    defer s.deinit();
    const t = (try s.observe(1, 50, 50)) orelse return error.ExpectedTransition;
    try testing.expectEqual(@as(?CellId, null), t.old_cell);
    try testing.expectEqual(CellId{ .x = 0, .z = 0 }, t.new_cell);
    try testing.expectEqual(@as(usize, 1), s.entityCount());
}

test "observe: same cell returns null" {
    var s = State.init(testing.allocator, 200);
    defer s.deinit();
    _ = try s.observe(1, 0, 0);
    try testing.expectEqual(@as(?Transition, null), try s.observe(1, 100, 100));
    try testing.expectEqual(@as(?Transition, null), try s.observe(1, 199, 199));
}

test "observe: different cell returns transition" {
    var s = State.init(testing.allocator, 200);
    defer s.deinit();
    _ = try s.observe(1, 50, 50);
    const t = (try s.observe(1, 250, 50)) orelse return error.ExpectedTransition;
    try testing.expectEqual(@as(?CellId, CellId{ .x = 0, .z = 0 }), t.old_cell);
    try testing.expectEqual(CellId{ .x = 1, .z = 0 }, t.new_cell);
}

test "observe: multiple entities tracked independently" {
    var s = State.init(testing.allocator, 200);
    defer s.deinit();
    _ = try s.observe(1, 0, 0);
    _ = try s.observe(2, 300, 0);
    try testing.expectEqual(@as(usize, 2), s.entityCount());
    // ent 1 doesn't transition when ent 2 moves
    _ = try s.observe(2, 600, 0);
    try testing.expectEqual(@as(?Transition, null), try s.observe(1, 50, 50));
}

test "forget: removes and returns last cell" {
    var s = State.init(testing.allocator, 200);
    defer s.deinit();
    _ = try s.observe(7, 100, 100);
    try testing.expectEqual(@as(?CellId, CellId{ .x = 0, .z = 0 }), s.forget(7));
    try testing.expectEqual(@as(usize, 0), s.entityCount());
    try testing.expectEqual(@as(?CellId, null), s.forget(7));
}
