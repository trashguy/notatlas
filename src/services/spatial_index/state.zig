//! Pure entity → cell membership oracle for spatial-index, plus
//! per-entity world-pose tracking for radius queries.
//!
//! Per docs/02 §1.4 / docs/08 §7.1 spatial-index is the global
//! membership owner. cell-mgr trusts spatial-index's deltas and
//! never recomputes membership itself.
//!
//! v1 scope:
//!   - single-instance (no HA)
//!   - per-entity tracking is `(cell, world_pos)`. Pose is updated on
//!     every `observe()` so radius queries have current data.
//!   - cell membership is x/z-only (y is irrelevant for the grid),
//!     but the stored pose is full 3D so radius queries can compare
//!     vertical separation.
//!
//! No I/O — main.zig drives the NATS side; this module is pure data
//! so the cell-math + radius-query are unit-testable without a broker.

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

/// Per-entity record. Carries the cell membership for delta
/// generation and the full 3D world pose for radius queries.
pub const EntityRecord = struct {
    cell: CellId,
    pos: [3]f32,
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
    /// Entity → (cell, pos). Single map keyed by entity id; the cell
    /// part drives delta generation and the pos part drives radius
    /// queries.
    entities: std.AutoHashMap(u32, EntityRecord),

    pub fn init(allocator: std.mem.Allocator, cell_side_m: f32) State {
        std.debug.assert(cell_side_m > 0);
        return .{
            .allocator = allocator,
            .cell_side_m = cell_side_m,
            .entities = std.AutoHashMap(u32, EntityRecord).init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        self.entities.deinit();
    }

    pub fn entityCount(self: *const State) usize {
        return self.entities.count();
    }

    /// Record a new state observation for `ent_id` at world `pos`.
    /// Always updates the stored pose (so radius queries see the
    /// latest); the returned `Transition` describes whether the cell
    /// portion changed:
    ///   - null when the entity stays in the same cell as its last
    ///     observation (steady-state — most state msgs)
    ///   - first sighting: `old_cell = null`, caller emits enter on
    ///     `new_cell`
    ///   - cross-cell move: `old_cell = some`, caller emits exit on
    ///     old + enter on new
    pub fn observe(
        self: *State,
        ent_id: u32,
        pos: [3]f32,
    ) !?Transition {
        const new_cell = posToCell(pos[0], pos[2], self.cell_side_m);
        const gop = try self.entities.getOrPut(ent_id);
        if (gop.found_existing) {
            const old_cell = gop.value_ptr.cell;
            gop.value_ptr.pos = pos;
            if (old_cell.eql(new_cell)) return null;
            gop.value_ptr.cell = new_cell;
            return .{ .new_cell = new_cell, .old_cell = old_cell };
        }
        gop.value_ptr.* = .{ .cell = new_cell, .pos = pos };
        return .{ .new_cell = new_cell, .old_cell = null };
    }

    /// Forget an entity (e.g. on explicit despawn). Returns the cell
    /// the entity was last seen in (so the caller can emit a final
    /// exit delta), or null if the entity wasn't tracked.
    pub fn forget(self: *State, ent_id: u32) ?CellId {
        const kv = self.entities.fetchRemove(ent_id) orelse return null;
        return kv.value.cell;
    }
};

/// Radius-query result entry — id + world pos. Mirrors
/// `wire.QueryEntry` but lives here so this module stays
/// dependency-free.
pub const QueryEntry = struct {
    id: u32,
    pos: [3]f32,
};

pub const QueryResult = struct {
    /// Number of entries written to the caller's buffer. May be less
    /// than the buffer length.
    written: usize,
    /// True when more entities qualified than fit in the buffer. The
    /// returned entries are not ordered (first-N-encountered).
    truncated: bool,
};

/// Brute-force radius query: O(N) over `state.entities`. Writes up
/// to `out.len` matches into `out`; returns `(written, truncated)`.
/// 3D Euclidean distance — vertical separation matters.
///
/// v1 chooses brute-force because typical spatial-index tracks a few
/// hundred entities and queries are not yet on the per-tick hot
/// path. If query rate goes hot (M9 lag-comp will hit it once hit
/// detection arrives), a candidate-cell prune off the cell-side
/// grid is the natural next optimization.
pub fn queryRadius(
    state: *const State,
    center: [3]f32,
    radius_m: f32,
    out: []QueryEntry,
) QueryResult {
    const r2 = radius_m * radius_m;
    var written: usize = 0;
    var truncated = false;
    var it = state.entities.iterator();
    while (it.next()) |kv| {
        const p = kv.value_ptr.pos;
        const dx = p[0] - center[0];
        const dy = p[1] - center[1];
        const dz = p[2] - center[2];
        const d2 = dx * dx + dy * dy + dz * dz;
        if (d2 > r2) continue;
        if (written >= out.len) {
            truncated = true;
            continue;
        }
        out[written] = .{ .id = kv.key_ptr.*, .pos = p };
        written += 1;
    }
    return .{ .written = written, .truncated = truncated };
}

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
    const t = (try s.observe(1, .{ 50, 0, 50 })) orelse return error.ExpectedTransition;
    try testing.expectEqual(@as(?CellId, null), t.old_cell);
    try testing.expectEqual(CellId{ .x = 0, .z = 0 }, t.new_cell);
    try testing.expectEqual(@as(usize, 1), s.entityCount());
}

test "observe: same cell returns null but updates pos" {
    var s = State.init(testing.allocator, 200);
    defer s.deinit();
    _ = try s.observe(1, .{ 0, 0, 0 });
    try testing.expectEqual(@as(?Transition, null), try s.observe(1, .{ 100, 5, 100 }));
    const rec = s.entities.get(1).?;
    try testing.expectEqual(@as(f32, 100), rec.pos[0]);
    try testing.expectEqual(@as(f32, 5), rec.pos[1]);
    try testing.expectEqual(@as(f32, 100), rec.pos[2]);
}

test "observe: different cell returns transition" {
    var s = State.init(testing.allocator, 200);
    defer s.deinit();
    _ = try s.observe(1, .{ 50, 0, 50 });
    const t = (try s.observe(1, .{ 250, 0, 50 })) orelse return error.ExpectedTransition;
    try testing.expectEqual(@as(?CellId, CellId{ .x = 0, .z = 0 }), t.old_cell);
    try testing.expectEqual(CellId{ .x = 1, .z = 0 }, t.new_cell);
}

test "observe: multiple entities tracked independently" {
    var s = State.init(testing.allocator, 200);
    defer s.deinit();
    _ = try s.observe(1, .{ 0, 0, 0 });
    _ = try s.observe(2, .{ 300, 0, 0 });
    try testing.expectEqual(@as(usize, 2), s.entityCount());
    _ = try s.observe(2, .{ 600, 0, 0 });
    try testing.expectEqual(@as(?Transition, null), try s.observe(1, .{ 50, 0, 50 }));
}

test "forget: removes and returns last cell" {
    var s = State.init(testing.allocator, 200);
    defer s.deinit();
    _ = try s.observe(7, .{ 100, 0, 100 });
    try testing.expectEqual(@as(?CellId, CellId{ .x = 0, .z = 0 }), s.forget(7));
    try testing.expectEqual(@as(usize, 0), s.entityCount());
    try testing.expectEqual(@as(?CellId, null), s.forget(7));
}

test "queryRadius: empty state" {
    var s = State.init(testing.allocator, 200);
    defer s.deinit();
    var buf: [4]QueryEntry = undefined;
    const r = queryRadius(&s, .{ 0, 0, 0 }, 100, &buf);
    try testing.expectEqual(@as(usize, 0), r.written);
    try testing.expectEqual(false, r.truncated);
}

test "queryRadius: filters by 3D distance" {
    var s = State.init(testing.allocator, 200);
    defer s.deinit();
    _ = try s.observe(1, .{ 0, 0, 0 }); // at center
    _ = try s.observe(2, .{ 30, 0, 40 }); // 50 m away (3-4-5 triangle)
    _ = try s.observe(3, .{ 100, 0, 0 }); // 100 m away — outside r=80
    _ = try s.observe(4, .{ 0, 60, 0 }); // 60 m vertically — inside r=80

    var buf: [8]QueryEntry = undefined;
    const r = queryRadius(&s, .{ 0, 0, 0 }, 80, &buf);
    try testing.expectEqual(@as(usize, 3), r.written);
    try testing.expectEqual(false, r.truncated);

    // Verify ids 1, 2, 4 are present (any order — first-N-encountered).
    var ids: [3]u32 = .{ buf[0].id, buf[1].id, buf[2].id };
    std.mem.sort(u32, &ids, {}, std.sort.asc(u32));
    try testing.expectEqual(@as(u32, 1), ids[0]);
    try testing.expectEqual(@as(u32, 2), ids[1]);
    try testing.expectEqual(@as(u32, 4), ids[2]);
}

test "queryRadius: respects buffer cap and sets truncated" {
    var s = State.init(testing.allocator, 200);
    defer s.deinit();
    _ = try s.observe(1, .{ 0, 0, 0 });
    _ = try s.observe(2, .{ 1, 0, 0 });
    _ = try s.observe(3, .{ 2, 0, 0 });

    var buf: [2]QueryEntry = undefined;
    const r = queryRadius(&s, .{ 0, 0, 0 }, 100, &buf);
    try testing.expectEqual(@as(usize, 2), r.written);
    try testing.expectEqual(true, r.truncated);
}
