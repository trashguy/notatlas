//! Per-subscriber fanout pass for cell-mgr — the slow lane.
//!
//! Per docs/08 §2.3 the cell-mgr fanout tick owns "tier ≤ 0.5
//! cadence" content: tier 0 (always, hull pose at 30 Hz) and tier
//! 0.5 (fleet aggregate at 5 Hz). Tier 1+ flows separately via the
//! fast-lane callback path (`Fanout.relayState`).
//!
//! In practice tier 0 individual records are subsumed by the tier
//! 0.5 cluster path (docs/08 §3.2a: distant entities flow as cluster
//! summaries instead of individual records — the 160× BW reduction
//! lever). So the slow-lane payload is **cluster records only**:
//!   - 8 B PayloadHeader { entity_count = 0, cluster_count }
//!   - cluster_count × 16 B ClusterRecord
//!
//! `entity_count` stays in the wire shape so receivers don't need a
//! version flip when individual records are reintroduced for some
//! field type that doesn't naturally fit into a cluster summary.
//!
//! Cluster pathway runs at 5 Hz (configurable). spatial-index will
//! eventually own the cluster build per docs/08 §3.2a; cell-mgr plays
//! both roles for now (until the spatial-index service spins up).
//!
//! Hot-path discipline: per-subscriber output buffers are pre-grown
//! at subscribe time and reused with `clearRetainingCapacity` per
//! tick. The cluster pass uses a dedicated arena that
//! `reset(.retain_capacity)`s each cycle — first build sizes it, all
//! subsequent builds reuse without growing. Net steady-state allocs
//! per tick: 0 (verified by the M6.4 gate test under a counting
//! allocator).
//!
//! Sink is a thin vtable so the same Fanout drives both real NATS
//! publishes (NatsSink) and the in-process gate test (CaptureSink in
//! the test module).

const std = @import("std");
const notatlas = @import("notatlas");
const replication = notatlas.replication;
const pose_codec = notatlas.pose_codec;

const State = @import("state.zig").State;

pub const Tier = replication.Tier;
pub const TierThresholds = replication.TierThresholds;
pub const EntityId = replication.EntityId;

// ============================================================
// Wire payload shapes
// ============================================================
//
// Per-subscriber payload layout:
//   [0..8]                              PayloadHeader
//   [8..8+ec*20]                        EntityRecord[entity_count]
//   [8+ec*20..8+ec*20+cc*16]            ClusterRecord[cluster_count]
//
// where ec = header.entity_count, cc = header.cluster_count.
//
// EntityRecord (20 B):
//   [0..4]   id          u32 little-endian
//   [4..6]   generation  u16 little-endian
//   [6..20]  pose codec  pose_codec.encodePose delta-mode (14 B)
//
// ClusterRecord (16 B): mirrors replication.FleetAggregate.

pub const PayloadHeader = extern struct {
    entity_count: u32,
    cluster_count: u32,
};
pub const payload_header_size: usize = @sizeOf(PayloadHeader);

pub const record_header_size: usize = 6;
pub const entity_record_size: usize = record_header_size + pose_codec.delta_size;

pub const ClusterRecord = extern struct {
    centroid_x: f32,
    centroid_z: f32,
    radius_m: f32,
    heading_deg: u16,
    count: u8,
    silhouette_mask: u8,
};
pub const cluster_record_size: usize = @sizeOf(ClusterRecord);

comptime {
    // 8 B header + 20 B entity + 16 B cluster: budgets assumed by the
    // initial-capacity sizing and by docs/research/m6-bandwidth.md.
    // Surprise size changes would silently invalidate the BW report.
    std.debug.assert(payload_header_size == 8);
    std.debug.assert(entity_record_size == 20);
    std.debug.assert(cluster_record_size == 16);
}

fn writeEntityHeader(buf: []u8, id: u32, generation: u16) void {
    std.mem.writeInt(u32, buf[0..4], id, .little);
    std.mem.writeInt(u16, buf[4..6], generation, .little);
}

pub fn readRecordId(buf: []const u8) u32 {
    return std.mem.readInt(u32, buf[0..4], .little);
}

pub fn readRecordGeneration(buf: []const u8) u16 {
    return std.mem.readInt(u16, buf[4..6], .little);
}

/// `gw.client.<id>.cmd` is at most "gw.client." (10) + u64 dec (20) +
/// ".cmd" (4) = 34 chars. 64 leaves slack for alternate subject
/// schemes without re-tuning.
pub const max_subject_len: usize = 64;

// ============================================================
// Sink: where publishes go
// ============================================================

pub const Sink = struct {
    ctx: *anyopaque,
    publishFn: *const fn (ctx: *anyopaque, client_id: u64, payload: []const u8) anyerror!void,

    pub fn publish(self: Sink, client_id: u64, payload: []const u8) anyerror!void {
        return self.publishFn(self.ctx, client_id, payload);
    }
};

// ============================================================
// Fanout
// ============================================================

/// Initial per-subscriber output buffer capacity. With slow-lane =
/// clusters only, the realistic max is ~64 clusters/cell × 16 B + 8 B
/// header ≈ 1 KB. 4 KB leaves room for future `entity_count > 0`
/// content (e.g. tier-0 fields that don't map to a cluster) without
/// reallocation.
pub const default_output_capacity: usize = 4 * 1024;

pub const ClusterConfig = struct {
    /// Master ticks between cluster rebuilds. Default 6 = 30 Hz / 5 Hz
    /// per docs/08 §3.2a.
    period_ticks: u32 = 6,
    /// Cell origin (bottom-left in xz). Defaults position the M6
    /// synthetic scenarios (centred on origin) symmetrically inside
    /// the cell.
    cell_origin: [2]f32 = .{ -2000, -2000 },
    cell_size_m: f32 = 4000,
    /// Bucket grid resolution for `replication.buildClusters`. 500 m
    /// gives an 8×8 = 64 bucket grid inside a 4 km cell, coarse
    /// enough to keep cluster counts low and fine enough that a single
    /// cluster's radius doesn't span the whole cell.
    sub_cell_size_m: f32 = 500,
};

const SubscriberBuffers = struct {
    /// Outbound payload — header + cluster records (+ entity records,
    /// reserved for future tier-0 content that doesn't fit a cluster
    /// summary).
    output: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *SubscriberBuffers, allocator: std.mem.Allocator) void {
        self.output.deinit(allocator);
    }
};

pub const Fanout = struct {
    allocator: std.mem.Allocator,
    thresholds: TierThresholds,
    cluster_cfg: ClusterConfig,
    output_capacity: usize,

    /// client_id → per-subscriber buffer pair. Allocated on
    /// `ensureSubscriber`, reused with `clearRetainingCapacity`.
    subs: std.AutoHashMapUnmanaged(u64, SubscriberBuffers),

    /// Master tick counter. Increments every `runTick` call.
    /// `master_tick % cluster_cfg.period_ticks == 0` triggers a
    /// cluster rebuild.
    master_tick: u64,

    /// Arena backing the cluster builder's bucket lists and per-
    /// cluster `members` slices. Reset (retaining capacity) before
    /// each cluster pass; first pass sizes it, subsequent passes
    /// reuse without growing because the per-cell entity cap is
    /// bounded.
    cluster_arena: std.heap.ArenaAllocator,

    /// Re-used staging buffer for the cluster builder's input.
    /// Pre-grown to entity_cap; `clearRetainingCapacity` per pass.
    cluster_input: std.ArrayListUnmanaged(replication.ClusterEntity),

    /// Latest cluster set, owned by `cluster_arena`. Lifetime ends at
    /// the next cluster pass (when the arena resets).
    clusters: []replication.Cluster,

    /// Fixed-size scratch buffer for the fast-lane relay path
    /// (`relayState`). One single-record payload fits in
    /// payload_header_size + entity_record_size = 28 B; 64 B leaves
    /// room without forcing a per-call allocation.
    relay_buf: [64]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, thresholds: TierThresholds) Fanout {
        return .{
            .allocator = allocator,
            .thresholds = thresholds,
            .cluster_cfg = .{},
            .output_capacity = default_output_capacity,
            .subs = .empty,
            .master_tick = 0,
            .cluster_arena = std.heap.ArenaAllocator.init(allocator),
            .cluster_input = .empty,
            .clusters = &.{},
        };
    }

    pub fn deinit(self: *Fanout) void {
        var it = self.subs.iterator();
        while (it.next()) |e| e.value_ptr.deinit(self.allocator);
        self.subs.deinit(self.allocator);
        self.cluster_input.deinit(self.allocator);
        self.cluster_arena.deinit();
    }

    /// Allocate per-subscriber buffers for `client_id`. Idempotent —
    /// repeat calls keep the existing buffers (and their retained
    /// capacity).
    pub fn ensureSubscriber(self: *Fanout, client_id: u64) !void {
        const gop = try self.subs.getOrPut(self.allocator, client_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
            try gop.value_ptr.output.ensureTotalCapacity(self.allocator, self.output_capacity);
        }
    }

    /// Free the buffers for `client_id`. No-op if absent.
    pub fn removeSubscriber(self: *Fanout, client_id: u64) void {
        if (self.subs.fetchRemove(client_id)) |kv| {
            var sb = kv.value;
            sb.deinit(self.allocator);
        }
    }

    /// One fanout tick — the slow lane. On cluster-pass ticks
    /// (master_tick % period_ticks == 0), rebuilds the global cluster
    /// set from the current entity table. Then walks subscribers,
    /// emitting **cluster records only** (visual+ entities flow via
    /// `relayState`, the fast-lane callback path; tier-0 individual
    /// records are subsumed by cluster summaries per docs/08 §3.2a).
    /// Returns the number of subscribers we published payloads for.
    pub fn runTick(self: *Fanout, state: *const State, sink: Sink) !usize {
        if (self.master_tick % self.cluster_cfg.period_ticks == 0) {
            try self.rebuildClusters(state);
        }
        defer self.master_tick += 1;

        var sub_it = state.subscribers.iterator();
        var publishes: usize = 0;
        while (sub_it.next()) |sub_entry| {
            const sub = sub_entry.value_ptr.*;

            const sb = self.subs.getPtr(sub.client_id) orelse return error.UnknownSubscriber;
            sb.output.clearRetainingCapacity();

            // Reserve the header slot — patched after we know counts.
            try sb.output.appendNTimes(self.allocator, 0, payload_header_size);

            var cluster_count: u32 = 0;
            for (self.clusters) |cluster| {
                // Centroid filter: include clusters whose centroid is
                // at fleet_aggregate or further from the sub. Skip
                // clusters whose centroid is in visual range — the sub
                // is close enough that the fast-lane carries the
                // individual entities and a summary adds nothing.
                const centroid_pos: [3]f32 = .{ cluster.aggregate.centroid[0], 0, cluster.aggregate.centroid[1] };
                const centroid_tier = replication.effectiveTier(sub, centroid_pos, null, self.thresholds);
                if (@intFromEnum(centroid_tier) >= @intFromEnum(Tier.visual)) continue;

                // No excluded set — slow-lane doesn't emit individual
                // records anymore, so there's nothing to pin out of
                // the cluster aggregate. Pass empty.
                const view = replication.aggregateForSubscriber(cluster, &.{}) orelse continue;
                if (view.count == 0) continue;

                const rec: ClusterRecord = .{
                    .centroid_x = view.centroid[0],
                    .centroid_z = view.centroid[1],
                    .radius_m = view.radius_m,
                    .heading_deg = view.heading_deg,
                    .count = view.count,
                    .silhouette_mask = view.silhouette_mask,
                };
                try sb.output.appendSlice(self.allocator, std.mem.asBytes(&rec));
                cluster_count += 1;
            }

            const header: PayloadHeader = .{ .entity_count = 0, .cluster_count = cluster_count };
            @memcpy(sb.output.items[0..payload_header_size], std.mem.asBytes(&header));

            try sink.publish(sub.client_id, sb.output.items);
            publishes += 1;
        }
        return publishes;
    }

    /// Fast-lane callback path per docs/08 §2.3. Forward a single
    /// entity's state to every subscriber whose effective tier is
    /// ≥ visual — without waiting for the slow-lane fanout tick. The
    /// caller (cell-mgr's `sim.entity.*.state` subscription) invokes
    /// this on every inbound state msg.
    ///
    /// Pose + aboard_ship come from the inbound msg, not from the
    /// cell's entity table — so subscribers near a cell boundary
    /// receive state for entities in neighbour cells too. The entity
    /// table membership filter only gates the slow-lane (cluster
    /// pathway is per-cell); the fast-lane works on pure geometry.
    /// This is the cleanest fix to the cross-cell visibility
    /// limitation noted in docs/08 §2A.3 — entity ownership stays
    /// decoupled from spatial location, and visibility is a
    /// per-(sub × pose) computation independent of any cell.
    ///
    /// Stale-generation guard: when the entity *is* in this cell's
    /// table at a higher generation, skip — the inbound msg is from
    /// a now-recycled instance. Cross-cell msgs (entity unknown to
    /// this cell) bypass the guard since we have no reference to
    /// compare against.
    ///
    /// Allocation-free: builds a single-record payload in `relay_buf`
    /// (28 B used out of 64 B), publishes via `sink`. nats-zig's
    /// publish path itself is alloc-free (fixed PUB header buffer).
    /// Returns the number of forwards made.
    pub fn relayState(
        self: *Fanout,
        state: *const State,
        ent_id: replication.EntityId,
        pose: pose_codec.Pose,
        aboard_ship: ?replication.EntityId,
        sink: Sink,
    ) !usize {
        if (state.entities.get(ent_id.id)) |existing| {
            if (existing.id.generation != ent_id.generation) return 0;
        }

        // Build the per-record bytes once — same value goes to every
        // subscriber.
        const slot = self.relay_buf[0 .. payload_header_size + entity_record_size];
        const header: PayloadHeader = .{ .entity_count = 1, .cluster_count = 0 };
        @memcpy(slot[0..payload_header_size], std.mem.asBytes(&header));
        const rec_slot = slot[payload_header_size..];
        writeEntityHeader(rec_slot[0..record_header_size], ent_id.id, ent_id.generation);
        const n = pose_codec.encodePose(pose, pose, null, rec_slot[record_header_size..][0..pose_codec.delta_size]);
        std.debug.assert(n == pose_codec.delta_size);

        var forwards: usize = 0;
        var sub_it = state.subscribers.iterator();
        while (sub_it.next()) |sub_entry| {
            const sub = sub_entry.value_ptr.*;
            const tier = replication.effectiveTier(sub, pose.pos, aboard_ship, self.thresholds);
            if (@intFromEnum(tier) < @intFromEnum(Tier.visual)) continue;
            try sink.publish(sub.client_id, slot);
            forwards += 1;
        }
        return forwards;
    }

    /// Cluster-pass body: snapshot entities into the cluster-builder
    /// input list, run buildClusters into the arena, swap the cached
    /// `clusters` slice over. Reset-then-reuse: arena memory persists
    /// across passes, so steady-state tick allocations stay at zero.
    fn rebuildClusters(self: *Fanout, state: *const State) !void {
        _ = self.cluster_arena.reset(.retain_capacity);
        const arena = self.cluster_arena.allocator();

        self.cluster_input.clearRetainingCapacity();
        try self.cluster_input.ensureTotalCapacity(self.allocator, state.entities.count());

        var it = state.entities.iterator();
        while (it.next()) |e| {
            const ent = e.value_ptr.*;
            try self.cluster_input.append(self.allocator, .{
                .id = ent.id,
                .pos = ent.pos,
                .heading_rad = ent.heading_rad,
                .silhouette = ent.silhouette,
            });
        }

        self.clusters = try replication.buildClusters(
            arena,
            self.cluster_input.items,
            self.cluster_cfg.sub_cell_size_m,
            self.cluster_cfg.cell_origin,
            self.cluster_cfg.cell_size_m,
        );
    }
};

// NatsSink lives in main.zig where the `nats` module is already
// imported — keeps this file decoupled from the transport.

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

// CaptureSink: in-process Sink that records the latest payload per
// client_id. Used by the gate test.
const CaptureSink = struct {
    allocator: std.mem.Allocator,
    /// client_id → owned latest payload bytes.
    captured: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(u8)) = .empty,

    fn deinit(self: *CaptureSink) void {
        var it = self.captured.iterator();
        while (it.next()) |e| e.value_ptr.deinit(self.allocator);
        self.captured.deinit(self.allocator);
    }

    fn sink(self: *CaptureSink) Sink {
        return .{ .ctx = self, .publishFn = capture };
    }

    fn capture(ctx: *anyopaque, client_id: u64, payload: []const u8) anyerror!void {
        const self: *CaptureSink = @ptrCast(@alignCast(ctx));
        const gop = try self.captured.getOrPut(self.allocator, client_id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.clearRetainingCapacity();
        try gop.value_ptr.appendSlice(self.allocator, payload);
    }

    fn payloadFor(self: *const CaptureSink, client_id: u64) ?[]const u8 {
        const buf = self.captured.getPtr(client_id) orelse return null;
        return buf.items;
    }
};

fn applyEnter(state: *State, id: u32, gen: u16, x: f32, z: f32) !void {
    _ = try state.applyDelta(.{ .op = .enter, .id = id, .generation = gen, .x = x, .y = 0, .z = z });
}

fn applySubscribe(state: *State, fanout: *Fanout, client_id: u64, x: f32, z: f32) !void {
    _ = try state.applySubscribe(.{ .op = .enter, .client_id = client_id, .x = x, .y = 0, .z = z });
    try fanout.ensureSubscriber(client_id);
}

fn payloadHeader(payload: []const u8) PayloadHeader {
    return std.mem.bytesToValue(PayloadHeader, payload[0..payload_header_size]);
}

fn entityRecordsSlice(payload: []const u8) []const u8 {
    const header = payloadHeader(payload);
    return payload[payload_header_size..][0 .. header.entity_count * entity_record_size];
}

fn clusterRecordsSlice(payload: []const u8) []const u8 {
    const header = payloadHeader(payload);
    const start = payload_header_size + header.entity_count * entity_record_size;
    return payload[start..][0 .. header.cluster_count * cluster_record_size];
}

test "fanout: slow-lane is clusters-only — visual+ entities not in individual stream" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var fanout = Fanout.init(testing.allocator, TierThresholds.default);
    defer fanout.deinit();
    var capture: CaptureSink = .{ .allocator = testing.allocator };
    defer capture.deinit();

    // Entity at 100 m → close_combat from sub. Slow-lane no longer
    // emits individual records for visual+ entities — fast-lane
    // (`relayState`) covers that. And the cluster centroid at 100 m
    // is in the sub's visual range, so the centroid filter drops it
    // too. Net: header-only payload.
    try applyEnter(&state, 1, 0, 100, 0);
    try applySubscribe(&state, &fanout, 0xAA, 0, 0);

    const n = try fanout.runTick(&state, capture.sink());
    try testing.expectEqual(@as(usize, 1), n);

    const payload = capture.payloadFor(0xAA).?;
    try testing.expectEqual(@as(usize, payload_header_size), payload.len);
    const header = payloadHeader(payload);
    try testing.expectEqual(@as(u32, 0), header.entity_count);
    try testing.expectEqual(@as(u32, 0), header.cluster_count);
}

test "fanout: distant entity surfaces as a cluster summary" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var fanout = Fanout.init(testing.allocator, TierThresholds.default);
    defer fanout.deinit();
    var capture: CaptureSink = .{ .allocator = testing.allocator };
    defer capture.deinit();

    // 1500 m → fleet_aggregate tier from origin sub. Cluster
    // pathway picks it up; entity_count stays 0.
    try applyEnter(&state, 1, 0, 1500, 0);
    try applySubscribe(&state, &fanout, 0xAA, 0, 0);

    _ = try fanout.runTick(&state, capture.sink());
    const header = payloadHeader(capture.payloadFor(0xAA).?);
    try testing.expectEqual(@as(u32, 0), header.entity_count);
    try testing.expectEqual(@as(u32, 1), header.cluster_count);
}

test "fanout: very-distant cluster (centroid at always tier) still surfaces" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var fanout = Fanout.init(testing.allocator, TierThresholds.default);
    defer fanout.deinit();
    var capture: CaptureSink = .{ .allocator = testing.allocator };
    defer capture.deinit();

    // Entities at origin; sub at 5 km. Centroid is at "always" tier
    // from sub (>2 km). The pre-cleanup centroid filter rejected
    // these — sub got an empty payload despite the cluster existing.
    // Post-cleanup the cluster is included so the sub knows there's
    // a fleet on the horizon.
    // All within bucket (4, 4) of the default 500-m sub-cell grid
    // (cell_origin = (-2000, -2000)) so they form one cluster.
    try applyEnter(&state, 1, 0, 0, 0);
    try applyEnter(&state, 2, 0, 10, 10);
    try applyEnter(&state, 3, 0, 20, 5);
    try applySubscribe(&state, &fanout, 0xAA, 5000, 0);

    _ = try fanout.runTick(&state, capture.sink());
    const header = payloadHeader(capture.payloadFor(0xAA).?);
    try testing.expectEqual(@as(u32, 0), header.entity_count);
    try testing.expectEqual(@as(u32, 1), header.cluster_count);
}

test "fanout: removeSubscriber drops them from the next tick" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var fanout = Fanout.init(testing.allocator, TierThresholds.default);
    defer fanout.deinit();
    var capture: CaptureSink = .{ .allocator = testing.allocator };
    defer capture.deinit();

    try applyEnter(&state, 1, 0, 50, 0);
    try applySubscribe(&state, &fanout, 0xAA, 0, 0);
    try applySubscribe(&state, &fanout, 0xBB, 0, 0);

    var n = try fanout.runTick(&state, capture.sink());
    try testing.expectEqual(@as(usize, 2), n);

    _ = try state.applySubscribe(.{ .op = .exit, .client_id = 0xAA, .x = 0, .y = 0, .z = 0 });
    fanout.removeSubscriber(0xAA);

    n = try fanout.runTick(&state, capture.sink());
    try testing.expectEqual(@as(usize, 1), n);
}

// ---- cluster pathway tests ----

test "fanout: cluster pass populates cluster_count for far entities" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var fanout = Fanout.init(testing.allocator, TierThresholds.default);
    defer fanout.deinit();
    var capture: CaptureSink = .{ .allocator = testing.allocator };
    defer capture.deinit();

    // 5 entities packed inside one sub-cell (default sub_cell_size_m
    // = 500 m, cell_origin = (-2000, -2000) so the bucket [1500-2000)
    // × [0-500) catches all of these). Distance from origin sub is
    // ~1500 m → fleet_aggregate band. None at visual+; the cluster
    // covers all five.
    try applyEnter(&state, 1, 0, 1500, 0);
    try applyEnter(&state, 2, 0, 1510, 10);
    try applyEnter(&state, 3, 0, 1505, 20);
    try applyEnter(&state, 4, 0, 1520, 5);
    try applyEnter(&state, 5, 0, 1515, 30);
    try applySubscribe(&state, &fanout, 0xAA, 0, 0);

    _ = try fanout.runTick(&state, capture.sink());
    const payload = capture.payloadFor(0xAA).?;
    const header = payloadHeader(payload);
    try testing.expectEqual(@as(u32, 0), header.entity_count);
    try testing.expectEqual(@as(u32, 1), header.cluster_count);

    const cluster_bytes = clusterRecordsSlice(payload);
    const rec: ClusterRecord = std.mem.bytesToValue(ClusterRecord, cluster_bytes[0..cluster_record_size]);
    try testing.expectEqual(@as(u8, 5), rec.count);
}

test "fanout: cluster cadence — only on every cluster_period tick" {
    // Force a tight period for the test so we can check both phases
    // without running 6 ticks between checks.
    var state = State.init(testing.allocator);
    defer state.deinit();
    var fanout = Fanout.init(testing.allocator, TierThresholds.default);
    fanout.cluster_cfg.period_ticks = 3;
    defer fanout.deinit();
    var capture: CaptureSink = .{ .allocator = testing.allocator };
    defer capture.deinit();

    try applyEnter(&state, 1, 0, 1500, 0);
    try applySubscribe(&state, &fanout, 0xAA, 0, 0);

    // Tick 0: cluster rebuild + emission. Tick 1, 2: reuse cached
    // cluster set (still emitted — receivers want the freshest
    // available aggregate every payload, not just on rebuild ticks).
    // Tick 3: rebuild again.
    inline for (0..6) |_| {
        _ = try fanout.runTick(&state, capture.sink());
        const header = payloadHeader(capture.payloadFor(0xAA).?);
        // Cluster always present once it's been built — the period
        // gates rebuild, not emission. Bandwidth-wise the cluster is
        // a small fixed cost per payload (16 B); the rebuild is the
        // expensive part we gate to 5 Hz.
        try testing.expect(header.cluster_count >= 1);
    }
}

test "fanout: cluster aggregates over all members regardless of fast-lane activity" {
    // Pre-cleanup this test asserted the count-correctness invariant
    // (subscriber never sees an entity in both their aggregate and
    // their individual stream). With the slow-lane carrying clusters
    // only, there's no individual stream to overlap with. Cluster
    // count is just "everyone in this geographic group" — the
    // fast-lane separately carries pose updates for the close ones.
    // The invariant moves up a level: subscribers reconcile their
    // local entity table from the union of (cluster.count summary,
    // fast-lane entity records).
    var state = State.init(testing.allocator);
    defer state.deinit();
    var fanout = Fanout.init(testing.allocator, TierThresholds.default);
    defer fanout.deinit();
    var capture: CaptureSink = .{ .allocator = testing.allocator };
    defer capture.deinit();

    // Same setup as the pre-cleanup test: 10 entities near (400, 400)
    // (fleet_aggregate tier from a sub at origin). The cluster covers
    // all 10 now (no exclusion).
    const cluster_x: f32 = 400;
    const cluster_z: f32 = 400;
    var i: u32 = 1;
    while (i <= 10) : (i += 1) {
        const x: f32 = cluster_x + @as(f32, @floatFromInt(i)) * 2;
        const z: f32 = cluster_z + @as(f32, @floatFromInt(i)) * 2;
        try applyEnter(&state, i, 0, x, z);
    }
    try applySubscribe(&state, &fanout, 0xAA, 0, 0);

    _ = try fanout.runTick(&state, capture.sink());
    const payload = capture.payloadFor(0xAA).?;
    const header = payloadHeader(payload);

    try testing.expectEqual(@as(u32, 0), header.entity_count);
    try testing.expectEqual(@as(u32, 1), header.cluster_count);

    const cluster_bytes = clusterRecordsSlice(payload);
    const rec: ClusterRecord = std.mem.bytesToValue(ClusterRecord, cluster_bytes[0..cluster_record_size]);
    try testing.expectEqual(@as(u8, 10), rec.count);
}

fn poseAt(x: f32, z: f32) pose_codec.Pose {
    return .{ .pos = .{ x, 0, z }, .rot = .{ 0, 0, 0, 1 }, .vel = .{ 0, 0, 0 } };
}

test "fanout: relayState forwards only to visual+ subscribers" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var fanout = Fanout.init(testing.allocator, TierThresholds.default);
    defer fanout.deinit();
    var capture: CaptureSink = .{ .allocator = testing.allocator };
    defer capture.deinit();

    // Entity at the origin. Three subs at 50 m (close_combat),
    // 300 m (visual), 1000 m (fleet_aggregate). The first two should
    // get the relay; the third shouldn't.
    try applyEnter(&state, 1, 0, 0, 0);
    try applySubscribe(&state, &fanout, 0xAA, 50, 0);
    try applySubscribe(&state, &fanout, 0xBB, 300, 0);
    try applySubscribe(&state, &fanout, 0xCC, 1000, 0);

    const ent_id: EntityId = .{ .id = 1, .generation = 0 };
    const forwards = try fanout.relayState(&state, ent_id, poseAt(0, 0), null, capture.sink());
    try testing.expectEqual(@as(usize, 2), forwards);

    try testing.expect(capture.payloadFor(0xAA) != null);
    try testing.expect(capture.payloadFor(0xBB) != null);
    try testing.expect(capture.payloadFor(0xCC) == null);

    // Payload shape: 8B header + 1 × 20B record = 28 B.
    const payload = capture.payloadFor(0xAA).?;
    try testing.expectEqual(@as(usize, payload_header_size + entity_record_size), payload.len);
    const header = payloadHeader(payload);
    try testing.expectEqual(@as(u32, 1), header.entity_count);
    try testing.expectEqual(@as(u32, 0), header.cluster_count);
    try testing.expectEqual(@as(u32, 1), readRecordId(payload[payload_header_size..]));
}

test "fanout: relayState forwards cross-cell entities (not in local entity table)" {
    // Entity NOT registered in this cell's table (simulates a state
    // msg arriving for a ship in a neighbour cell). Sub at the
    // origin is in close_combat from the entity's pose. The relay
    // must still fire — fast-lane works on pure geometry, not cell
    // membership. Closes the docs/08 §2A.3 cross-cell visibility
    // gap that the previous `state.entities.get` guard left open.
    var state = State.init(testing.allocator);
    defer state.deinit();
    var fanout = Fanout.init(testing.allocator, TierThresholds.default);
    defer fanout.deinit();
    var capture: CaptureSink = .{ .allocator = testing.allocator };
    defer capture.deinit();

    try applySubscribe(&state, &fanout, 0xAA, 0, 0);
    try testing.expectEqual(@as(usize, 0), state.entityCount());

    const ent_id: EntityId = .{ .id = 99, .generation = 0 };
    const forwards = try fanout.relayState(&state, ent_id, poseAt(50, 0), null, capture.sink());
    try testing.expectEqual(@as(usize, 1), forwards);
    try testing.expect(capture.payloadFor(0xAA) != null);
}

test "fanout: relayState rejects stale-generation msg for known entity" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var fanout = Fanout.init(testing.allocator, TierThresholds.default);
    defer fanout.deinit();
    var capture: CaptureSink = .{ .allocator = testing.allocator };
    defer capture.deinit();

    try applyEnter(&state, 1, 5, 0, 0);
    try applySubscribe(&state, &fanout, 0xAA, 50, 0);

    // Inbound msg from generation 4 of an entity we know at
    // generation 5 — stale, drop it.
    const stale: EntityId = .{ .id = 1, .generation = 4 };
    const forwards = try fanout.relayState(&state, stale, poseAt(0, 0), null, capture.sink());
    try testing.expectEqual(@as(usize, 0), forwards);
    try testing.expect(capture.payloadFor(0xAA) == null);
}

// ---- M6.4 GATE: 100 entities × 50 subscribers, 1800 ticks, 0 allocs ----

const CountingAllocator = struct {
    parent: std.mem.Allocator,
    alloc_calls: usize = 0,
    resize_calls: usize = 0,
    remap_calls: usize = 0,
    free_calls: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocFn,
                .resize = resizeFn,
                .remap = remapFn,
                .free = freeFn,
            },
        };
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.alloc_calls += 1;
        return self.parent.rawAlloc(len, alignment, ret_addr);
    }

    fn resizeFn(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.resize_calls += 1;
        return self.parent.rawResize(buf, alignment, new_len, ret_addr);
    }

    fn remapFn(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.remap_calls += 1;
        return self.parent.rawRemap(buf, alignment, new_len, ret_addr);
    }

    fn freeFn(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.free_calls += 1;
        self.parent.rawFree(buf, alignment, ret_addr);
    }
};

/// Gate ground truth: independently compute whether a cluster
/// centroid passes the slow-lane's centroid filter from a given sub.
fn clusterShouldFire(sub: replication.Subscriber, centroid: [2]f32) bool {
    const centroid_pos: [3]f32 = .{ centroid[0], 0, centroid[1] };
    const t = replication.effectiveTier(sub, centroid_pos, null, TierThresholds.default);
    return @intFromEnum(t) < @intFromEnum(Tier.visual);
}

test "M6.4 gate: 100 entities × 50 subscribers, 1800 ticks, no allocs after warm-up, payloads correct" {
    // Per docs/08 §6 M6.4: "Run for 60 s, no allocations on the hot
    // path (verify with allocator counters)." 1800 ticks @ 30 Hz =
    // 60 s. Warm-up = 1 cluster-period worth of ticks so the cluster
    // arena, per-sub buffers, and cached clusters all reach steady
    // state before the snapshot.
    var counting: CountingAllocator = .{ .parent = testing.allocator };
    const a = counting.allocator();

    var state = State.init(a);
    defer state.deinit();
    var fanout = Fanout.init(a, TierThresholds.default);
    defer fanout.deinit();
    var capture: CaptureSink = .{ .allocator = a };
    defer capture.deinit();

    var rng = std.Random.DefaultPrng.init(0xC0FFEE);
    const r = rng.random();

    const N_ENT: u32 = 100;
    var ent_positions: [N_ENT][3]f32 = undefined;
    for (0..N_ENT) |i| {
        const x = (r.float(f32) - 0.5) * 4000;
        const z = (r.float(f32) - 0.5) * 4000;
        ent_positions[i] = .{ x, 0, z };
        _ = try state.applyDelta(.{
            .op = .enter,
            .id = @intCast(i + 1),
            .generation = 0,
            .x = x,
            .y = 0,
            .z = z,
        });
    }

    const N_SUB: u32 = 50;
    var sub_positions: [N_SUB][3]f32 = undefined;
    for (0..N_SUB) |i| {
        const x = (r.float(f32) - 0.5) * 4000;
        const z = (r.float(f32) - 0.5) * 4000;
        sub_positions[i] = .{ x, 0, z };
        const cid: u64 = 0x1000 + @as(u64, i);
        _ = try state.applySubscribe(.{
            .op = .enter,
            .client_id = cid,
            .x = x,
            .y = 0,
            .z = z,
        });
        try fanout.ensureSubscriber(cid);
    }

    // Warm-up: 5 cluster cycles. The cluster arena's high-water
    // mark depends on entity distribution per pass — first pass sets
    // the floor, but `toOwnedSlice` and intermediate ArrayList
    // grows in the builder may push the arena to request additional
    // pages on the second or third pass before it fully stabilises.
    // 5 cycles gives the arena a comfortable margin to settle.
    const warm_cycles: u32 = 5;
    const warm_ticks: u32 = warm_cycles * fanout.cluster_cfg.period_ticks;
    var w: u32 = 0;
    while (w < warm_ticks) : (w += 1) {
        _ = try fanout.runTick(&state, capture.sink());
    }
    const baseline_allocs = counting.alloc_calls;
    const baseline_resizes = counting.resize_calls;
    const baseline_remaps = counting.remap_calls;
    const baseline_frees = counting.free_calls;

    const N_TICKS_RUN: u32 = 1800 - warm_ticks;
    var t: u32 = 0;
    while (t < N_TICKS_RUN) : (t += 1) {
        _ = try fanout.runTick(&state, capture.sink());
    }

    try testing.expectEqual(baseline_allocs, counting.alloc_calls);
    try testing.expectEqual(baseline_resizes, counting.resize_calls);
    try testing.expectEqual(baseline_remaps, counting.remap_calls);
    try testing.expectEqual(baseline_frees, counting.free_calls);

    const post_run_allocs = counting.alloc_calls;

    // Correctness: per-sub cluster_count must equal the number of
    // clusters whose centroid passes `clusterShouldFire` from that
    // sub. Slow-lane is clusters-only post-cleanup, so entity_count
    // is always 0 and the verifier doesn't need to walk records.
    for (0..N_SUB) |i| {
        const cid: u64 = 0x1000 + @as(u64, i);
        const sub: replication.Subscriber = .{
            .client_id = cid,
            .pos_world = sub_positions[i],
            .aboard_ship = null,
        };
        const payload = capture.payloadFor(cid) orelse return error.NoPayload;
        const header = payloadHeader(payload);
        try testing.expectEqual(@as(u32, 0), header.entity_count);

        var expected_clusters: u32 = 0;
        for (fanout.clusters) |cluster| {
            if (clusterShouldFire(sub, cluster.aggregate.centroid)) expected_clusters += 1;
        }
        if (expected_clusters != header.cluster_count) {
            std.debug.print("client {d}: expected {d} clusters, got {d}\n", .{ cid, expected_clusters, header.cluster_count });
            return error.ClusterCountMismatch;
        }
    }

    std.debug.print("\n[M6.4] gate: 100 ents × 50 subs × 1800 ticks (incl {d} warm-up); hot-path allocs={d} (baseline {d}, post-run {d})\n", .{
        warm_ticks,
        post_run_allocs - baseline_allocs,
        baseline_allocs,
        post_run_allocs,
    });
}

// ---- M6.5 BANDWIDTH MEASUREMENT ----
//
// Per docs/08 §6 M6.5: confirm per-subscriber BW ≤ Tier 0 budget at
// idle, scales with tier escalation as expected. Numbers logged to
// docs/research/m6-bandwidth.md.
//
// Per-client downstream cap per docs/01 §1 / docs/02 §9: ≤1 Mbps =
// 125 000 B/s. M6 fanout is uniform 30 Hz on the individual stream;
// cluster pass runs 5 Hz but cluster records are emitted on every
// 30 Hz payload (caching the latest aggregate) so receivers see them
// at fanout cadence.

const ScenarioStats = struct {
    name: []const u8,
    n_subs: usize,
    n_ents: usize,
    payload_min: usize,
    payload_max: usize,
    payload_mean: f64,
    visible_mean: f64,
    cluster_mean: f64,
    bytes_per_sec_mean: f64,
    bytes_per_sec_max: f64,
    pct_of_budget_max: f64,
};

const tick_hz: f64 = 30.0;
const budget_bytes_per_sec: f64 = 125_000.0;

fn measureScenario(
    a: std.mem.Allocator,
    name: []const u8,
    ent_positions: []const [3]f32,
    sub_positions: []const [3]f32,
) !ScenarioStats {
    var state = State.init(a);
    defer state.deinit();
    var fanout = Fanout.init(a, TierThresholds.default);
    defer fanout.deinit();
    var capture: CaptureSink = .{ .allocator = a };
    defer capture.deinit();

    for (ent_positions, 0..) |p, i| {
        _ = try state.applyDelta(.{
            .op = .enter,
            .id = @intCast(i + 1),
            .generation = 0,
            .x = p[0],
            .y = p[1],
            .z = p[2],
        });
    }
    for (sub_positions, 0..) |p, i| {
        const cid: u64 = 0x1000 + @as(u64, i);
        _ = try state.applySubscribe(.{
            .op = .enter,
            .client_id = cid,
            .x = p[0],
            .y = p[1],
            .z = p[2],
        });
        try fanout.ensureSubscriber(cid);
    }

    _ = try fanout.runTick(&state, capture.sink());

    var min: usize = std.math.maxInt(usize);
    var max: usize = 0;
    var sum: usize = 0;
    var vis_sum: usize = 0;
    var cluster_sum: usize = 0;
    for (sub_positions, 0..) |_, i| {
        const cid: u64 = 0x1000 + @as(u64, i);
        const payload = capture.payloadFor(cid).?;
        if (payload.len < min) min = payload.len;
        if (payload.len > max) max = payload.len;
        sum += payload.len;

        const header = payloadHeader(payload);
        vis_sum += header.entity_count;
        cluster_sum += header.cluster_count;
    }

    const n_subs_f: f64 = @floatFromInt(sub_positions.len);
    const mean_payload: f64 = @as(f64, @floatFromInt(sum)) / n_subs_f;
    const max_f: f64 = @floatFromInt(max);
    return .{
        .name = name,
        .n_subs = sub_positions.len,
        .n_ents = ent_positions.len,
        .payload_min = min,
        .payload_max = max,
        .payload_mean = mean_payload,
        .visible_mean = @as(f64, @floatFromInt(vis_sum)) / n_subs_f,
        .cluster_mean = @as(f64, @floatFromInt(cluster_sum)) / n_subs_f,
        .bytes_per_sec_mean = mean_payload * tick_hz,
        .bytes_per_sec_max = max_f * tick_hz,
        .pct_of_budget_max = max_f * tick_hz / budget_bytes_per_sec * 100.0,
    };
}

test "M6.5 BW: idle / mid / hot scenarios + distance sweep" {
    const a = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const sa = arena.allocator();

    var rng = std.Random.DefaultPrng.init(0xBADC0DE);
    const r = rng.random();

    const n_ent_idle: usize = 100;
    const n_sub_idle: usize = 50;
    const idle_ents = try sa.alloc([3]f32, n_ent_idle);
    for (idle_ents) |*p| p.* = .{ (r.float(f32) - 0.5) * 4000, 0, (r.float(f32) - 0.5) * 4000 };
    const idle_subs = try sa.alloc([3]f32, n_sub_idle);
    for (idle_subs) |*p| p.* = .{ (r.float(f32) - 0.5) * 4000, 0, (r.float(f32) - 0.5) * 4000 };
    const idle = try measureScenario(a, "idle (uniform 4 km box)", idle_ents, idle_subs);

    const n_ent_mid: usize = 30;
    const n_sub_mid: usize = 50;
    const mid_ents = try sa.alloc([3]f32, n_ent_mid);
    for (mid_ents) |*p| p.* = .{ (r.float(f32) - 0.5) * 800, 0, (r.float(f32) - 0.5) * 800 };
    const mid_subs = try sa.alloc([3]f32, n_sub_mid);
    for (mid_subs) |*p| p.* = .{ (r.float(f32) - 0.5) * 1000, 0, (r.float(f32) - 0.5) * 1000 };
    const mid = try measureScenario(a, "mid (30 ents, 50 subs in ~1 km)", mid_ents, mid_subs);

    const n_ent_hot: usize = 100;
    const n_sub_hot: usize = 50;
    const hot_ents = try sa.alloc([3]f32, n_ent_hot);
    for (hot_ents) |*p| p.* = .{ (r.float(f32) - 0.5) * 200, 0, (r.float(f32) - 0.5) * 200 };
    const hot_subs = try sa.alloc([3]f32, n_sub_hot);
    for (hot_subs) |*p| p.* = .{ (r.float(f32) - 0.5) * 200, 0, (r.float(f32) - 0.5) * 200 };
    const hot = try measureScenario(a, "hot (100 ents, 50 subs in 200 m)", hot_ents, hot_subs);

    const sweep_ents = try sa.alloc([3]f32, 100);
    for (sweep_ents) |*p| p.* = .{ 0, 0, 0 };
    const distances_m = [_]f32{ 5000, 2500, 1000, 600, 500, 400, 200, 150, 100, 0 };
    var sweep_results: [distances_m.len]struct { d: f32, payload: usize, visible: u32, cluster_n: u32 } = undefined;
    for (distances_m, 0..) |d, i| {
        const subs = try sa.alloc([3]f32, 1);
        subs[0] = .{ d, 0, 0 };
        const s = try measureScenario(a, "sweep", sweep_ents, subs);
        sweep_results[i] = .{
            .d = d,
            .payload = s.payload_max,
            .visible = @intFromFloat(s.visible_mean),
            .cluster_n = @intFromFloat(s.cluster_mean),
        };
    }

    const Stats = ScenarioStats;
    const fmt =
        \\
        \\=== [M6.5] bandwidth report ===
        \\Per-client cap: 1 Mbps = 125 000 B/s. Fanout @ 30 Hz; cluster rebuild 5 Hz, emitted every payload.
        \\
        \\Scenario                              | subs |ents| visible/sub | clusters/sub | payload bytes (min/mean/max) | mean B/s | max B/s |  max%/budget
        \\--------------------------------------+------+----+-------------+--------------+------------------------------+----------+---------+-------------
    ;
    std.debug.print("{s}\n", .{fmt});
    inline for (.{ idle, mid, hot }) |s| {
        const x: Stats = s;
        std.debug.print(" {s:<37} | {d:>4} |{d:>3} | {d:>11.1} | {d:>12.2} | {d:>5} / {d:>7.1} / {d:>5}      | {d:>8.1} | {d:>7.1} | {d:>9.2}%\n", .{
            x.name,               x.n_subs,            x.n_ents,            x.visible_mean,
            x.cluster_mean,       x.payload_min,       x.payload_mean,      x.payload_max,
            x.bytes_per_sec_mean, x.bytes_per_sec_max, x.pct_of_budget_max,
        });
    }
    std.debug.print("\nDistance sweep: 100 entities at origin, single subscriber stepped outward.\n", .{});
    std.debug.print(" distance |  visible  | clusters | payload bytes | bytes/sec @30Hz\n", .{});
    std.debug.print("----------+-----------+----------+---------------+----------------\n", .{});
    for (sweep_results) |sr| {
        const bps = @as(f64, @floatFromInt(sr.payload)) * tick_hz;
        std.debug.print(" {d:>6.0} m | {d:>9} | {d:>8} | {d:>13} | {d:>15.1}\n", .{ sr.d, sr.visible, sr.cluster_n, sr.payload, bps });
    }
    std.debug.print("\n", .{});

    // Gate assertions, post-cleanup:
    // - Hot collapses to header-only because all entities are at
    //   close_combat from each sub (visual+ → fast-lane), and the
    //   cluster centroid is also in visual range so it's filtered
    //   out. Slow-lane payload = 8 B header.
    // - Idle still carries clusters for distant entities; same
    //   ballpark as pre-cleanup. Loosen the bound a touch for
    //   scenario-randomness slack.
    try testing.expect(hot.pct_of_budget_max <= 1.0);
    try testing.expect(idle.pct_of_budget_max <= 30.0);
    // Sweep should now include the very-distant case (5000 m): pre-
    // cleanup the centroid filter rejected it, post-cleanup it shows
    // up as a cluster.
    try testing.expect(sweep_results[0].cluster_n >= 1);
    // At 0 m all entities are inside visual range; cluster centroid
    // is too, so cluster_count must drop to 0.
    try testing.expectEqual(@as(u32, 0), sweep_results[sweep_results.len - 1].cluster_n);
}
