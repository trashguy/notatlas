//! inventory-sim — authoritative in-memory inventory per character.
//! Closes the SLA arc as the 4th real producer (events.session ✅,
//! events.handoff.cell ✅, events.market.trade ✅, events.inventory.change
//! now ✅).
//!
//! The service exists specifically as the rate-limit / batching
//! layer between the gameplay write rate and Postgres' capacity.
//! Survival sandboxes hand the player 1000s-of-slots operations
//! (hold consolidation, structure stocking, transfer); writing each
//! one straight to PG would knock the datastore over. inventory-sim
//! holds the authoritative blob in memory and flushes on a long
//! tick.
//!
//! ## Durability model
//!
//! Two protections at the wire AND at the service:
//!
//!   - **Batching at the wire**: `inv.mutate` carries
//!     `wire.InventoryMutateMsg` — one message, one character, N
//!     mutations. A 1000-slot transfer becomes ONE NATS msg + ONE
//!     PG write.
//!   - **Coalescing at the service**: a long flush tick (60 s
//!     default, `--flush-interval-ms`) emits ONE
//!     `events.inventory.change.<character_id>` per dirty character
//!     with the full updated `{slots:[...]}` blob. Caps PG writes
//!     at ~1/min/character regardless of producer rate.
//!
//! End-to-end mutation→PG SLA: flush_interval + pwriter slow-tier
//! p99 (10 s) = ~70 s worst-case at the default. Acceptable for
//! inventory: short-window rollback on service crash is preferable
//! to bombing pwriter.
//!
//! ## Rollback semantics (lossy-on-crash, by design)
//!
//! Between flushes, the authoritative inventory state lives ONLY in
//! the service's memory. If the service dies mid-window, every
//! mutation since the last successful flush is gone. The gameplay
//! model accepts this: PG holds the last good blob, and a
//! post-restart player sees their inventory as it was at the last
//! flush.
//!
//! ## PG hydration on boot (REQUIRED for safety)
//!
//! Without hydration, a service restart starts with empty state.
//! The first new mutation builds a 1-slot blob from scratch and
//! publishes — pwriter UPSERTs over the full PG blob. That's worse
//! than rollback; it's data destruction.
//!
//! So at startup the service reads `SELECT character_id, blob FROM
//! inventories JOIN characters ON characters.id =
//! inventories.character_id WHERE characters.cycle_id = $1` (current
//! cycle from `wipe_cycles.ends_at IS NULL`) and rehydrates state.
//! A subsequent mutation merges into the hydrated blob and re-emits
//! a faithful full blob.
//!
//! ## Out of scope for v0
//!
//!   - Cross-character atomicity (player A → player B transfer is
//!     two separate mutate messages; needs a transfer-record stream
//!     and a 2-phase shape — Phase 2/3).
//!   - Slot caps / weight / volume / quality tiers.
//!   - Per-character rate limiting beyond the flush cap.
//!   - `admin.cycle.changed` handling — on wipe, the service should
//!     drop its in-memory state because the FK'd characters
//!     disappear. Currently you'd restart the service. Wire up
//!     when wipe rollover lands in production.

const std = @import("std");
const nats = @import("nats");
const pg = @import("pg");
const wire = @import("wire");

const default_flush_interval_ms: u64 = 60_000; // 60 s — minute-class SLA
const log_interval_ns: u64 = std.time.ns_per_s;

const Args = struct {
    nats_url: []const u8 = "nats://127.0.0.1:4222",
    pg_host: []const u8 = "127.0.0.1",
    pg_port: u16 = 5432,
    pg_user: []const u8 = "notatlas",
    pg_pass: []const u8 = "notatlas",
    pg_db: []const u8 = "notatlas",
    /// Flush tick in ms. Default 60 s (minute-class SLA). Smoke
    /// harnesses set this to a sub-second value so assertions don't
    /// take a minute.
    flush_interval_ms: u64 = default_flush_interval_ms,
};

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var out: Args = .{};
    var owned_nats = false;
    var owned_pg_host = false;
    var owned_pg_user = false;
    var owned_pg_pass = false;
    var owned_pg_db = false;
    errdefer {
        if (owned_nats) allocator.free(out.nats_url);
        if (owned_pg_host) allocator.free(out.pg_host);
        if (owned_pg_user) allocator.free(out.pg_user);
        if (owned_pg_pass) allocator.free(out.pg_pass);
        if (owned_pg_db) allocator.free(out.pg_db);
    }
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--nats")) {
            const v = args.next() orelse return error.MissingArg;
            out.nats_url = try allocator.dupe(u8, v);
            owned_nats = true;
        } else if (std.mem.eql(u8, a, "--pg-host")) {
            const v = args.next() orelse return error.MissingArg;
            out.pg_host = try allocator.dupe(u8, v);
            owned_pg_host = true;
        } else if (std.mem.eql(u8, a, "--pg-port")) {
            out.pg_port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--pg-user")) {
            const v = args.next() orelse return error.MissingArg;
            out.pg_user = try allocator.dupe(u8, v);
            owned_pg_user = true;
        } else if (std.mem.eql(u8, a, "--pg-pass")) {
            const v = args.next() orelse return error.MissingArg;
            out.pg_pass = try allocator.dupe(u8, v);
            owned_pg_pass = true;
        } else if (std.mem.eql(u8, a, "--pg-db")) {
            const v = args.next() orelse return error.MissingArg;
            out.pg_db = try allocator.dupe(u8, v);
            owned_pg_db = true;
        } else if (std.mem.eql(u8, a, "--flush-interval-ms")) {
            out.flush_interval_ms = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArg, 10);
            if (out.flush_interval_ms == 0) return error.BadArg;
        } else {
            std.debug.print("inventory-sim: unknown arg '{s}'\n", .{a});
            return error.BadArg;
        }
    }
    if (!owned_nats)    out.nats_url = try allocator.dupe(u8, out.nats_url);
    if (!owned_pg_host) out.pg_host  = try allocator.dupe(u8, out.pg_host);
    if (!owned_pg_user) out.pg_user  = try allocator.dupe(u8, out.pg_user);
    if (!owned_pg_pass) out.pg_pass  = try allocator.dupe(u8, out.pg_pass);
    if (!owned_pg_db)   out.pg_db    = try allocator.dupe(u8, out.pg_db);
    return out;
}

fn freeArgs(allocator: std.mem.Allocator, a: *Args) void {
    allocator.free(a.nats_url);
    allocator.free(a.pg_host);
    allocator.free(a.pg_user);
    allocator.free(a.pg_pass);
    allocator.free(a.pg_db);
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

/// Find the current wipe cycle. Mirrors pwriter's probeCurrentCycle
/// so both services land on the same id.
fn probeCurrentCycle(pool: *pg.Pool) !i64 {
    var row_opt = try pool.row(
        "SELECT id FROM wipe_cycles WHERE ends_at IS NULL ORDER BY id DESC LIMIT 1",
        .{},
    );
    if (row_opt) |*row| {
        defer row.deinit() catch {};
        return try row.get(i64, 0);
    }
    return error.NoCurrentCycle;
}

/// Walk `inventories JOIN characters` for the current cycle and
/// populate `state` with the persisted blobs. Without this, a
/// post-crash restart starts empty and the next mutation overwrites
/// the full PG blob with a partial one. Returns rows loaded.
fn hydrateFromPg(state: *State, pool: *pg.Pool, cycle_id: i64) !u32 {
    var result = try pool.query(
        \\SELECT inventories.character_id, inventories.blob::text
        \\FROM inventories
        \\JOIN characters ON characters.id = inventories.character_id
        \\WHERE characters.cycle_id = $1
    , .{cycle_id});
    defer result.deinit();

    var loaded: u32 = 0;
    while (try result.next()) |row| {
        const character_id = try row.get(i64, 0);
        const blob_text = try row.get([]const u8, 1);

        const parsed = std.json.parseFromSlice(Blob, state.allocator, blob_text, .{ .ignore_unknown_fields = true }) catch |err| {
            std.debug.print("inventory-sim: hydrate skip char={d} bad JSON ({s}): {s}\n", .{ character_id, @errorName(err), blob_text });
            continue;
        };
        defer parsed.deinit();

        const inv = try state.inventoryPtr(character_id);
        // The blob is already sorted on the write path (encodeBlob
        // walks slots.items in stored order, which insertSortedSlot
        // keeps sorted by .slot). Append wholesale; don't bother
        // re-sorting.
        try inv.slots.appendSlice(state.allocator, parsed.value.slots);
        // Hydrated state matches PG → no pending flush.
        inv.dirty = false;
        loaded += 1;
    }
    return loaded;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try parseArgs(allocator);
    defer freeArgs(allocator, &args);
    try installSignalHandlers();

    const flush_period_ns: u64 = args.flush_interval_ms * std.time.ns_per_ms;

    std.debug.print(
        "inventory-sim: nats={s} pg={s}@{s}:{d}/{s} flush_interval={d} ms\n",
        .{ args.nats_url, args.pg_user, args.pg_host, args.pg_port, args.pg_db, args.flush_interval_ms },
    );

    // PG first — fail fast if hydration prerequisite isn't reachable,
    // before opening a NATS sub and accepting mutations we'd lose.
    var pool = pg.Pool.init(allocator, .{
        .size = 1,
        .connect = .{ .host = args.pg_host, .port = args.pg_port },
        .auth = .{
            .username = args.pg_user,
            .password = args.pg_pass,
            .database = args.pg_db,
            .timeout = 10_000,
        },
    }) catch |err| {
        std.debug.print("inventory-sim: pg connect failed: {}\n", .{err});
        return err;
    };
    defer pool.deinit();

    const cycle_id = probeCurrentCycle(pool) catch |err| {
        std.debug.print("inventory-sim: cycle probe failed: {}\n", .{err});
        return err;
    };
    std.debug.print("inventory-sim: current cycle id={d}\n", .{cycle_id});

    var state = State.init(allocator);
    defer state.deinit();

    const hydrated = hydrateFromPg(&state, pool, cycle_id) catch |err| {
        std.debug.print("inventory-sim: hydration failed: {}\n", .{err});
        return err;
    };
    std.debug.print("inventory-sim: hydrated {d} characters from PG\n", .{hydrated});

    var client = try nats.Client.connect(allocator, .{
        .servers = &.{args.nats_url},
        .name = "inventory-sim",
    });
    defer client.close();

    const sub = try client.subscribe("inv.mutate", .{});
    std.debug.print("inventory-sim: subscribed to inv.mutate\n", .{});

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
