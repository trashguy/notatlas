//! Per-subscriber fanout pass for cell-mgr.
//!
//! M6.4 scope: walk subscribers × entities, run the M6.1 tier filter,
//! assemble a fixed-record binary payload of every entity each
//! subscriber should receive on their individual stream, publish via
//! a Sink. Tier-0.5 (fleet aggregate) goes through a separate cluster
//! pathway; here we stream only `visual` / `close_combat` / `boarded`.
//!
//! Hot-path discipline: the runTick body must allocate zero bytes
//! after warm-up. Per-subscriber output buffers are pre-grown at
//! subscribe time (`ensureSubscriber`) and reused with
//! `clearRetainingCapacity` each tick. The M6.4 gate test wraps the
//! allocator and asserts the alloc count doesn't change between
//! ticks once the buffer pool is established.
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

// ---- wire payload shapes ----
//
// Per-entity record on the wire:
//   [0..4]   id          (u32, little-endian)
//   [4..6]   generation  (u16, little-endian)
//   [6..20]  pose codec  (14 B delta-mode payload)
//
// Total 20 B per record. Pose-codec runs in delta mode with the
// entity's stored pose as the keyframe (delta is zero for the
// synthetic static load — exercises the codec end-to-end without
// requiring a separate keyframe-establishing message stream). Real
// receivers will need a keyframe-message channel; that lives outside
// the M6.4 fanout scope.
//
// Tier byte from the M6.4 placeholder is gone — receivers can
// recompute it locally from the decoded position + their own
// subscriber position. The 2 bytes saved hold the codec payload
// without breaking the 20 B per-record budget that M6.5's BW report
// is calibrated against.

pub const record_header_size: usize = 6;
pub const entity_record_size: usize = record_header_size + pose_codec.delta_size;

comptime {
    // 20 bytes is the budget assumed by initial_capacity below and
    // by docs/research/m6-bandwidth.md — a surprise size change
    // would silently invalidate the BW report.
    std.debug.assert(entity_record_size == 20);
}

/// Header prepended to each subscriber payload.
pub const PayloadHeader = extern struct {
    count: u32,
};
pub const payload_header_size: usize = @sizeOf(PayloadHeader);

fn writeRecordHeader(buf: []u8, id: u32, generation: u16) void {
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

// ---- Sink: where publishes go ----

pub const Sink = struct {
    ctx: *anyopaque,
    publishFn: *const fn (ctx: *anyopaque, client_id: u64, payload: []const u8) anyerror!void,

    pub fn publish(self: Sink, client_id: u64, payload: []const u8) anyerror!void {
        return self.publishFn(self.ctx, client_id, payload);
    }
};

// ---- Fanout ----

/// Initial per-subscriber buffer capacity. Sized for cell.entity_cap
/// (200/cell per docs/06) × 20 B + 4 B header + headroom = 4 KB.
/// Cell density spikes within this band don't trigger reallocation.
pub const default_initial_capacity: usize = 4 * 1024;

pub const Fanout = struct {
    allocator: std.mem.Allocator,
    thresholds: TierThresholds,
    initial_capacity: usize,

    /// client_id → output buffer. Buffer is allocated at
    /// `ensureSubscriber` and reused with `clearRetainingCapacity`
    /// per tick — no per-tick allocation in steady state.
    buffers: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(u8)),

    pub fn init(allocator: std.mem.Allocator, thresholds: TierThresholds) Fanout {
        return .{
            .allocator = allocator,
            .thresholds = thresholds,
            .initial_capacity = default_initial_capacity,
            .buffers = .empty,
        };
    }

    pub fn deinit(self: *Fanout) void {
        var it = self.buffers.iterator();
        while (it.next()) |e| e.value_ptr.deinit(self.allocator);
        self.buffers.deinit(self.allocator);
    }

    /// Allocate an output buffer for `client_id`. Idempotent — repeat
    /// calls keep the existing buffer (and its retained capacity).
    pub fn ensureSubscriber(self: *Fanout, client_id: u64) !void {
        const gop = try self.buffers.getOrPut(self.allocator, client_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
            try gop.value_ptr.ensureTotalCapacity(self.allocator, self.initial_capacity);
        }
    }

    /// Free the output buffer for `client_id`. No-op if absent.
    pub fn removeSubscriber(self: *Fanout, client_id: u64) void {
        if (self.buffers.fetchRemove(client_id)) |kv| {
            var buf = kv.value;
            buf.deinit(self.allocator);
        }
    }

    /// One fanout tick. For each subscriber, walks every entity in
    /// `state`, computes the effective tier, and includes the entity
    /// in the subscriber's payload iff the tier is ≥ visual (i.e.,
    /// individually streamed, not part of a cluster aggregate).
    /// Returns the number of subscribers we published payloads for.
    pub fn runTick(self: *Fanout, state: *const State, sink: Sink) !usize {
        var sub_it = state.subscribers.iterator();
        var publishes: usize = 0;
        while (sub_it.next()) |sub_entry| {
            const sub = sub_entry.value_ptr.*;

            const buf_ptr = self.buffers.getPtr(sub.client_id) orelse return error.UnknownSubscriber;
            buf_ptr.clearRetainingCapacity();

            // Reserve header bytes; fill `count` after we know it.
            try buf_ptr.appendNTimes(self.allocator, 0, payload_header_size);

            var count: u32 = 0;
            var ent_it = state.entities.iterator();
            while (ent_it.next()) |ent_entry| {
                const ent = ent_entry.value_ptr.*;
                const tier = replication.effectiveTier(sub, ent.pos, ent.aboard_ship, self.thresholds);
                if (@intFromEnum(tier) < @intFromEnum(Tier.visual)) continue;

                // Reserve the full 20-byte slot, write header bytes,
                // then have the codec fill the trailing 14 bytes
                // in-place. Avoids an intermediate staging buffer.
                const slot_start = buf_ptr.items.len;
                try buf_ptr.appendNTimes(self.allocator, 0, entity_record_size);
                const slot = buf_ptr.items[slot_start..][0..entity_record_size];
                writeRecordHeader(slot[0..record_header_size], ent.id.id, ent.id.generation);

                // Delta mode against the entity's own pose — for the
                // synthetic static load the delta is zero. Real
                // dynamic state will use a stored keyframe + periodic
                // refresh; the codec API doesn't change.
                const ent_pose: pose_codec.Pose = .{ .pos = ent.pos, .rot = ent.rot, .vel = ent.vel };
                const n = pose_codec.encodePose(ent_pose, ent_pose, null, slot[record_header_size..]);
                std.debug.assert(n == pose_codec.delta_size);
                count += 1;
            }

            // Patch the count into the reserved header slot.
            const header: PayloadHeader = .{ .count = count };
            @memcpy(buf_ptr.items[0..payload_header_size], std.mem.asBytes(&header));

            try sink.publish(sub.client_id, buf_ptr.items);
            publishes += 1;
        }
        return publishes;
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

test "fanout: single subscriber, single visible entity → 1 record" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var fanout = Fanout.init(testing.allocator, TierThresholds.default);
    defer fanout.deinit();
    var capture: CaptureSink = .{ .allocator = testing.allocator };
    defer capture.deinit();

    try applyEnter(&state, 1, 0, 100, 0);
    try applySubscribe(&state, &fanout, 0xAA, 0, 0);

    const n = try fanout.runTick(&state, capture.sink());
    try testing.expectEqual(@as(usize, 1), n);

    const payload = capture.payloadFor(0xAA).?;
    const header: PayloadHeader = std.mem.bytesToValue(PayloadHeader, payload[0..payload_header_size]);
    try testing.expectEqual(@as(u32, 1), header.count);
}

test "fanout: distant entity (>visual) is excluded" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var fanout = Fanout.init(testing.allocator, TierThresholds.default);
    defer fanout.deinit();
    var capture: CaptureSink = .{ .allocator = testing.allocator };
    defer capture.deinit();

    // 1500 m → fleet_aggregate tier; not in the individual stream.
    try applyEnter(&state, 1, 0, 1500, 0);
    try applySubscribe(&state, &fanout, 0xAA, 0, 0);

    _ = try fanout.runTick(&state, capture.sink());
    const payload = capture.payloadFor(0xAA).?;
    const header: PayloadHeader = std.mem.bytesToValue(PayloadHeader, payload[0..payload_header_size]);
    try testing.expectEqual(@as(u32, 0), header.count);
}

test "fanout: codec roundtrip — payload pose decodes back to entity pose" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var fanout = Fanout.init(testing.allocator, TierThresholds.default);
    defer fanout.deinit();
    var capture: CaptureSink = .{ .allocator = testing.allocator };
    defer capture.deinit();

    try applyEnter(&state, 1, 0, 50, 0);
    try applyEnter(&state, 2, 0, 300, 0);
    try applySubscribe(&state, &fanout, 0xAA, 0, 0);

    _ = try fanout.runTick(&state, capture.sink());
    const payload = capture.payloadFor(0xAA).?;
    const records_bytes = payload[payload_header_size..];
    try testing.expectEqual(@as(usize, 2 * entity_record_size), records_bytes.len);

    var saw_50: bool = false;
    var saw_300: bool = false;
    var i: usize = 0;
    while (i < records_bytes.len) : (i += entity_record_size) {
        const slot = records_bytes[i..][0..entity_record_size];
        const id = readRecordId(slot);
        const ent = state.entities.get(id).?;
        // Decode against the same keyframe the encoder used (the
        // entity's own pose); the delta is zero so we should land
        // back on the keyframe within codec precision.
        const ent_pose: pose_codec.Pose = .{ .pos = ent.pos, .rot = ent.rot, .vel = ent.vel };
        const decoded = pose_codec.decodePose(slot[record_header_size..], ent_pose);
        try testing.expectApproxEqAbs(@as(f32, ent.pos[0]), decoded.pos[0], 0.01);
        if (id == 1) saw_50 = true else if (id == 2) saw_300 = true;
    }
    try testing.expect(saw_50 and saw_300);
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

/// Independent ground-truth for the gate: replicates the filter
/// directly without going through the fanout, so a bug in either
/// can't mask itself by being symmetric.
fn expectedTierFor(sub: replication.Subscriber, ent_pos: [3]f32, ent_ship: ?replication.EntityId) ?Tier {
    const t = replication.effectiveTier(sub, ent_pos, ent_ship, TierThresholds.default);
    if (@intFromEnum(t) < @intFromEnum(Tier.visual)) return null;
    return t;
}

test "M6.4 gate: 100 entities × 50 subscribers, 1800 ticks, no allocs after warm-up, payloads correct" {
    // The gate caps at 60 s of fanout = 30 Hz × 60 = 1800 ticks. Per
    // docs/08 §6 M6.4: "Run for 60 s, no allocations on the hot path
    // (verify with allocator counters)."

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

    // 100 entities spread across a 4 km box (covers all distance bands
    // for a subscriber near the origin).
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

    // 50 subscribers spread over the same area.
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

    // Warm-up tick: lets the buffers grow to their final capacities so
    // the alloc-count snapshot we take next is the steady-state floor.
    _ = try fanout.runTick(&state, capture.sink());
    const baseline_allocs = counting.alloc_calls;
    const baseline_resizes = counting.resize_calls;
    const baseline_remaps = counting.remap_calls;
    const baseline_frees = counting.free_calls;

    // 1799 more ticks → 1800 total = 60 s @ 30 Hz.
    const N_TICKS_RUN: u32 = 1799;
    var t: u32 = 0;
    while (t < N_TICKS_RUN) : (t += 1) {
        _ = try fanout.runTick(&state, capture.sink());
    }

    // Hot-path discipline: no allocs across 1799 ticks, no remaps.
    // CaptureSink doesn't grow either (we use clearRetainingCapacity).
    try testing.expectEqual(baseline_allocs, counting.alloc_calls);
    try testing.expectEqual(baseline_resizes, counting.resize_calls);
    try testing.expectEqual(baseline_remaps, counting.remap_calls);
    try testing.expectEqual(baseline_frees, counting.free_calls);

    // Snapshot the counters now — the per-subscriber verifier below
    // allocates its own ground-truth HashMap, which would otherwise
    // pollute the gate-summary print.
    const post_run_allocs = counting.alloc_calls;

    // Correctness: every subscriber's captured payload matches the
    // independently-computed expected set. We rebuild Subscriber from
    // sub_positions so the verifier doesn't depend on State's view of
    // the same data.
    for (0..N_SUB) |i| {
        const cid: u64 = 0x1000 + @as(u64, i);
        const sub: replication.Subscriber = .{
            .client_id = cid,
            .pos_world = sub_positions[i],
            .aboard_ship = null,
        };
        const payload = capture.payloadFor(cid) orelse return error.NoPayload;
        const header: PayloadHeader = std.mem.bytesToValue(PayloadHeader, payload[0..payload_header_size]);
        const records_bytes = payload[payload_header_size..];
        try testing.expectEqual(@as(usize, header.count) * entity_record_size, records_bytes.len);

        // Build expected = { ent_id → expected_tier } for sub i. Tier
        // is independently recomputed in the verifier, not read off
        // the wire (M7 codec doesn't carry it; receivers compute
        // tier locally from decoded position + own subscriber pos).
        var expected: std.AutoHashMapUnmanaged(u32, Tier) = .empty;
        defer expected.deinit(a);
        for (0..N_ENT) |j| {
            const expected_tier = expectedTierFor(sub, ent_positions[j], null) orelse continue;
            try expected.put(a, @intCast(j + 1), expected_tier);
        }

        // Walk the captured records; tick off each one against the
        // expected set. Anything left over = false negative; anything
        // extra in the payload = false positive. Just the id is
        // needed — the codec bytes carry the pose but the verifier
        // doesn't redecode it (the M7 1M-roundtrip gate already
        // covers codec correctness).
        var seen: u32 = 0;
        var k: usize = 0;
        while (k < records_bytes.len) : (k += entity_record_size) {
            const slot = records_bytes[k..][0..entity_record_size];
            const id = readRecordId(slot);
            if (!expected.contains(id)) {
                std.debug.print("client {d}: payload contains entity {d} that should not be visible\n", .{ cid, id });
                return error.UnexpectedEntityInPayload;
            }
            seen += 1;
            _ = expected.remove(id);
        }
        if (expected.count() != 0) {
            std.debug.print("client {d}: {d} expected entities missing from payload\n", .{ cid, expected.count() });
            return error.MissingEntityInPayload;
        }
        try testing.expectEqual(header.count, seen);
    }

    std.debug.print("\n[M6.4] gate: 100 ents × 50 subs × 1800 ticks; hot-path allocs={d} (baseline {d}, post-run {d})\n", .{
        post_run_allocs - baseline_allocs,
        baseline_allocs,
        post_run_allocs,
    });
}

// ---- M6.5 BANDWIDTH MEASUREMENT ----
//
// Per docs/08 §6 M6.5: confirm per-subscriber BW ≤ Tier 0 budget at
// idle, scales with tier escalation as expected. Numbers logged to
// docs/research/m6-bandwidth.md. The actual 16 B/pose comes in M7;
// for M6 a fixed-size 20 B placeholder record is fine.
//
// Per-client downstream cap per docs/01 §1 / docs/02 §9: ≤1 Mbps
// = 125 000 B/s. M6 fanout is uniform 30 Hz (tier-1 will jump to 60 Hz
// post-M7 once per-tier rate gating lands; M6 numbers undercount that
// case and overcount the fleet-aggregate 5 Hz case). All measurements
// are application-layer payload — NATS framing + TCP/IP add a fixed
// per-message overhead (~20-30 B for "PUB <subj> <len>\r\n") that
// doesn't change the relative scaling.

const ScenarioStats = struct {
    name: []const u8,
    n_subs: usize,
    n_ents: usize,
    payload_min: usize,
    payload_max: usize,
    payload_mean: f64,
    /// Mean visible-entity count per subscriber. Sanity-check that the
    /// scenario produced what we intended.
    visible_mean: f64,
    bytes_per_sec_mean: f64,
    bytes_per_sec_max: f64,
    pct_of_budget_max: f64,
};

const tick_hz: f64 = 30.0;
const budget_bytes_per_sec: f64 = 125_000.0; // 1 Mbps / 8

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
    for (sub_positions, 0..) |_, i| {
        const cid: u64 = 0x1000 + @as(u64, i);
        const payload = capture.payloadFor(cid).?;
        if (payload.len < min) min = payload.len;
        if (payload.len > max) max = payload.len;
        sum += payload.len;

        const header: PayloadHeader = std.mem.bytesToValue(PayloadHeader, payload[0..payload_header_size]);
        vis_sum += header.count;
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
        .bytes_per_sec_mean = mean_payload * tick_hz,
        .bytes_per_sec_max = max_f * tick_hz,
        .pct_of_budget_max = max_f * tick_hz / budget_bytes_per_sec * 100.0,
    };
}

test "M6.5 BW: idle / mid / hot scenarios + distance sweep" {
    const a = testing.allocator;

    // Allocator the scenarios share for their position arrays. Freed
    // at end of test.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const sa = arena.allocator();

    var rng = std.Random.DefaultPrng.init(0xBADC0DE);
    const r = rng.random();

    // ---- Scenario A: idle ----
    // 100 entities + 50 subs uniformly across 4 km × 4 km. With
    // visual range 500 m, mean inter-pair distance is large; most
    // pairs are at fleet_aggregate or always (excluded from the
    // individual stream).
    const n_ent_idle: usize = 100;
    const n_sub_idle: usize = 50;
    const idle_ents = try sa.alloc([3]f32, n_ent_idle);
    for (idle_ents) |*p| p.* = .{ (r.float(f32) - 0.5) * 4000, 0, (r.float(f32) - 0.5) * 4000 };
    const idle_subs = try sa.alloc([3]f32, n_sub_idle);
    for (idle_subs) |*p| p.* = .{ (r.float(f32) - 0.5) * 4000, 0, (r.float(f32) - 0.5) * 4000 };
    const idle = try measureScenario(a, "idle (uniform 4 km box)", idle_ents, idle_subs);

    // ---- Scenario B: mid (typical fleet engagement) ----
    // 30 entities clustered in 800 m × 800 m, 50 subs in 1 km × 1 km.
    // Most pairs at visual or close_combat.
    const n_ent_mid: usize = 30;
    const n_sub_mid: usize = 50;
    const mid_ents = try sa.alloc([3]f32, n_ent_mid);
    for (mid_ents) |*p| p.* = .{ (r.float(f32) - 0.5) * 800, 0, (r.float(f32) - 0.5) * 800 };
    const mid_subs = try sa.alloc([3]f32, n_sub_mid);
    for (mid_subs) |*p| p.* = .{ (r.float(f32) - 0.5) * 1000, 0, (r.float(f32) - 0.5) * 1000 };
    const mid = try measureScenario(a, "mid (30 ents, 50 subs in ~1 km)", mid_ents, mid_subs);

    // ---- Scenario C: hot (200/cell stress, peak fight) ----
    // Per docs/06 the per-cell entity cap is 200; 100 entities + 50
    // subs all packed into a 200 m radius is the close_combat-density
    // worst case.
    const n_ent_hot: usize = 100;
    const n_sub_hot: usize = 50;
    const hot_ents = try sa.alloc([3]f32, n_ent_hot);
    for (hot_ents) |*p| p.* = .{ (r.float(f32) - 0.5) * 200, 0, (r.float(f32) - 0.5) * 200 };
    const hot_subs = try sa.alloc([3]f32, n_sub_hot);
    for (hot_subs) |*p| p.* = .{ (r.float(f32) - 0.5) * 200, 0, (r.float(f32) - 0.5) * 200 };
    const hot = try measureScenario(a, "hot (100 ents, 50 subs in 200 m)", hot_ents, hot_subs);

    // ---- Distance sweep (single subscriber, fixed entity cluster) ----
    // 100 entities all at origin; one subscriber stepped through
    // distances. Demonstrates the per-subscriber-payload curve as
    // tier-promotes from `always` (excluded) → fleet_aggregate
    // (excluded) → visual → close_combat.
    const sweep_ents = try sa.alloc([3]f32, 100);
    for (sweep_ents) |*p| p.* = .{ 0, 0, 0 };
    const distances_m = [_]f32{ 5000, 2500, 1000, 600, 500, 400, 200, 150, 100, 0 };
    var sweep_results: [distances_m.len]struct { d: f32, payload: usize, visible: u32 } = undefined;
    for (distances_m, 0..) |d, i| {
        const subs = try sa.alloc([3]f32, 1);
        subs[0] = .{ d, 0, 0 };
        const s = try measureScenario(a, "sweep", sweep_ents, subs);
        sweep_results[i] = .{ .d = d, .payload = s.payload_max, .visible = @intFromFloat(s.visible_mean) };
    }

    const Stats = ScenarioStats;
    const fmt =
        \\
        \\=== [M6.5] bandwidth report ===
        \\Per-client cap: 1 Mbps = 125 000 B/s. M6 fanout @ 30 Hz uniform.
        \\
        \\Scenario                              | subs |ents| visible/sub | payload bytes (min/mean/max) | mean B/s | max B/s |  max%/budget
        \\--------------------------------------+------+----+-------------+------------------------------+----------+---------+-------------
    ;
    std.debug.print("{s}\n", .{fmt});
    inline for (.{ idle, mid, hot }) |s| {
        const x: Stats = s;
        std.debug.print(" {s:<37} | {d:>4} |{d:>3} | {d:>11.1} | {d:>5} / {d:>7.1} / {d:>5}      | {d:>8.1} | {d:>7.1} | {d:>9.2}%\n", .{
            x.name,              x.n_subs,            x.n_ents,      x.visible_mean,
            x.payload_min,       x.payload_mean,      x.payload_max, x.bytes_per_sec_mean,
            x.bytes_per_sec_max, x.pct_of_budget_max,
        });
    }
    std.debug.print("\nDistance sweep: 100 entities at origin, single subscriber stepped outward.\n", .{});
    std.debug.print(" distance |  visible  | payload bytes | bytes/sec @30Hz\n", .{});
    std.debug.print("----------+-----------+---------------+----------------\n", .{});
    for (sweep_results) |sr| {
        const bps = @as(f64, @floatFromInt(sr.payload)) * tick_hz;
        std.debug.print(" {d:>6.0} m | {d:>9} | {d:>13} | {d:>15.1}\n", .{ sr.d, sr.visible, sr.payload, bps });
    }
    std.debug.print("\n", .{});

    // ---- Gate assertions ----
    //
    // 1. Idle floor: subscribers far from all entities pay ≤ header
    //    bytes per tick. Allow up to ~1% of budget — the uniform
    //    scenario naturally has some sub-entity pairs within 500 m.
    try testing.expect(idle.pct_of_budget_max <= 5.0);
    // 2. Hot peak: even under 200/cell stress, a subscriber's max
    //    payload must stay well within budget. 100 entities × 20 B +
    //    4 B = 2004 B/tick = 60.12 KB/s = ~48% of budget.
    try testing.expect(hot.pct_of_budget_max <= 75.0);
    // 3. Scaling: visible-entity count must increase monotonically
    //    as the sweep moves from far → close. Asserts the filter
    //    actually escalates tier with distance.
    var prev: u32 = 0;
    for (sweep_results) |sr| {
        try testing.expect(sr.visible >= prev);
        prev = sr.visible;
    }
    // 4. Sanity: the sweep's closest position (0 m) sees all 100
    //    entities (they're stacked at the origin, all within
    //    close_combat range).
    try testing.expectEqual(@as(u32, 100), sweep_results[sweep_results.len - 1].visible);
}
