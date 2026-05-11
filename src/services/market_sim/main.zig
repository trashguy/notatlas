//! market-sim — geo-scoped order matching service per docs/02 §201
//! (services: ai, env, market, match) and init.sql §161 (markets are
//! cell-scoped via cell_x/cell_y).
//!
//! v0 scope:
//!   - Single process, in-memory order books keyed by
//!     (cell_x, cell_y, item_def_id). One bid list + one ask list
//!     per book, sorted price-time. No persistence of orders
//!     themselves — only matched trades hit PG, via the existing
//!     `events.market.trade` workqueue stream. Pwriter maps
//!     `buy_order_id = 0` → NULL (`handleMarketTrade`), so v0 trade
//!     rows carry NULL FKs to market_orders. Adding a market_orders
//!     producer is a separate stream the day someone needs order-book
//!     replay.
//!   - Inbound `market.order.submit` carries `wire.OrderMsg` JSON.
//!     Side is 'B' or 'S' as one ASCII byte. On submit we try-match
//!     against the opposite side; partial fills are supported and
//!     leftover quantity rests in the book.
//!   - Outbound `events.market.trade` carries `wire.MarketTradeMsg`
//!     JSON, one per fill. Aggressor + resting prints separately
//!     (the resting price wins — standard exchange semantics).
//!
//! Matching rule (price-time priority):
//!   - A new buy with price >= best ask matches; trade price is the
//!     resting ask's price (price improvement goes to the aggressor).
//!   - A new sell with price <= best bid matches; trade price is the
//!     resting bid's price.
//!   - At same price, earlier submissions match first (FIFO).
//!
//! Phase 2 surface (intentionally deferred):
//!   - market_orders persistence stream + replay on restart
//!   - per-shard sharding (each market-sim owns a contiguous cell
//!     range — already the right shape because books are
//!     cell-keyed).
//!   - cancel / replace orders
//!   - expiration timer for `expires_at`

const std = @import("std");
const nats = @import("nats");
const wire = @import("wire");

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
            std.debug.print("market-sim: unknown arg '{s}'\n", .{a});
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

/// One resting order in a book side. `quantity` is the *remaining*
/// quantity (partial fills decrement in place); when it reaches 0
/// the order is removed.
const Order = struct {
    order_id: i64,
    character_id: i64,
    quantity: i32,
    price: i64,
    submitted_seq: u64,
};

/// Composite hash-map key.
const BookKey = struct {
    cell_x: i32,
    cell_y: i32,
    item_def_id: i32,
};

const Book = struct {
    /// Sorted: price descending, then submitted_seq ascending.
    /// Index 0 is the best (highest) bid.
    bids: std.ArrayListUnmanaged(Order) = .{},
    /// Sorted: price ascending, then submitted_seq ascending.
    /// Index 0 is the best (lowest) ask.
    asks: std.ArrayListUnmanaged(Order) = .{},
};

const State = struct {
    allocator: std.mem.Allocator,
    books: std.AutoHashMapUnmanaged(BookKey, Book) = .{},
    next_order_id: i64 = 1,
    next_seq: u64 = 0,

    fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *State) void {
        var it = self.books.valueIterator();
        while (it.next()) |b| {
            b.bids.deinit(self.allocator);
            b.asks.deinit(self.allocator);
        }
        self.books.deinit(self.allocator);
    }

    fn bookPtr(self: *State, key: BookKey) !*Book {
        const gop = try self.books.getOrPut(self.allocator, key);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }
};

/// Submit one order to the book; emit MarketTradeMsg for each fill.
/// `sink` decouples NATS publish from match logic so the unit test
/// can collect trades into a list without spinning up a client.
const TradeSink = struct {
    ctx: *anyopaque,
    publishFn: *const fn (ctx: *anyopaque, msg: wire.MarketTradeMsg) anyerror!void,

    fn publish(self: TradeSink, msg: wire.MarketTradeMsg) !void {
        return self.publishFn(self.ctx, msg);
    }
};

fn submit(state: *State, sink: TradeSink, order_msg: wire.OrderMsg) !void {
    if (order_msg.quantity <= 0) return; // silent drop — bad input from buggy producer

    const key: BookKey = .{
        .cell_x = order_msg.cell_x,
        .cell_y = order_msg.cell_y,
        .item_def_id = order_msg.item_def_id,
    };
    const book = try state.bookPtr(key);

    state.next_order_id += 1;
    state.next_seq += 1;
    var aggressor: Order = .{
        .order_id = state.next_order_id,
        .character_id = order_msg.character_id,
        .quantity = order_msg.quantity,
        .price = order_msg.price,
        .submitted_seq = state.next_seq,
    };

    const is_buy = order_msg.side == 'B';
    const opposite = if (is_buy) &book.asks else &book.bids;

    // Match loop: consume opposite-side liquidity while the price
    // condition holds and we have remaining quantity.
    while (aggressor.quantity > 0 and opposite.items.len > 0) {
        const resting = &opposite.items[0];
        const crosses = if (is_buy) (aggressor.price >= resting.price) else (aggressor.price <= resting.price);
        if (!crosses) break;

        const fill_qty = @min(aggressor.quantity, resting.quantity);
        const trade: wire.MarketTradeMsg = .{
            // v0 leaves order_ids as 0 → NULL in pwriter. We have the
            // ids but they're ephemeral (book is in-memory; restart
            // resets next_order_id), so publishing them would
            // misrepresent durability.
            .buy_order_id = 0,
            .sell_order_id = 0,
            .buyer_id = if (is_buy) aggressor.character_id else resting.character_id,
            .seller_id = if (is_buy) resting.character_id else aggressor.character_id,
            .item_def_id = order_msg.item_def_id,
            .quantity = fill_qty,
            .price = resting.price, // resting wins — standard exchange semantics
        };
        try sink.publish(trade);

        aggressor.quantity -= fill_qty;
        resting.quantity -= fill_qty;
        if (resting.quantity == 0) _ = opposite.orderedRemove(0);
    }

    // Anything left rests in the book on the aggressor's own side.
    if (aggressor.quantity > 0) {
        const side = if (is_buy) &book.bids else &book.asks;
        try insertSorted(state.allocator, side, aggressor, is_buy);
    }
}

/// Sorted insert preserving price-time priority. `desc_price` is true
/// for bids (best = highest), false for asks (best = lowest).
fn insertSorted(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(Order), o: Order, desc_price: bool) !void {
    var idx: usize = 0;
    while (idx < list.items.len) : (idx += 1) {
        const cur = list.items[idx];
        const better = if (desc_price) (cur.price < o.price) else (cur.price > o.price);
        if (better) break;
        // Same price: the existing order is earlier (smaller
        // submitted_seq), so we slot in *after*.
    }
    try list.insert(allocator, idx, o);
}

const NatsSinkCtx = struct {
    client: *nats.Client,
    allocator: std.mem.Allocator,

    fn publish(ctx: *anyopaque, msg: wire.MarketTradeMsg) anyerror!void {
        const self: *NatsSinkCtx = @ptrCast(@alignCast(ctx));
        const buf = try wire.encodeMarketTrade(self.allocator, msg);
        defer self.allocator.free(buf);
        try self.client.publish("events.market.trade", buf);
    }
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);
    defer allocator.free(args.nats_url);
    try installSignalHandlers();

    std.debug.print("market-sim: connecting to {s}\n", .{args.nats_url});

    var client = try nats.Client.connect(allocator, .{
        .servers = &.{args.nats_url},
        .name = "market-sim",
    });
    defer client.close();

    const sub = try client.subscribe("market.order.submit", .{});
    std.debug.print("market-sim: subscribed to market.order.submit\n", .{});

    var state = State.init(allocator);
    defer state.deinit();

    var sink_ctx: NatsSinkCtx = .{ .client = client, .allocator = allocator };
    const sink: TradeSink = .{ .ctx = &sink_ctx, .publishFn = NatsSinkCtx.publish };

    var orders_since_log: u64 = 0;
    var trades_since_log: u64 = 0;
    var last_log_ns: u64 = @intCast(std.time.nanoTimestamp());

    while (g_running.load(.acquire)) {
        try client.processIncomingTimeout(5);
        try client.maybeSendPing();

        while (sub.nextMsg()) |msg| {
            var owned = msg;
            defer owned.deinit();
            const payload = owned.payload orelse continue;
            const parsed = wire.decodeOrder(allocator, payload) catch |err| {
                std.debug.print("market-sim: bad order payload ({s}): {s}\n", .{ @errorName(err), payload });
                continue;
            };
            defer parsed.deinit();

            const before = state.next_order_id;
            // Trade counter pickup is via a stub sink that wraps the
            // real sink. Cheaper to track from sink side.
            var counting_ctx: CountingSinkCtx = .{ .inner = sink, .count = 0 };
            const counting_sink: TradeSink = .{ .ctx = &counting_ctx, .publishFn = CountingSinkCtx.publish };
            submit(&state, counting_sink, parsed.value) catch |err| {
                std.debug.print("market-sim: submit error ({s})\n", .{@errorName(err)});
                continue;
            };
            orders_since_log += 1;
            trades_since_log += counting_ctx.count;
            std.debug.assert(state.next_order_id == before + 1);
        }

        const now_ns: u64 = @intCast(std.time.nanoTimestamp());
        if (now_ns -% last_log_ns >= log_interval_ns) {
            std.debug.print(
                "[market-sim] {d} orders, {d} trades / 1 s; {d} books\n",
                .{ orders_since_log, trades_since_log, state.books.count() },
            );
            orders_since_log = 0;
            trades_since_log = 0;
            last_log_ns = now_ns;
        }
    }

    std.debug.print("market-sim: shutting down\n", .{});
}

/// Wraps a real sink and counts publishes so the per-second log can
/// report trades emitted this window without re-walking state.
const CountingSinkCtx = struct {
    inner: TradeSink,
    count: u64,

    fn publish(ctx: *anyopaque, msg: wire.MarketTradeMsg) anyerror!void {
        const self: *CountingSinkCtx = @ptrCast(@alignCast(ctx));
        try self.inner.publish(msg);
        self.count += 1;
    }
};

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------
const testing = std.testing;

const CollectorCtx = struct {
    trades: std.ArrayListUnmanaged(wire.MarketTradeMsg) = .{},

    fn publish(ctx: *anyopaque, msg: wire.MarketTradeMsg) anyerror!void {
        const self: *CollectorCtx = @ptrCast(@alignCast(ctx));
        try self.trades.append(testing.allocator, msg);
    }
};

test "match: empty book rests aggressor" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var col: CollectorCtx = .{};
    defer col.trades.deinit(testing.allocator);
    const sink: TradeSink = .{ .ctx = &col, .publishFn = CollectorCtx.publish };

    try submit(&state, sink, .{
        .character_id = 1, .side = 'B', .item_def_id = 42,
        .quantity = 10, .price = 100, .cell_x = 0, .cell_y = 0,
    });
    try testing.expectEqual(@as(usize, 0), col.trades.items.len);
    const book = state.books.get(.{ .cell_x = 0, .cell_y = 0, .item_def_id = 42 }).?;
    try testing.expectEqual(@as(usize, 1), book.bids.items.len);
    try testing.expectEqual(@as(usize, 0), book.asks.items.len);
}

test "match: simple cross at resting price" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var col: CollectorCtx = .{};
    defer col.trades.deinit(testing.allocator);
    const sink: TradeSink = .{ .ctx = &col, .publishFn = CollectorCtx.publish };

    // Resting sell @95, aggressor buy @100 → trades at 95 (resting
    // wins, price improvement to the aggressor).
    try submit(&state, sink, .{
        .character_id = 2, .side = 'S', .item_def_id = 42,
        .quantity = 5, .price = 95, .cell_x = 0, .cell_y = 0,
    });
    try submit(&state, sink, .{
        .character_id = 1, .side = 'B', .item_def_id = 42,
        .quantity = 5, .price = 100, .cell_x = 0, .cell_y = 0,
    });
    try testing.expectEqual(@as(usize, 1), col.trades.items.len);
    const t = col.trades.items[0];
    try testing.expectEqual(@as(i64, 1), t.buyer_id);
    try testing.expectEqual(@as(i64, 2), t.seller_id);
    try testing.expectEqual(@as(i32, 5), t.quantity);
    try testing.expectEqual(@as(i64, 95), t.price);
    const book = state.books.get(.{ .cell_x = 0, .cell_y = 0, .item_def_id = 42 }).?;
    try testing.expectEqual(@as(usize, 0), book.bids.items.len);
    try testing.expectEqual(@as(usize, 0), book.asks.items.len);
}

test "match: partial fill leaves remainder resting" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var col: CollectorCtx = .{};
    defer col.trades.deinit(testing.allocator);
    const sink: TradeSink = .{ .ctx = &col, .publishFn = CollectorCtx.publish };

    // Resting sell of 3, aggressor buy of 10 → 1 trade for 3,
    // remaining 7 rests as a bid.
    try submit(&state, sink, .{
        .character_id = 2, .side = 'S', .item_def_id = 42,
        .quantity = 3, .price = 100, .cell_x = 0, .cell_y = 0,
    });
    try submit(&state, sink, .{
        .character_id = 1, .side = 'B', .item_def_id = 42,
        .quantity = 10, .price = 100, .cell_x = 0, .cell_y = 0,
    });
    try testing.expectEqual(@as(usize, 1), col.trades.items.len);
    try testing.expectEqual(@as(i32, 3), col.trades.items[0].quantity);
    const book = state.books.get(.{ .cell_x = 0, .cell_y = 0, .item_def_id = 42 }).?;
    try testing.expectEqual(@as(usize, 1), book.bids.items.len);
    try testing.expectEqual(@as(i32, 7), book.bids.items[0].quantity);
}

test "match: time priority at same price" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var col: CollectorCtx = .{};
    defer col.trades.deinit(testing.allocator);
    const sink: TradeSink = .{ .ctx = &col, .publishFn = CollectorCtx.publish };

    // Two resting sells at the same price, char 2 first then char 3.
    // A buy of 5 should fully consume char 2's order, then take 2
    // from char 3's.
    try submit(&state, sink, .{
        .character_id = 2, .side = 'S', .item_def_id = 42,
        .quantity = 3, .price = 100, .cell_x = 0, .cell_y = 0,
    });
    try submit(&state, sink, .{
        .character_id = 3, .side = 'S', .item_def_id = 42,
        .quantity = 5, .price = 100, .cell_x = 0, .cell_y = 0,
    });
    try submit(&state, sink, .{
        .character_id = 1, .side = 'B', .item_def_id = 42,
        .quantity = 5, .price = 100, .cell_x = 0, .cell_y = 0,
    });
    try testing.expectEqual(@as(usize, 2), col.trades.items.len);
    try testing.expectEqual(@as(i64, 2), col.trades.items[0].seller_id);
    try testing.expectEqual(@as(i32, 3), col.trades.items[0].quantity);
    try testing.expectEqual(@as(i64, 3), col.trades.items[1].seller_id);
    try testing.expectEqual(@as(i32, 2), col.trades.items[1].quantity);
}

test "match: no cross when prices don't meet" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var col: CollectorCtx = .{};
    defer col.trades.deinit(testing.allocator);
    const sink: TradeSink = .{ .ctx = &col, .publishFn = CollectorCtx.publish };

    try submit(&state, sink, .{
        .character_id = 2, .side = 'S', .item_def_id = 42,
        .quantity = 5, .price = 105, .cell_x = 0, .cell_y = 0,
    });
    try submit(&state, sink, .{
        .character_id = 1, .side = 'B', .item_def_id = 42,
        .quantity = 5, .price = 100, .cell_x = 0, .cell_y = 0,
    });
    try testing.expectEqual(@as(usize, 0), col.trades.items.len);
    const book = state.books.get(.{ .cell_x = 0, .cell_y = 0, .item_def_id = 42 }).?;
    try testing.expectEqual(@as(usize, 1), book.bids.items.len);
    try testing.expectEqual(@as(usize, 1), book.asks.items.len);
}

test "match: cells are isolated" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    var col: CollectorCtx = .{};
    defer col.trades.deinit(testing.allocator);
    const sink: TradeSink = .{ .ctx = &col, .publishFn = CollectorCtx.publish };

    // Sell in cell (0,0), buy at matching price in cell (1,0) — must
    // NOT match across cells.
    try submit(&state, sink, .{
        .character_id = 2, .side = 'S', .item_def_id = 42,
        .quantity = 5, .price = 100, .cell_x = 0, .cell_y = 0,
    });
    try submit(&state, sink, .{
        .character_id = 1, .side = 'B', .item_def_id = 42,
        .quantity = 5, .price = 100, .cell_x = 1, .cell_y = 0,
    });
    try testing.expectEqual(@as(usize, 0), col.trades.items.len);
}
