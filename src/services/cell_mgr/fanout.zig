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
const replication = @import("notatlas").replication;

const State = @import("state.zig").State;

pub const Tier = replication.Tier;
pub const TierThresholds = replication.TierThresholds;

// ---- wire payload shapes ----

/// Per-entity record in a subscriber's per-tick payload. `extern
/// struct` for a stable, alignment-safe layout we can `@memcpy`
/// straight into the output buffer.
pub const EntityRecord = extern struct {
    id: u32,
    generation: u16,
    /// Effective tier for this subscriber × entity. M6.4 only writes
    /// records for tier ≥ visual; receivers can still read the byte.
    tier: u8,
    _pad: u8 = 0,
    pos: [3]f32,
};
pub const entity_record_size: usize = @sizeOf(EntityRecord);

comptime {
    // 20 bytes is the budget assumed by initial_capacity below — a
    // surprise size change would silently undersize buffers.
    std.debug.assert(entity_record_size == 20);
}

/// Header prepended to each subscriber payload.
pub const PayloadHeader = extern struct {
    count: u32,
};
pub const payload_header_size: usize = @sizeOf(PayloadHeader);

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

                const rec: EntityRecord = .{
                    .id = ent.id.id,
                    .generation = ent.id.generation,
                    .tier = @intFromEnum(tier),
                    .pos = ent.pos,
                };
                const rec_bytes = std.mem.asBytes(&rec);
                try buf_ptr.appendSlice(self.allocator, rec_bytes);
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

test "fanout: tier ordering — close_combat at 50m, visual at 300m" {
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

    // Walk both records; verify each entity got its expected tier.
    var saw_close: bool = false;
    var saw_visual: bool = false;
    var i: usize = 0;
    while (i < records_bytes.len) : (i += entity_record_size) {
        const rec: EntityRecord = std.mem.bytesToValue(EntityRecord, records_bytes[i..][0..entity_record_size]);
        if (rec.id == 1) {
            try testing.expectEqual(@intFromEnum(Tier.close_combat), rec.tier);
            saw_close = true;
        } else if (rec.id == 2) {
            try testing.expectEqual(@intFromEnum(Tier.visual), rec.tier);
            saw_visual = true;
        }
    }
    try testing.expect(saw_close and saw_visual);
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

        // Build expected = { ent_id → expected_tier } for sub i.
        var expected: std.AutoHashMapUnmanaged(u32, Tier) = .empty;
        defer expected.deinit(a);
        for (0..N_ENT) |j| {
            const expected_tier = expectedTierFor(sub, ent_positions[j], null) orelse continue;
            try expected.put(a, @intCast(j + 1), expected_tier);
        }

        // Walk the captured records; tick off each one against the
        // expected set. Anything left over = false negative; anything
        // extra in the payload = false positive.
        var seen: u32 = 0;
        var k: usize = 0;
        while (k < records_bytes.len) : (k += entity_record_size) {
            const rec: EntityRecord = std.mem.bytesToValue(EntityRecord, records_bytes[k..][0..entity_record_size]);
            const exp_tier = expected.get(rec.id) orelse {
                std.debug.print("client {d}: payload contains entity {d} that should not be visible\n", .{ cid, rec.id });
                return error.UnexpectedEntityInPayload;
            };
            try testing.expectEqual(@intFromEnum(exp_tier), rec.tier);
            seen += 1;
            _ = expected.remove(rec.id);
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
