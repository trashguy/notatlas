//! inventory-sim — authoritative in-memory inventory per character.
//! v0 of the last SLA-arc producer (events.session ✅,
//! events.handoff.cell ✅, events.market.trade ✅, events.inventory.change
//! now ✅).
//!
//! v0 scope:
//!   - Single process, `HashMap<character_id, blob>` in memory; no
//!     restart-recovery (deferred — would read PG at boot).
//!   - Inbound subject `inv.mutate` carries `wire.InventoryMutateMsg`
//!     — one message can batch N mutations for a single character.
//!     Survival-sandbox transfers move 1000s of items at once, so
//!     batching at the wire keeps NATS+pwriter pressure linear in
//!     transfers, not in slots.
//!   - On mutation, mark the character dirty. A 100 ms flush tick
//!     publishes one `events.inventory.change.<character_id>` per
//!     dirty character with the full updated `{slots:[...]}` blob.
//!     Caps PG writes at 10/sec/character even under chatty
//!     single-mutation callers.
//!   - pwriter's `handleInventoryChange` takes the published payload
//!     verbatim as JSONB; this service is its only producer.
//!
//! Out of scope for v0:
//!   - Cross-character atomicity (player A → player B transfer is
//!     two separate mutate messages; needs a transfer-record event
//!     stream and a 2-phase shape — Phase 2/3 design work).
//!   - Slot caps / weight / volume / quality tiers. Slots are
//!     unbounded i32 ids; content design hasn't locked.
//!   - Per-character rate limiting beyond the flush cap. Future
//!     defensive ceiling if needed.
//!   - Restart-recovery from PG.

const std = @import("std");
const nats = @import("nats");
const wire = @import("wire");

const flush_period_ns: u64 = 100 * std.time.ns_per_ms; // 10 Hz max per character
const log_interval_ns: u64 = std.time.ns_per_s;

const Args = struct {
    nats_url: []const u8 = "nats://127.0.0.1:4222",
};

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var out: Args = .{};
    var have_nats = false;
    errdefer if (have_nats) allocator.free(out.nats_url);
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--nats")) {
            const v = args.next() orelse return error.MissingArg;
            out.nats_url = try allocator.dupe(u8, v);
            have_nats = true;
        } else {
            std.debug.print("inventory-sim: unknown arg '{s}'\n", .{a});
            return error.BadArg;
        }
    }
    if (!have_nats) out.nats_url = try allocator.dupe(u8, out.nats_url);
    return out;
}

var g_running: std.atomic.Value(bool) = .init(true);

fn handleSignal(_: c_int) callconv(.c) void {
    g_running.store(false, .release);
}

fn installSignalHandlers() !void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = &handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

/// One inventory slot. Mirrors `{"slot":N,"item_def_id":N,"quantity":N}`
/// in the published JSONB blob.
const Slot = struct {
    slot: i32,
    item_def_id: i32,
    quantity: i32,
};

/// Per-character inventory state. Slot list kept sorted by `.slot`
/// so the published JSON is stable (testing diff-friendliness +
/// matches the de-facto shape from `persistence_smoke.sh`).
const Inventory = struct {
    slots: std.ArrayListUnmanaged(Slot) = .{},
    /// True iff a mutation has landed since the last successful flush.
    /// Flush tick clears this.
    dirty: bool = false,

    fn deinit(self: *Inventory, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
    }

    fn findSlotIdx(self: Inventory, slot: i32) ?usize {
        for (self.slots.items, 0..) |s, i| if (s.slot == slot) return i;
        return null;
    }

    fn insertSortedSlot(self: *Inventory, allocator: std.mem.Allocator, new: Slot) !void {
        var idx: usize = 0;
        while (idx < self.slots.items.len and self.slots.items[idx].slot < new.slot) : (idx += 1) {}
        try self.slots.insert(allocator, idx, new);
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    inventories: std.AutoHashMapUnmanaged(i64, Inventory) = .{},

    fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *State) void {
        var it = self.inventories.valueIterator();
        while (it.next()) |inv| inv.deinit(self.allocator);
        self.inventories.deinit(self.allocator);
    }

    fn inventoryPtr(self: *State, character_id: i64) !*Inventory {
        const gop = try self.inventories.getOrPut(self.allocator, character_id);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }
};

/// Apply one mutation to an in-memory inventory. Returns true iff
/// the mutation produced any observable state change; coalescing
/// uses this to keep the dirty bit honest. Bad inputs (negative
/// quantity, unknown op) are silent no-ops — buggy producers
/// shouldn't take down the service.
fn apply(allocator: std.mem.Allocator, inv: *Inventory, m: wire.InventoryMutation) !bool {
    if (m.quantity < 0) return false;
    const existing_idx = inv.findSlotIdx(m.slot);
    switch (m.op) {
        'A' => {
            if (m.quantity == 0) return false;
            if (existing_idx) |i| {
                // Adding to a slot with a different item def is a
                // category error; keep the existing item, drop the
                // mutation. Survival games usually surface this as
                // "stack mismatch" client-side.
                if (inv.slots.items[i].item_def_id != m.item_def_id) return false;
                inv.slots.items[i].quantity += m.quantity;
            } else {
                try inv.insertSortedSlot(allocator, .{
                    .slot = m.slot,
                    .item_def_id = m.item_def_id,
                    .quantity = m.quantity,
                });
            }
            return true;
        },
        'R' => {
            const i = existing_idx orelse return false;
            if (inv.slots.items[i].item_def_id != m.item_def_id) return false;
            const before = inv.slots.items[i].quantity;
            const after = if (m.quantity >= before) 0 else (before - m.quantity);
            if (after == 0) {
                _ = inv.slots.orderedRemove(i);
            } else {
                inv.slots.items[i].quantity = after;
            }
            return before != after;
        },
        'S' => {
            if (m.quantity == 0) {
                if (existing_idx) |i| {
                    _ = inv.slots.orderedRemove(i);
                    return true;
                }
                return false;
            }
            if (existing_idx) |i| {
                const cur = inv.slots.items[i];
                if (cur.item_def_id == m.item_def_id and cur.quantity == m.quantity) return false;
                inv.slots.items[i] = .{
                    .slot = m.slot,
                    .item_def_id = m.item_def_id,
                    .quantity = m.quantity,
                };
                return true;
            }
            try inv.insertSortedSlot(allocator, .{
                .slot = m.slot,
                .item_def_id = m.item_def_id,
                .quantity = m.quantity,
            });
            return true;
        },
        else => return false, // unknown op
    }
}

fn applyBatch(allocator: std.mem.Allocator, inv: *Inventory, mutations: []const wire.InventoryMutation) !void {
    for (mutations) |m| {
        if (try apply(allocator, inv, m)) inv.dirty = true;
    }
}

/// Build the published JSONB blob: `{"slots":[{slot,item_def_id,quantity},...]}`.
/// Matches the shape pwriter sees in `persistence_smoke.sh`.
const Blob = struct { slots: []const Slot };

fn encodeBlob(allocator: std.mem.Allocator, inv: Inventory) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, Blob{ .slots = inv.slots.items }, .{});
}

const PublishSink = struct {
    ctx: *anyopaque,
    publishFn: *const fn (ctx: *anyopaque, character_id: i64, blob: []const u8) anyerror!void,

    fn publish(self: PublishSink, character_id: i64, blob: []const u8) !void {
        return self.publishFn(self.ctx, character_id, blob);
    }
};

/// Walk dirty characters and emit one inventory.change per. Returns
/// the number of publishes. Clears dirty bits on success.
fn flushDirty(state: *State, sink: PublishSink) !u32 {
    var published: u32 = 0;
    var it = state.inventories.iterator();
    while (it.next()) |entry| {
        const inv = entry.value_ptr;
        if (!inv.dirty) continue;
        const blob = try encodeBlob(state.allocator, inv.*);
        defer state.allocator.free(blob);
        try sink.publish(entry.key_ptr.*, blob);
        inv.dirty = false;
        published += 1;
    }
    return published;
}

const NatsSinkCtx = struct {
    client: *nats.Client,

    fn publish(ctx: *anyopaque, character_id: i64, blob: []const u8) anyerror!void {
        const self: *NatsSinkCtx = @ptrCast(@alignCast(ctx));
        var subj_buf: [64]u8 = undefined;
        const subj = try std.fmt.bufPrint(&subj_buf, "events.inventory.change.{d}", .{character_id});
        try self.client.publish(subj, blob);
    }
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);
    defer allocator.free(args.nats_url);
    try installSignalHandlers();

    std.debug.print("inventory-sim: connecting to {s}\n", .{args.nats_url});

    var client = try nats.Client.connect(allocator, .{
        .servers = &.{args.nats_url},
        .name = "inventory-sim",
    });
    defer client.close();

    const sub = try client.subscribe("inv.mutate", .{});
    std.debug.print("inventory-sim: subscribed to inv.mutate\n", .{});

    var state = State.init(allocator);
    defer state.deinit();

    var sink_ctx: NatsSinkCtx = .{ .client = client };
    const sink: PublishSink = .{ .ctx = &sink_ctx, .publishFn = NatsSinkCtx.publish };

    var mutations_since_log: u64 = 0;
    var batches_since_log: u64 = 0;
    var publishes_since_log: u64 = 0;
    var last_flush_ns: u64 = @intCast(std.time.nanoTimestamp());
    var last_log_ns: u64 = last_flush_ns;

    while (g_running.load(.acquire)) {
        try client.processIncomingTimeout(5);
        try client.maybeSendPing();

        while (sub.nextMsg()) |msg| {
            var owned = msg;
            defer owned.deinit();
            const payload = owned.payload orelse continue;
            const parsed = wire.decodeInventoryMutate(allocator, payload) catch |err| {
                std.debug.print("inventory-sim: bad mutate payload ({s}): {s}\n", .{ @errorName(err), payload });
                continue;
            };
            defer parsed.deinit();
            const inv = state.inventoryPtr(parsed.value.character_id) catch |err| {
                std.debug.print("inventory-sim: oom on inventoryPtr ({s})\n", .{@errorName(err)});
                continue;
            };
            applyBatch(allocator, inv, parsed.value.mutations) catch |err| {
                std.debug.print("inventory-sim: apply error ({s})\n", .{@errorName(err)});
                continue;
            };
            mutations_since_log += parsed.value.mutations.len;
            batches_since_log += 1;
        }

        const now_ns: u64 = @intCast(std.time.nanoTimestamp());
        if (now_ns -% last_flush_ns >= flush_period_ns) {
            const n = flushDirty(&state, sink) catch |err| blk: {
                std.debug.print("inventory-sim: flush error ({s})\n", .{@errorName(err)});
                break :blk @as(u32, 0);
            };
            publishes_since_log += n;
            last_flush_ns +%= flush_period_ns;
        }

        if (now_ns -% last_log_ns >= log_interval_ns) {
            std.debug.print(
                "[inventory-sim] {d} batches, {d} mutations, {d} blob publishes / 1 s; {d} characters tracked\n",
                .{ batches_since_log, mutations_since_log, publishes_since_log, state.inventories.count() },
            );
            mutations_since_log = 0;
            batches_since_log = 0;
            publishes_since_log = 0;
            last_log_ns = now_ns;
        }
    }

    // Final flush so a clean shutdown after a mutation doesn't drop
    // the trailing blob update.
    _ = flushDirty(&state, sink) catch {};
    std.debug.print("inventory-sim: shutting down\n", .{});
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------
const testing = std.testing;

const CollectorCtx = struct {
    pubs: std.ArrayListUnmanaged(struct { character_id: i64, blob: []u8 }) = .{},

    fn publish(ctx: *anyopaque, character_id: i64, blob: []const u8) anyerror!void {
        const self: *CollectorCtx = @ptrCast(@alignCast(ctx));
        const owned = try testing.allocator.dupe(u8, blob);
        try self.pubs.append(testing.allocator, .{ .character_id = character_id, .blob = owned });
    }

    fn deinit(self: *CollectorCtx) void {
        for (self.pubs.items) |p| testing.allocator.free(p.blob);
        self.pubs.deinit(testing.allocator);
    }
};

test "apply: add creates slot" {
    var inv: Inventory = .{};
    defer inv.deinit(testing.allocator);
    const changed = try apply(testing.allocator, &inv, .{ .op = 'A', .slot = 0, .item_def_id = 42, .quantity = 5 });
    try testing.expect(changed);
    try testing.expectEqual(@as(usize, 1), inv.slots.items.len);
    try testing.expectEqual(@as(i32, 5), inv.slots.items[0].quantity);
}

test "apply: add to existing same-item stacks" {
    var inv: Inventory = .{};
    defer inv.deinit(testing.allocator);
    _ = try apply(testing.allocator, &inv, .{ .op = 'A', .slot = 0, .item_def_id = 42, .quantity = 5 });
    _ = try apply(testing.allocator, &inv, .{ .op = 'A', .slot = 0, .item_def_id = 42, .quantity = 3 });
    try testing.expectEqual(@as(i32, 8), inv.slots.items[0].quantity);
}

test "apply: add with mismatched item def is no-op" {
    var inv: Inventory = .{};
    defer inv.deinit(testing.allocator);
    _ = try apply(testing.allocator, &inv, .{ .op = 'A', .slot = 0, .item_def_id = 42, .quantity = 5 });
    const changed = try apply(testing.allocator, &inv, .{ .op = 'A', .slot = 0, .item_def_id = 7, .quantity = 3 });
    try testing.expect(!changed);
    try testing.expectEqual(@as(i32, 42), inv.slots.items[0].item_def_id);
    try testing.expectEqual(@as(i32, 5), inv.slots.items[0].quantity);
}

test "apply: remove drops slot at zero" {
    var inv: Inventory = .{};
    defer inv.deinit(testing.allocator);
    _ = try apply(testing.allocator, &inv, .{ .op = 'A', .slot = 0, .item_def_id = 42, .quantity = 5 });
    _ = try apply(testing.allocator, &inv, .{ .op = 'R', .slot = 0, .item_def_id = 42, .quantity = 5 });
    try testing.expectEqual(@as(usize, 0), inv.slots.items.len);
}

test "apply: remove clamps underflow at zero" {
    var inv: Inventory = .{};
    defer inv.deinit(testing.allocator);
    _ = try apply(testing.allocator, &inv, .{ .op = 'A', .slot = 0, .item_def_id = 42, .quantity = 3 });
    _ = try apply(testing.allocator, &inv, .{ .op = 'R', .slot = 0, .item_def_id = 42, .quantity = 10 });
    try testing.expectEqual(@as(usize, 0), inv.slots.items.len); // dropped
}

test "apply: set creates and overwrites" {
    var inv: Inventory = .{};
    defer inv.deinit(testing.allocator);
    _ = try apply(testing.allocator, &inv, .{ .op = 'S', .slot = 2, .item_def_id = 42, .quantity = 7 });
    try testing.expectEqual(@as(i32, 7), inv.slots.items[0].quantity);
    _ = try apply(testing.allocator, &inv, .{ .op = 'S', .slot = 2, .item_def_id = 99, .quantity = 1 });
    try testing.expectEqual(@as(i32, 99), inv.slots.items[0].item_def_id);
}

test "apply: set with qty=0 deletes slot" {
    var inv: Inventory = .{};
    defer inv.deinit(testing.allocator);
    _ = try apply(testing.allocator, &inv, .{ .op = 'A', .slot = 3, .item_def_id = 42, .quantity = 5 });
    _ = try apply(testing.allocator, &inv, .{ .op = 'S', .slot = 3, .item_def_id = 42, .quantity = 0 });
    try testing.expectEqual(@as(usize, 0), inv.slots.items.len);
}

test "applyBatch: 1000-item bulk transfer is one dirty mark" {
    // The whole point of batching: 1000 mutations = 1 dirty bit, so
    // the flush tick emits ONE blob update for the entire transfer.
    var state = State.init(testing.allocator);
    defer state.deinit();
    const muts = try testing.allocator.alloc(wire.InventoryMutation, 1000);
    defer testing.allocator.free(muts);
    for (muts, 0..) |*m, i| m.* = .{
        .op = 'S',
        .slot = @intCast(i),
        .item_def_id = 42,
        .quantity = 1,
    };
    const inv = try state.inventoryPtr(7);
    try applyBatch(testing.allocator, inv, muts);
    try testing.expect(inv.dirty);
    try testing.expectEqual(@as(usize, 1000), inv.slots.items.len);

    var col: CollectorCtx = .{};
    defer col.deinit();
    const sink: PublishSink = .{ .ctx = &col, .publishFn = CollectorCtx.publish };
    const n = try flushDirty(&state, sink);
    try testing.expectEqual(@as(u32, 1), n); // ONE publish, not 1000
    try testing.expect(!inv.dirty);
}

test "flushDirty: skips characters with no pending changes" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    const a = try state.inventoryPtr(1);
    const b = try state.inventoryPtr(2);
    _ = try apply(testing.allocator, a, .{ .op = 'A', .slot = 0, .item_def_id = 42, .quantity = 1 });
    a.dirty = true; // applyBatch handles this in prod; apply() returns the bool
    _ = b;

    var col: CollectorCtx = .{};
    defer col.deinit();
    const sink: PublishSink = .{ .ctx = &col, .publishFn = CollectorCtx.publish };
    const n = try flushDirty(&state, sink);
    try testing.expectEqual(@as(u32, 1), n); // only character 1
}

test "encodeBlob: stable shape matches pwriter expectation" {
    var inv: Inventory = .{};
    defer inv.deinit(testing.allocator);
    _ = try apply(testing.allocator, &inv, .{ .op = 'A', .slot = 1, .item_def_id = 7, .quantity = 100 });
    _ = try apply(testing.allocator, &inv, .{ .op = 'A', .slot = 0, .item_def_id = 42, .quantity = 5 });
    const blob = try encodeBlob(testing.allocator, inv);
    defer testing.allocator.free(blob);
    // Slots sorted by .slot — 0 before 1 — for stable JSON output.
    try testing.expectEqualStrings(
        \\{"slots":[{"slot":0,"item_def_id":42,"quantity":5},{"slot":1,"item_def_id":7,"quantity":100}]}
    , blob);
}
