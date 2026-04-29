//! Tier-replication filter + fleet-aggregate cluster builder.
//!
//! Pure module — no I/O, no globals. Two consumers in the service mesh
//! (docs/08-phase1-architecture.md §3.3): cell-mgr's per-subscriber
//! fanout pass at 30 Hz, and ship-sim's direct publish for tier-2/3
//! events. The cluster builder lives at spatial-index in production
//! per docs/08 §3.2a, but the primitive is here so cell-mgr unit tests
//! can exercise the count-correctness invariant without standing up
//! the service.
//!
//! M6.1 scope: pure filter + cluster + per-subscriber view.
//! M6.2 scope adds: `replicated(T, tier)` field wrapper with change
//! detection (dirty bit + last-published snapshot), and a comptime
//! `dirtyMask` for ECS-side iteration over a struct of replicated
//! fields. Still pure — no I/O, no service code.

const std = @import("std");

// ---- types ----

pub const Tier = enum(u8) {
    /// Never gated by distance. Existence-level fields the subscriber
    /// always sees for an entity in their cell awareness (name,
    /// faction). Lowest enum value so `field_tier <= subscriber_tier`
    /// includes it for every closer tier.
    always = 0,
    /// 500–2000 m horizontal: clustered into a per-cell aggregate
    /// rather than streamed individually. The cluster pathway replaces
    /// per-entity replication for entities at this tier; see
    /// `aggregateForSubscriber`.
    fleet_aggregate = 1,
    /// ≤ 500 m: silhouette-resolution per-entity stream at 60 Hz.
    visual = 2,
    /// ≤ 150 m: hit-resolution data (plank HP, sail rig state).
    close_combat = 3,
    /// Same ship as the subscriber. Below-deck / inventory state.
    boarded = 4,
};

pub const ClientId = u64;

/// Generation-tagged entity identity. Required from day one
/// (docs/08-phase1-architecture.md §5.4) so a stale subscriber that
/// was attached to a now-recycled `id` cannot accidentally reattach
/// to the new owner.
pub const EntityId = struct {
    id: u32,
    generation: u16,

    pub fn eq(a: EntityId, b: EntityId) bool {
        return a.id == b.id and a.generation == b.generation;
    }
};

pub const Subscriber = struct {
    client_id: ClientId,
    pos_world: [3]f32,
    /// The ship the subscriber is aboard, if any. Gates the boarded
    /// tier — only entities on the same ship qualify.
    aboard_ship: ?EntityId,
};

pub const TierThresholds = struct {
    fleet_aggregate_range_m: f32 = 2000.0,
    visual_range_m: f32 = 500.0,
    close_combat_range_m: f32 = 150.0,

    pub const default: TierThresholds = .{};
};

// ---- filter ----

/// Which tier should the subscriber receive for this entity?
///
/// Distance is computed in the xz plane. Naval combat doesn't need the
/// y component — ships and free-agent swimmers all sit within a few
/// meters of y=0 and the wave displacement is dominated by xz extent.
/// Skipping y also lets the hot loop avoid one f32 multiply per call.
pub fn effectiveTier(
    subscriber: Subscriber,
    entity_pos: [3]f32,
    entity_ship: ?EntityId,
    thresholds: TierThresholds,
) Tier {
    if (subscriber.aboard_ship) |sub_ship| {
        if (entity_ship) |ent_ship| {
            if (sub_ship.eq(ent_ship)) return .boarded;
        }
    }

    const dx = entity_pos[0] - subscriber.pos_world[0];
    const dz = entity_pos[2] - subscriber.pos_world[2];
    const d2 = dx * dx + dz * dz;

    const cc = thresholds.close_combat_range_m;
    const vis = thresholds.visual_range_m;
    const fa = thresholds.fleet_aggregate_range_m;

    if (d2 <= cc * cc) return .close_combat;
    if (d2 <= vis * vis) return .visual;
    if (d2 <= fa * fa) return .fleet_aggregate;
    return .always;
}

/// Should a field declared at `field_tier` go on the subscriber's
/// individual stream when their effective tier for this entity is
/// `subscriber_tier`?
///
/// Pure ordering. Note: when `subscriber_tier == .fleet_aggregate` the
/// caller routes the entity through the cluster pathway instead — this
/// function does not gate that decision; it answers only the
/// "does this field belong on a per-entity stream" question.
pub fn shouldReplicate(field_tier: Tier, subscriber_tier: Tier) bool {
    return @intFromEnum(field_tier) <= @intFromEnum(subscriber_tier);
}

// ---- fleet-aggregate cluster builder ----

pub const ClusterEntity = struct {
    id: EntityId,
    pos: [3]f32,
    /// Heading on the xz plane in radians; CCW from +x.
    heading_rad: f32,
    /// Silhouette class — 0 sloop, 1 schooner, 2 brigantine. Fits in
    /// `silhouette_mask`'s 8-bit width.
    silhouette: u3,
};

/// Wire form, ~16-24 B per docs/08 §3.2a.
pub const FleetAggregate = struct {
    centroid: [2]f32,
    radius_m: f32,
    /// Saturating cap; clusters with > 255 members report 255. The
    /// cluster builder splits cells into sub-cells, so a single
    /// aggregate exceeding 255 entities would only happen if a sub-
    /// cell's bucket exceeds it — well past the 200/cell design cap.
    count: u8,
    /// Mean heading in q14.2 — degrees × 4, range [0, 1440).
    heading_deg: u16,
    /// Bit i set iff the cluster contains at least one member with
    /// `silhouette == i`.
    silhouette_mask: u8,
};

/// Internal form: wire `aggregate` plus the contained entity-id list.
/// cell-mgr keeps this around so it can derive a per-subscriber view
/// that excludes entities the subscriber receives individually
/// (`aggregateForSubscriber`). spatial-index publishes only the
/// `aggregate` field on the wire.
pub const Cluster = struct {
    aggregate: FleetAggregate,
    members: []const EntityId,

    pub fn deinit(self: Cluster, allocator: std.mem.Allocator) void {
        allocator.free(self.members);
    }
};

/// Bucket entities into a uniform sub-cell grid aligned to
/// `cell_origin`, then derive one `Cluster` per non-empty bucket.
/// O(N) — single bucket pass, single per-bucket aggregate pass.
///
/// `cell_origin` is the bottom-left (min-x, min-z) corner of the cell.
/// `sub_cell_size_m` controls the bucket grid resolution; smaller
/// values produce more, tighter clusters at the cost of more aggregate
/// messages on the wire. 250 m sub-cells inside a 1000 m cell yields a
/// 4×4 grid — coarse enough for the 5 Hz rate to remain cheap, fine
/// enough that a cluster's `radius_m` doesn't span the whole cell.
///
/// Caller owns the returned slice and each cluster's `members`; free
/// via `freeClusters`.
pub fn buildClusters(
    allocator: std.mem.Allocator,
    entities: []const ClusterEntity,
    sub_cell_size_m: f32,
    cell_origin: [2]f32,
    cell_size_m: f32,
) ![]Cluster {
    if (entities.len == 0) return &.{};

    std.debug.assert(sub_cell_size_m > 0);
    std.debug.assert(cell_size_m > 0);

    const grid_n: usize = @max(1, @as(usize, @intFromFloat(@ceil(cell_size_m / sub_cell_size_m))));
    const bucket_count = grid_n * grid_n;

    const buckets = try allocator.alloc(std.ArrayList(u32), bucket_count);
    defer {
        for (buckets) |*b| b.deinit(allocator);
        allocator.free(buckets);
    }
    for (buckets) |*b| b.* = .empty;

    const grid_max: isize = @as(isize, @intCast(grid_n)) - 1;
    for (entities, 0..) |e, i| {
        const lx = e.pos[0] - cell_origin[0];
        const lz = e.pos[2] - cell_origin[1];
        const sx_raw: isize = @intFromFloat(@floor(lx / sub_cell_size_m));
        const sz_raw: isize = @intFromFloat(@floor(lz / sub_cell_size_m));
        const sx = std.math.clamp(sx_raw, 0, grid_max);
        const sz = std.math.clamp(sz_raw, 0, grid_max);
        const idx: usize = @intCast(sz * @as(isize, @intCast(grid_n)) + sx);
        try buckets[idx].append(allocator, @intCast(i));
    }

    var clusters: std.ArrayList(Cluster) = .empty;
    errdefer {
        for (clusters.items) |c| c.deinit(allocator);
        clusters.deinit(allocator);
    }

    for (buckets) |b| {
        if (b.items.len == 0) continue;
        const cluster = try buildOneCluster(allocator, entities, b.items);
        try clusters.append(allocator, cluster);
    }

    return clusters.toOwnedSlice(allocator);
}

pub fn freeClusters(allocator: std.mem.Allocator, clusters: []Cluster) void {
    for (clusters) |c| c.deinit(allocator);
    allocator.free(clusters);
}

fn buildOneCluster(
    allocator: std.mem.Allocator,
    entities: []const ClusterEntity,
    indices: []const u32,
) !Cluster {
    const members = try allocator.alloc(EntityId, indices.len);
    errdefer allocator.free(members);

    var sum_x: f64 = 0;
    var sum_z: f64 = 0;
    var sum_hx: f64 = 0;
    var sum_hz: f64 = 0;
    var silhouette_mask: u8 = 0;

    for (indices, 0..) |i, k| {
        const e = entities[i];
        sum_x += e.pos[0];
        sum_z += e.pos[2];
        // Mean heading via unit-vector average — robust to wraparound
        // (the simple mean of e.g. 5° and 355° is 180°, the wrong
        // answer; the unit-vector mean is 0°).
        sum_hx += @cos(@as(f64, e.heading_rad));
        sum_hz += @sin(@as(f64, e.heading_rad));
        silhouette_mask |= @as(u8, 1) << @as(u3, e.silhouette);
        members[k] = e.id;
    }

    const n_f: f64 = @floatFromInt(indices.len);
    const cx: f32 = @floatCast(sum_x / n_f);
    const cz: f32 = @floatCast(sum_z / n_f);

    var max_d2: f32 = 0;
    for (indices) |i| {
        const e = entities[i];
        const dx = e.pos[0] - cx;
        const dz = e.pos[2] - cz;
        const d2 = dx * dx + dz * dz;
        if (d2 > max_d2) max_d2 = d2;
    }

    const ang_rad = std.math.atan2(sum_hz, sum_hx);
    const ang_deg = ang_rad * (180.0 / std.math.pi);
    const ang_deg_pos = if (ang_deg < 0) ang_deg + 360.0 else ang_deg;
    const heading_q14_2: u16 = @intFromFloat(@mod(ang_deg_pos * 4.0, 1440.0));

    const count: u8 = if (indices.len > 255) 255 else @intCast(indices.len);

    return .{
        .aggregate = .{
            .centroid = .{ cx, cz },
            .radius_m = @sqrt(max_d2),
            .count = count,
            .heading_deg = heading_q14_2,
            .silhouette_mask = silhouette_mask,
        },
        .members = members,
    };
}

/// Per-subscriber cluster view: derive a `FleetAggregate` from a
/// cluster while excluding entities the subscriber already receives on
/// their individual stream. Returns `null` when every member is
/// excluded (the cluster is empty for this subscriber).
///
/// Only `count` is recomputed. Centroid, radius, heading, and
/// silhouette mask remain pinned to the full-cluster values — they're
/// rendering hints, and the cost of recomputing them per subscriber
/// per cluster per fanout tick is wasted CPU until evidence says
/// otherwise. The count-correctness invariant from the M6.1 gate
/// (subscriber never sees an entity in both their aggregate and their
/// individual stream) is the only invariant that requires per-
/// subscriber adjustment.
pub fn aggregateForSubscriber(
    cluster: Cluster,
    excluded: []const EntityId,
) ?FleetAggregate {
    if (excluded.len == 0) return cluster.aggregate;

    var excluded_n: usize = 0;
    for (cluster.members) |m| {
        if (containsId(excluded, m)) excluded_n += 1;
    }
    if (excluded_n == 0) return cluster.aggregate;
    if (excluded_n >= cluster.members.len) return null;

    const remaining = cluster.members.len - excluded_n;
    var derived = cluster.aggregate;
    derived.count = if (remaining > 255) 255 else @intCast(remaining);
    return derived;
}

fn containsId(haystack: []const EntityId, needle: EntityId) bool {
    for (haystack) |h| if (h.eq(needle)) return true;
    return false;
}

// ============================================================
// M6.2 — replicated field wrapper + ECS-side glue
// ============================================================

/// Marker decl on the wrapper type so `dirtyMask` can recognize a field
/// as `replicated(T, tier)` at comptime without a name-based check.
/// Internal — callers introspect `Wrapper.tier` and `Wrapper.Inner`.
const ReplicatedMarker = struct {};

/// Field wrapper that pairs a value with its replication tier and a
/// change-detection bit. Component declarations match the docs/03 §6
/// shape exactly:
///
/// ```zig
/// const ShipState = struct {
///     hull_pose: replicated(Pose, .always),
///     sail_state: replicated(SailState, .visual),
///     plank_hp: replicated([]u16, .close_combat),
///     below_deck: replicated(InventoryRef, .boarded),
/// };
/// ```
///
/// `last_published` is a snapshot of `value` at the last `markPublished`
/// call; M7's pose codec will encode against it as the per-stream
/// keyframe. M6.2 doesn't dedupe writes that produce equal values —
/// equality on slices/non-trivial T has unbounded cost, so dirty is set
/// unconditionally on `set`. Producers that already know "no real
/// change" should simply skip the call.
pub fn replicated(comptime T: type, comptime field_tier: Tier) type {
    return struct {
        const Self = @This();

        /// Comptime constants for `dirtyMask` and downstream
        /// introspection (e.g. M6.4 wire-format dispatch).
        pub const Replicated: type = ReplicatedMarker;
        pub const tier: Tier = field_tier;
        pub const Inner = T;

        value: T,
        last_published: T,
        dirty: bool,

        pub fn init(v: T) Self {
            return .{ .value = v, .last_published = v, .dirty = false };
        }

        pub fn set(self: *Self, v: T) void {
            self.value = v;
            self.dirty = true;
        }

        pub fn markPublished(self: *Self) void {
            self.last_published = self.value;
            self.dirty = false;
        }
    };
}

fn isReplicatedField(comptime FieldType: type) bool {
    const info = @typeInfo(FieldType);
    if (info != .@"struct") return false;
    return @hasDecl(FieldType, "Replicated") and FieldType.Replicated == ReplicatedMarker;
}

/// Bitmask of `component` fields that are both dirty AND visible at
/// `subscriber_tier`. Bit `i` corresponds to the i-th declared field
/// of the struct (declaration order). Plain (non-`replicated`) fields
/// always contribute 0 — replicated and plain fields can mix.
///
/// 64-field cap is comptime-asserted; production components are
/// expected to stay well under it (the docs/03 §6 example has 4
/// fields).
pub fn dirtyMask(component: anytype, subscriber_tier: Tier) u64 {
    const T = @TypeOf(component);
    const fields = @typeInfo(T).@"struct".fields;
    comptime std.debug.assert(fields.len <= 64);

    var mask: u64 = 0;
    inline for (fields, 0..) |f, i| {
        if (comptime isReplicatedField(f.type)) {
            const fv = @field(component, f.name);
            if (fv.dirty and shouldReplicate(f.type.tier, subscriber_tier)) {
                mask |= @as(u64, 1) << @as(u6, @intCast(i));
            }
        }
    }
    return mask;
}

/// Mark every `replicated` field of `component` published. Called by
/// the producer after the per-tick fanout pass commits the component
/// to all subscribers. Subscriber dispatch (cell-mgr, M6.4) decides
/// what each peer actually receives at their tier; the dirty bit is
/// just "changed since last fanout tick", so a single uniform clear
/// after dispatch is correct.
pub fn markPublishedAll(component: anytype) void {
    const Ptr = @TypeOf(component);
    const T = @typeInfo(Ptr).pointer.child;
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields) |f| {
        if (comptime isReplicatedField(f.type)) {
            (&@field(component, f.name)).markPublished();
        }
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn mkSub(x: f32, z: f32, aboard: ?EntityId) Subscriber {
    return .{ .client_id = 0, .pos_world = .{ x, 0, z }, .aboard_ship = aboard };
}

fn mkEnt(id: u32) EntityId {
    return .{ .id = id, .generation = 0 };
}

// ---- effectiveTier: distance bands ----

test "effectiveTier: close_combat at 50 m" {
    const sub = mkSub(0, 0, null);
    const tier = effectiveTier(sub, .{ 50, 0, 0 }, null, TierThresholds.default);
    try testing.expectEqual(Tier.close_combat, tier);
}

test "effectiveTier: visual at 200 m" {
    const sub = mkSub(0, 0, null);
    const tier = effectiveTier(sub, .{ 200, 0, 0 }, null, TierThresholds.default);
    try testing.expectEqual(Tier.visual, tier);
}

test "effectiveTier: fleet_aggregate at 1000 m" {
    const sub = mkSub(0, 0, null);
    const tier = effectiveTier(sub, .{ 1000, 0, 0 }, null, TierThresholds.default);
    try testing.expectEqual(Tier.fleet_aggregate, tier);
}

test "effectiveTier: always at 3000 m" {
    const sub = mkSub(0, 0, null);
    const tier = effectiveTier(sub, .{ 3000, 0, 0 }, null, TierThresholds.default);
    try testing.expectEqual(Tier.always, tier);
}

test "effectiveTier: y component is ignored" {
    const sub = mkSub(0, 0, null);
    const flat = effectiveTier(sub, .{ 100, 0, 0 }, null, TierThresholds.default);
    const high = effectiveTier(sub, .{ 100, 1000, 0 }, null, TierThresholds.default);
    try testing.expectEqual(flat, high);
}

// ---- effectiveTier: threshold edges ----

test "effectiveTier: exactly on close_combat threshold = close_combat" {
    const sub = mkSub(0, 0, null);
    const tier = effectiveTier(sub, .{ 150, 0, 0 }, null, TierThresholds.default);
    try testing.expectEqual(Tier.close_combat, tier);
}

test "effectiveTier: exactly on visual threshold = visual" {
    const sub = mkSub(0, 0, null);
    const tier = effectiveTier(sub, .{ 500, 0, 0 }, null, TierThresholds.default);
    try testing.expectEqual(Tier.visual, tier);
}

test "effectiveTier: exactly on fleet_aggregate threshold = fleet_aggregate" {
    const sub = mkSub(0, 0, null);
    const tier = effectiveTier(sub, .{ 2000, 0, 0 }, null, TierThresholds.default);
    try testing.expectEqual(Tier.fleet_aggregate, tier);
}

// ---- effectiveTier: boarded special case (gate a) ----

test "boarded: subscriber and entity on same ship -> boarded" {
    const ship = mkEnt(42);
    const sub = mkSub(1000, 1000, ship);
    const tier = effectiveTier(sub, .{ 1001, 0, 1001 }, ship, TierThresholds.default);
    try testing.expectEqual(Tier.boarded, tier);
}

test "boarded: same ship trumps distance — entities far in ship-local space still boarded" {
    const ship = mkEnt(42);
    const sub = mkSub(0, 0, ship);
    // Pretend the ship is huge and the entity is 600 m away in ship-
    // local frame. Boarded gate should still fire.
    const tier = effectiveTier(sub, .{ 600, 0, 0 }, ship, TierThresholds.default);
    try testing.expectEqual(Tier.boarded, tier);
}

test "boarded: different ships -> distance check, not boarded" {
    const ship_a = mkEnt(42);
    const ship_b = mkEnt(43);
    const sub = mkSub(0, 0, ship_a);
    const tier = effectiveTier(sub, .{ 50, 0, 0 }, ship_b, TierThresholds.default);
    try testing.expectEqual(Tier.close_combat, tier);
}

test "boarded: subscriber free-agent, entity aboard -> distance check" {
    const ship = mkEnt(42);
    const sub = mkSub(0, 0, null);
    const tier = effectiveTier(sub, .{ 50, 0, 0 }, ship, TierThresholds.default);
    try testing.expectEqual(Tier.close_combat, tier);
}

test "boarded: id matches but generation differs -> not boarded (stale subscription)" {
    const ship_g0: EntityId = .{ .id = 42, .generation = 0 };
    const ship_g1: EntityId = .{ .id = 42, .generation = 1 };
    const sub = mkSub(0, 0, ship_g0);
    const tier = effectiveTier(sub, .{ 50, 0, 0 }, ship_g1, TierThresholds.default);
    try testing.expectEqual(Tier.close_combat, tier);
}

// ---- shouldReplicate ----

test "shouldReplicate: ordering — close subscriber gets every lower tier" {
    inline for (.{ Tier.always, Tier.fleet_aggregate, Tier.visual, Tier.close_combat, Tier.boarded }) |ft| {
        try testing.expect(shouldReplicate(ft, .boarded));
    }
}

test "shouldReplicate: visual subscriber doesn't get close_combat or boarded fields" {
    try testing.expect(shouldReplicate(.always, .visual));
    try testing.expect(shouldReplicate(.fleet_aggregate, .visual));
    try testing.expect(shouldReplicate(.visual, .visual));
    try testing.expect(!shouldReplicate(.close_combat, .visual));
    try testing.expect(!shouldReplicate(.boarded, .visual));
}

test "shouldReplicate: always subscriber gets only always fields" {
    try testing.expect(shouldReplicate(.always, .always));
    try testing.expect(!shouldReplicate(.fleet_aggregate, .always));
    try testing.expect(!shouldReplicate(.visual, .always));
}

// ---- transitions: promotion (gate b) and demotion (gate c) ----

test "transition: aggregate -> visual when entity crosses 500 m inward" {
    const sub = mkSub(0, 0, null);
    const t_far = effectiveTier(sub, .{ 600, 0, 0 }, null, TierThresholds.default);
    const t_near = effectiveTier(sub, .{ 400, 0, 0 }, null, TierThresholds.default);
    try testing.expectEqual(Tier.fleet_aggregate, t_far);
    try testing.expectEqual(Tier.visual, t_near);
}

test "transition: visual -> aggregate when entity crosses 500 m outward (symmetric demote)" {
    const sub = mkSub(0, 0, null);
    const t_near = effectiveTier(sub, .{ 400, 0, 0 }, null, TierThresholds.default);
    const t_far = effectiveTier(sub, .{ 600, 0, 0 }, null, TierThresholds.default);
    try testing.expectEqual(Tier.visual, t_near);
    try testing.expectEqual(Tier.fleet_aggregate, t_far);
}

test "transition: visual -> close_combat at 150 m and back" {
    const sub = mkSub(0, 0, null);
    const t_in = effectiveTier(sub, .{ 100, 0, 0 }, null, TierThresholds.default);
    const t_out = effectiveTier(sub, .{ 200, 0, 0 }, null, TierThresholds.default);
    try testing.expectEqual(Tier.close_combat, t_in);
    try testing.expectEqual(Tier.visual, t_out);
}

test "transition: aggregate -> always at 2000 m boundary" {
    const sub = mkSub(0, 0, null);
    const t_in = effectiveTier(sub, .{ 1500, 0, 0 }, null, TierThresholds.default);
    const t_out = effectiveTier(sub, .{ 2500, 0, 0 }, null, TierThresholds.default);
    try testing.expectEqual(Tier.fleet_aggregate, t_in);
    try testing.expectEqual(Tier.always, t_out);
}

// ---- cluster builder ----

test "buildClusters: empty input -> empty output" {
    const clusters = try buildClusters(testing.allocator, &.{}, 250.0, .{ 0, 0 }, 1000.0);
    defer freeClusters(testing.allocator, clusters);
    try testing.expectEqual(@as(usize, 0), clusters.len);
}

test "buildClusters: single bucket -> one cluster, full count" {
    const ents = [_]ClusterEntity{
        .{ .id = mkEnt(1), .pos = .{ 100, 0, 100 }, .heading_rad = 0, .silhouette = 0 },
        .{ .id = mkEnt(2), .pos = .{ 110, 0, 110 }, .heading_rad = 0, .silhouette = 0 },
        .{ .id = mkEnt(3), .pos = .{ 120, 0, 120 }, .heading_rad = 0, .silhouette = 1 },
    };
    const clusters = try buildClusters(testing.allocator, &ents, 250.0, .{ 0, 0 }, 1000.0);
    defer freeClusters(testing.allocator, clusters);
    try testing.expectEqual(@as(usize, 1), clusters.len);
    try testing.expectEqual(@as(u8, 3), clusters[0].aggregate.count);
    try testing.expectEqual(@as(usize, 3), clusters[0].members.len);
    // Silhouette mask: bits 0 and 1.
    try testing.expectEqual(@as(u8, 0b011), clusters[0].aggregate.silhouette_mask);
}

test "buildClusters: separate buckets -> separate clusters" {
    const ents = [_]ClusterEntity{
        .{ .id = mkEnt(1), .pos = .{ 100, 0, 100 }, .heading_rad = 0, .silhouette = 0 },
        .{ .id = mkEnt(2), .pos = .{ 800, 0, 800 }, .heading_rad = 0, .silhouette = 1 },
    };
    const clusters = try buildClusters(testing.allocator, &ents, 250.0, .{ 0, 0 }, 1000.0);
    defer freeClusters(testing.allocator, clusters);
    try testing.expectEqual(@as(usize, 2), clusters.len);
    for (clusters) |c| try testing.expectEqual(@as(u8, 1), c.aggregate.count);
}

test "buildClusters: centroid is mean of member positions" {
    const ents = [_]ClusterEntity{
        .{ .id = mkEnt(1), .pos = .{ 100, 0, 100 }, .heading_rad = 0, .silhouette = 0 },
        .{ .id = mkEnt(2), .pos = .{ 200, 0, 200 }, .heading_rad = 0, .silhouette = 0 },
    };
    const clusters = try buildClusters(testing.allocator, &ents, 500.0, .{ 0, 0 }, 1000.0);
    defer freeClusters(testing.allocator, clusters);
    try testing.expectEqual(@as(usize, 1), clusters.len);
    try testing.expectApproxEqAbs(@as(f32, 150.0), clusters[0].aggregate.centroid[0], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 150.0), clusters[0].aggregate.centroid[1], 0.01);
}

test "buildClusters: radius is max member distance from centroid" {
    const ents = [_]ClusterEntity{
        .{ .id = mkEnt(1), .pos = .{ 100, 0, 100 }, .heading_rad = 0, .silhouette = 0 },
        .{ .id = mkEnt(2), .pos = .{ 200, 0, 100 }, .heading_rad = 0, .silhouette = 0 },
    };
    const clusters = try buildClusters(testing.allocator, &ents, 500.0, .{ 0, 0 }, 1000.0);
    defer freeClusters(testing.allocator, clusters);
    // Centroid x=150; both members 50 m away.
    try testing.expectApproxEqAbs(@as(f32, 50.0), clusters[0].aggregate.radius_m, 0.01);
}

test "buildClusters: heading averaging handles wraparound (5° and 355° -> ~0°)" {
    const ents = [_]ClusterEntity{
        .{ .id = mkEnt(1), .pos = .{ 100, 0, 100 }, .heading_rad = std.math.degreesToRadians(5), .silhouette = 0 },
        .{ .id = mkEnt(2), .pos = .{ 100, 0, 110 }, .heading_rad = std.math.degreesToRadians(355), .silhouette = 0 },
    };
    const clusters = try buildClusters(testing.allocator, &ents, 500.0, .{ 0, 0 }, 1000.0);
    defer freeClusters(testing.allocator, clusters);
    // q14.2: degrees × 4. ~0° -> ~0; not 720 (which would be the naive
    // arithmetic mean of 5° and 355°).
    const h = clusters[0].aggregate.heading_deg;
    try testing.expect(h <= 4 or h >= 1436);
}

// ---- gate (d): per-subscriber count correctness ----

test "aggregateForSubscriber: no exclusions -> full aggregate" {
    const ents = [_]ClusterEntity{
        .{ .id = mkEnt(1), .pos = .{ 100, 0, 100 }, .heading_rad = 0, .silhouette = 0 },
        .{ .id = mkEnt(2), .pos = .{ 110, 0, 110 }, .heading_rad = 0, .silhouette = 0 },
    };
    const clusters = try buildClusters(testing.allocator, &ents, 500.0, .{ 0, 0 }, 1000.0);
    defer freeClusters(testing.allocator, clusters);
    const view = aggregateForSubscriber(clusters[0], &.{}).?;
    try testing.expectEqual(@as(u8, 2), view.count);
}

test "aggregateForSubscriber: exclusion decrements count exactly" {
    const ents = [_]ClusterEntity{
        .{ .id = mkEnt(1), .pos = .{ 100, 0, 100 }, .heading_rad = 0, .silhouette = 0 },
        .{ .id = mkEnt(2), .pos = .{ 110, 0, 110 }, .heading_rad = 0, .silhouette = 0 },
        .{ .id = mkEnt(3), .pos = .{ 120, 0, 120 }, .heading_rad = 0, .silhouette = 0 },
        .{ .id = mkEnt(4), .pos = .{ 130, 0, 130 }, .heading_rad = 0, .silhouette = 0 },
        .{ .id = mkEnt(5), .pos = .{ 140, 0, 140 }, .heading_rad = 0, .silhouette = 0 },
    };
    const clusters = try buildClusters(testing.allocator, &ents, 500.0, .{ 0, 0 }, 1000.0);
    defer freeClusters(testing.allocator, clusters);

    // Two members individually streamed; aggregate should report 3.
    const excluded = [_]EntityId{ mkEnt(1), mkEnt(3) };
    const view = aggregateForSubscriber(clusters[0], &excluded).?;
    try testing.expectEqual(@as(u8, 3), view.count);
}

test "aggregateForSubscriber: exclusion of unknown id is a no-op" {
    const ents = [_]ClusterEntity{
        .{ .id = mkEnt(1), .pos = .{ 100, 0, 100 }, .heading_rad = 0, .silhouette = 0 },
        .{ .id = mkEnt(2), .pos = .{ 110, 0, 110 }, .heading_rad = 0, .silhouette = 0 },
    };
    const clusters = try buildClusters(testing.allocator, &ents, 500.0, .{ 0, 0 }, 1000.0);
    defer freeClusters(testing.allocator, clusters);

    const excluded = [_]EntityId{mkEnt(99)};
    const view = aggregateForSubscriber(clusters[0], &excluded).?;
    try testing.expectEqual(@as(u8, 2), view.count);
}

test "aggregateForSubscriber: all members excluded -> null" {
    const ents = [_]ClusterEntity{
        .{ .id = mkEnt(1), .pos = .{ 100, 0, 100 }, .heading_rad = 0, .silhouette = 0 },
        .{ .id = mkEnt(2), .pos = .{ 110, 0, 110 }, .heading_rad = 0, .silhouette = 0 },
    };
    const clusters = try buildClusters(testing.allocator, &ents, 500.0, .{ 0, 0 }, 1000.0);
    defer freeClusters(testing.allocator, clusters);

    const excluded = [_]EntityId{ mkEnt(1), mkEnt(2) };
    const view = aggregateForSubscriber(clusters[0], &excluded);
    try testing.expectEqual(@as(?FleetAggregate, null), view);
}

test "aggregateForSubscriber: generation tag — id match w/ wrong generation is not excluded" {
    const ents = [_]ClusterEntity{
        .{ .id = .{ .id = 1, .generation = 5 }, .pos = .{ 100, 0, 100 }, .heading_rad = 0, .silhouette = 0 },
        .{ .id = .{ .id = 2, .generation = 0 }, .pos = .{ 110, 0, 110 }, .heading_rad = 0, .silhouette = 0 },
    };
    const clusters = try buildClusters(testing.allocator, &ents, 500.0, .{ 0, 0 }, 1000.0);
    defer freeClusters(testing.allocator, clusters);

    // Stale subscription on old generation — must NOT match the live
    // entity, so count stays at 2.
    const stale = [_]EntityId{.{ .id = 1, .generation = 4 }};
    const view = aggregateForSubscriber(clusters[0], &stale).?;
    try testing.expectEqual(@as(u8, 2), view.count);
}

test "count invariant: aggregate.count + |excluded ∩ members| == |members|" {
    // Spread 12 entities across one bucket; sweep through every
    // possible exclusion set size 0..12 and assert no double counting.
    var ents: [12]ClusterEntity = undefined;
    for (&ents, 0..) |*e, i| {
        e.* = .{
            .id = mkEnt(@intCast(i + 1)),
            .pos = .{ @as(f32, 100) + @as(f32, @floatFromInt(i)), 0, 100 },
            .heading_rad = 0,
            .silhouette = @intCast(i % 3),
        };
    }
    const clusters = try buildClusters(testing.allocator, &ents, 500.0, .{ 0, 0 }, 1000.0);
    defer freeClusters(testing.allocator, clusters);
    try testing.expectEqual(@as(usize, 1), clusters.len);

    var k: usize = 0;
    while (k <= ents.len) : (k += 1) {
        const excluded = blk: {
            const buf = try testing.allocator.alloc(EntityId, k);
            for (buf, 0..) |*x, i| x.* = mkEnt(@intCast(i + 1));
            break :blk buf;
        };
        defer testing.allocator.free(excluded);

        const view = aggregateForSubscriber(clusters[0], excluded);
        const remaining = ents.len - k;
        if (remaining == 0) {
            try testing.expectEqual(@as(?FleetAggregate, null), view);
        } else {
            try testing.expectEqual(@as(u8, @intCast(remaining)), view.?.count);
        }
    }
}

// ---- microbenchmarks: gate latencies ----
//
// The M6.1 budget (<500 ns/call, <100 µs/cluster at N=50) is the
// production target; only enforced in Release builds. Debug-mode
// `zig build test` skips them — overhead from safety checks and the
// non-inlined ArrayList path inflates runtime by ~30× and would
// false-positive the gate. Run `make test-release` to verify.

const builtin = @import("builtin");

test "perf: filter latency < 500 ns per call" {
    if (builtin.mode == .Debug) return error.SkipZigTest;

    const sub = mkSub(0, 0, null);
    const thresholds = TierThresholds.default;

    var rng = std.Random.DefaultPrng.init(0xC0FFEE);
    const r = rng.random();
    const N = 100_000;
    var positions: [N][3]f32 = undefined;
    for (&positions) |*p| {
        p.* = .{ (r.float(f32) - 0.5) * 4000, 0, (r.float(f32) - 0.5) * 4000 };
    }

    var sink: u64 = 0;
    var timer = try std.time.Timer.start();
    for (positions) |p| {
        const t = effectiveTier(sub, p, null, thresholds);
        sink +%= @intFromEnum(t);
    }
    const elapsed_ns = timer.read();
    std.mem.doNotOptimizeAway(sink);

    const ns_per_call = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(N));
    std.debug.print("\n[M6.1] effectiveTier: {d:.1} ns/call ({d} samples)\n", .{ ns_per_call, N });
    try testing.expect(ns_per_call < 500.0);
}

test "perf: clustering pass < 100 µs at N=50" {
    if (builtin.mode == .Debug) return error.SkipZigTest;

    // Production pattern: spatial-index runs the clustering pass on a
    // per-tick arena (5 Hz × N cells), so per-cluster `members` slices
    // never go through the global allocator's free path. The gate
    // measures that; a benchmark using `testing.allocator` would
    // measure GPA-with-safety bookkeeping, not the algorithm.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var rng = std.Random.DefaultPrng.init(0xCAFEBABE);
    const r = rng.random();
    var ents: [50]ClusterEntity = undefined;
    for (&ents, 0..) |*e, i| {
        e.* = .{
            .id = mkEnt(@intCast(i + 1)),
            .pos = .{ r.float(f32) * 1000, 0, r.float(f32) * 1000 },
            .heading_rad = r.float(f32) * 2 * std.math.pi,
            .silhouette = @intCast(r.intRangeAtMost(u32, 0, 2)),
        };
    }

    // Warm-up — also covers any first-time arena page reservation.
    {
        const warm = try buildClusters(a, &ents, 250.0, .{ 0, 0 }, 1000.0);
        std.mem.doNotOptimizeAway(warm);
    }

    // Average over many iterations to wash out timer jitter; the
    // arena keeps growing (no inter-iteration free) but allocations
    // stay O(1) cost so per-iteration time is stable.
    const iterations = 200;
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        const clusters = try buildClusters(a, &ents, 250.0, .{ 0, 0 }, 1000.0);
        std.mem.doNotOptimizeAway(clusters);
    }
    const elapsed_ns = timer.read();

    const us_per_iter = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations)) / 1000.0;
    std.debug.print("[M6.1] buildClusters N=50 (arena, avg of {d}): {d:.2} µs\n", .{ iterations, us_per_iter });
    try testing.expect(us_per_iter < 100.0);
}

// ============================================================
// M6.2 tests — replicated wrapper + dirtyMask roundtrip
// ============================================================

// Stand-in payload types for the docs/03 §6 ShipState example. We
// don't need the real Pose/Inventory shapes — M6.2 is testing the
// wrapper, not the inner T.
const TestPose = struct { x: f32, y: f32, z: f32 };
const TestSail = struct { hoist: f32, trim: f32 };

// Fields chosen to cover all five tiers (close_combat is implicitly
// covered by the `<= subscriber_tier` ordering through `boarded`).
const TestShip = struct {
    name: replicated([8]u8, .always),
    fleet_summary: replicated(u32, .fleet_aggregate),
    hull_pose: replicated(TestPose, .visual),
    plank_hp: replicated(u16, .close_combat),
    inv_count: replicated(u32, .boarded),

    fn init() TestShip {
        return .{
            .name = .init([_]u8{ 'A', 'd', 'a', 'm', 0, 0, 0, 0 }),
            .fleet_summary = .init(0),
            .hull_pose = .init(.{ .x = 0, .y = 0, .z = 0 }),
            .plank_hp = .init(1000),
            .inv_count = .init(0),
        };
    }
};

// Field indices into the TestShip struct, declaration order. Used to
// build expected-mask values without typing magic numbers.
const F_NAME: u6 = 0;
const F_FLEET: u6 = 1;
const F_POSE: u6 = 2;
const F_PLANK: u6 = 3;
const F_INV: u6 = 4;

fn bit(i: u6) u64 {
    return @as(u64, 1) << i;
}

test "replicated: init -> not dirty, value == last_published" {
    const ship = TestShip.init();
    try testing.expect(!ship.name.dirty);
    try testing.expect(!ship.hull_pose.dirty);
    try testing.expect(!ship.inv_count.dirty);
    try testing.expectEqual(ship.plank_hp.value, ship.plank_hp.last_published);
}

test "replicated: set marks dirty and updates value but not last_published" {
    var ship = TestShip.init();
    ship.plank_hp.set(900);
    try testing.expect(ship.plank_hp.dirty);
    try testing.expectEqual(@as(u16, 900), ship.plank_hp.value);
    try testing.expectEqual(@as(u16, 1000), ship.plank_hp.last_published);
}

test "replicated: markPublished snapshots value and clears dirty" {
    var ship = TestShip.init();
    ship.plank_hp.set(900);
    ship.plank_hp.markPublished();
    try testing.expect(!ship.plank_hp.dirty);
    try testing.expectEqual(@as(u16, 900), ship.plank_hp.value);
    try testing.expectEqual(@as(u16, 900), ship.plank_hp.last_published);
}

test "dirtyMask: nothing dirty -> 0 at every tier" {
    const ship = TestShip.init();
    inline for (.{ Tier.always, Tier.fleet_aggregate, Tier.visual, Tier.close_combat, Tier.boarded }) |t| {
        try testing.expectEqual(@as(u64, 0), dirtyMask(ship, t));
    }
}

test "dirtyMask: visual subscriber sees only fields with tier <= visual" {
    var ship = TestShip.init();
    ship.fleet_summary.set(7);
    ship.hull_pose.set(.{ .x = 1, .y = 2, .z = 3 });
    ship.plank_hp.set(900);
    ship.inv_count.set(42);
    // Expected: fleet_summary (1) and hull_pose (visual). plank_hp
    // (close_combat) and inv_count (boarded) are above the subscriber's
    // tier, so they're excluded even though they're dirty.
    const mask = dirtyMask(ship, .visual);
    try testing.expectEqual(bit(F_FLEET) | bit(F_POSE), mask);
}

test "dirtyMask: boarded subscriber sees every dirty field" {
    var ship = TestShip.init();
    ship.name.set([_]u8{ 'M', 'a', 'r', 'y', 0, 0, 0, 0 });
    ship.fleet_summary.set(7);
    ship.hull_pose.set(.{ .x = 1, .y = 2, .z = 3 });
    ship.plank_hp.set(900);
    ship.inv_count.set(42);
    const mask = dirtyMask(ship, .boarded);
    try testing.expectEqual(
        bit(F_NAME) | bit(F_FLEET) | bit(F_POSE) | bit(F_PLANK) | bit(F_INV),
        mask,
    );
}

test "dirtyMask: always subscriber sees only the always field" {
    var ship = TestShip.init();
    ship.name.set([_]u8{ 'M', 'a', 'r', 'y', 0, 0, 0, 0 });
    ship.hull_pose.set(.{ .x = 1, .y = 2, .z = 3 });
    ship.plank_hp.set(900);
    const mask = dirtyMask(ship, .always);
    try testing.expectEqual(bit(F_NAME), mask);
}

test "dirtyMask: close_combat subscriber excludes boarded field" {
    var ship = TestShip.init();
    ship.plank_hp.set(900);
    ship.inv_count.set(42);
    const mask = dirtyMask(ship, .close_combat);
    try testing.expectEqual(bit(F_PLANK), mask);
}

test "dirtyMask: fleet_aggregate subscriber excludes visual+ fields" {
    var ship = TestShip.init();
    ship.fleet_summary.set(7);
    ship.hull_pose.set(.{ .x = 1, .y = 2, .z = 3 });
    ship.plank_hp.set(900);
    const mask = dirtyMask(ship, .fleet_aggregate);
    try testing.expectEqual(bit(F_FLEET), mask);
}

test "dirtyMask roundtrip: markPublishedAll clears every bit at every tier" {
    var ship = TestShip.init();
    ship.name.set([_]u8{ 'M', 'a', 'r', 'y', 0, 0, 0, 0 });
    ship.fleet_summary.set(7);
    ship.hull_pose.set(.{ .x = 1, .y = 2, .z = 3 });
    ship.plank_hp.set(900);
    ship.inv_count.set(42);
    // Pre-publish: boarded subscriber sees all five.
    try testing.expect(dirtyMask(ship, .boarded) != 0);
    markPublishedAll(&ship);
    inline for (.{ Tier.always, Tier.fleet_aggregate, Tier.visual, Tier.close_combat, Tier.boarded }) |t| {
        try testing.expectEqual(@as(u64, 0), dirtyMask(ship, t));
    }
    // last_published snapshot took on the new values.
    try testing.expectEqual(@as(u16, 900), ship.plank_hp.last_published);
    try testing.expectEqual(@as(u32, 42), ship.inv_count.last_published);
}

test "dirtyMask roundtrip: re-set after publish dirties again" {
    var ship = TestShip.init();
    ship.hull_pose.set(.{ .x = 1, .y = 0, .z = 0 });
    markPublishedAll(&ship);
    try testing.expectEqual(@as(u64, 0), dirtyMask(ship, .boarded));
    ship.hull_pose.set(.{ .x = 2, .y = 0, .z = 0 });
    try testing.expectEqual(bit(F_POSE), dirtyMask(ship, .visual));
}

test "dirtyMask: plain (non-replicated) fields contribute 0" {
    const Mixed = struct {
        rep: replicated(u32, .visual),
        // Plain field at index 1 — must not affect the mask.
        plain_counter: u32,
        rep2: replicated(u32, .close_combat),
    };
    var m: Mixed = .{
        .rep = .init(0),
        .plain_counter = 0,
        .rep2 = .init(0),
    };
    m.rep.set(1);
    m.plain_counter = 999; // would-be bit 1; must NOT appear
    m.rep2.set(2);
    const mask = dirtyMask(m, .close_combat);
    // Bits 0 and 2 set; bit 1 (plain field) cleared.
    try testing.expectEqual(@as(u64, 0b101), mask);
}

test "dirtyMask: comptime tier+Inner introspection round-trips" {
    // Sanity check that downstream code (M6.4 wire-format dispatch)
    // can read back tier and Inner from the wrapper type.
    const F = replicated(TestPose, .visual);
    try testing.expectEqual(Tier.visual, F.tier);
    try testing.expectEqual(TestPose, F.Inner);
}
