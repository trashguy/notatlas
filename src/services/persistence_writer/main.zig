//! persistence-writer — sole Postgres writer per docs/02 §5.
//!
//! Consumes JetStream change streams (workqueue retention) and
//! materializes them into Postgres tables. Never on the hot path;
//! batches writes; ack-on-commit so JetStream redelivers any work
//! that wasn't durably committed.
//!
//! v0 streams attached:
//!   events_market_trade     events.market.trade         → market_trades
//!   events_handoff_cell     events.handoff.cell         → cell_handoffs
//!   events_inventory_change events.inventory.change.*   → inventories
//!
//! Damage is NOT in pwriter — too volume-heavy for row-per-event PG
//! and the only useful queries are aggregates. Live damage stays on
//! `sim.entity.*.damage` core NATS; a future stats-sim consumes it.
//! Optional forensic JetStream capture is config in
//! `data/jetstream.yaml` (disabled by default).
//!
//! Per-stream wiring lives in `stream_specs[]` — adding another stream
//! is one entry plus a handler. Round-robin pull-fetch with short
//! per-stream timeouts so a hot stream isn't latency-blocked behind
//! cold ones.
//!
//! Per-event errors (FK violation, malformed JSON, etc.) are isolated
//! via Postgres SAVEPOINTs so one bad event doesn't roll back the
//! batch. JetStream redelivers only un-acked messages.
//!
//! Design context:
//!   - docs/02-architecture.md §5 — mixed persistence shape, sole-writer
//!     decision. Damage/handoff lists are JetStream KV (live) plus PG
//!     analytics aggregates; market is purely relational; inventory is
//!     the JSONB blob path.
//!   - feedback_graceful_degradation.md — PG offline must NOT cascade
//!     into producers. Producers keep writing to JetStream (durable);
//!     this service catches up on reconnect.
//!   - feedback_nats_zig_2_14_consumer_envelope.md — js.createConsumer
//!     in nats-zig 0.2.2 sends pre-2.14 JSON; we hand-roll via
//!     client.request() until nats-zig 0.3 ships.

const std = @import("std");
const nats = @import("nats");
const pg = @import("pg");
const wire = @import("wire");

const fetch_batch: u32 = 256;
const fetch_timeout_ms: u32 = 25; // per-stream; round-robin wraps in ~100ms with 4 streams
const idle_sleep_ns: u64 = 50 * std.time.ns_per_ms;
const log_interval_ns: u64 = std.time.ns_per_s;

const consumer_name = "pwriter";

const StreamSpec = struct {
    stream_name: []const u8,
    subject_filter: []const u8,
    handler: *const fn (
        allocator: std.mem.Allocator,
        conn: *pg.Conn,
        cycle_id: i64,
        subject: []const u8,
        payload: []const u8,
    ) anyerror!void,
};

// Damage events are deliberately NOT in this list. The PG row would
// be ~5k/sec/cell × 100 cells × 70d = ~30B rows per wipe — and the
// only useful queries are aggregates (kill counts, leaderboards).
// Live damage flows on `sim.entity.*.damage` core NATS; future
// stats-sim and anomaly-sim consume there. Optional forensic
// capture is a broker-level config in `data/jetstream.yaml`,
// disabled by default. See memory `architecture_damage_not_in_pg.md`.
const stream_specs = [_]StreamSpec{
    .{
        .stream_name = "events_market_trade",
        .subject_filter = "events.market.trade",
        .handler = handleMarketTrade,
    },
    .{
        .stream_name = "events_handoff_cell",
        .subject_filter = "events.handoff.cell",
        .handler = handleHandoffCell,
    },
    .{
        .stream_name = "events_inventory_change",
        .subject_filter = "events.inventory.change.*",
        .handler = handleInventoryChange,
    },
};

const Args = struct {
    nats_url: []const u8 = "nats://127.0.0.1:4222",
    pg_host: []const u8 = "127.0.0.1",
    pg_port: u16 = 5432,
    pg_user: []const u8 = "notatlas",
    pg_pass: []const u8 = "notatlas",
    pg_db: []const u8 = "notatlas",
};

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var out: Args = .{};
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--nats")) {
            out.nats_url = try allocator.dupe(u8, args.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, a, "--pg-host")) {
            out.pg_host = try allocator.dupe(u8, args.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, a, "--pg-port")) {
            out.pg_port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--pg-user")) {
            out.pg_user = try allocator.dupe(u8, args.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, a, "--pg-pass")) {
            out.pg_pass = try allocator.dupe(u8, args.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, a, "--pg-db")) {
            out.pg_db = try allocator.dupe(u8, args.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                \\persistence-writer — sole Postgres writer.
                \\
                \\Options:
                \\  --nats <url>       (default nats://127.0.0.1:4222)
                \\  --pg-host <host>   (default 127.0.0.1)
                \\  --pg-port <port>   (default 5432)
                \\  --pg-user <user>   (default notatlas)
                \\  --pg-pass <pass>   (default notatlas)
                \\  --pg-db <db>       (default notatlas)
                \\
            , .{});
            std.process.exit(0);
        } else {
            std.debug.print("persistence-writer: unknown arg '{s}'\n", .{a});
            return error.BadArg;
        }
    }
    return out;
}

var stop_flag = std.atomic.Value(bool).init(false);

fn handleSignal(_: c_int) callconv(.c) void {
    stop_flag.store(true, .release);
}

fn installSignalHandlers() !void {
    var sa: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);

    try installSignalHandlers();

    std.debug.print("persistence-writer: connecting to nats {s}\n", .{args.nats_url});
    var nats_client = nats.Client.connect(allocator, .{
        .servers = &.{args.nats_url},
        .name = "persistence-writer",
    }) catch |err| {
        std.debug.print("persistence-writer: nats connect failed: {}\n", .{err});
        return err;
    };
    defer nats_client.close();
    std.debug.print("persistence-writer: nats connected\n", .{});

    std.debug.print("persistence-writer: connecting to pg {s}@{s}:{d}/{s}\n", .{
        args.pg_user, args.pg_host, args.pg_port, args.pg_db,
    });
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
        std.debug.print("persistence-writer: pg connect failed: {}\n", .{err});
        return err;
    };
    defer pool.deinit();
    std.debug.print("persistence-writer: pg connected\n", .{});

    var cycle_id: i64 = probeCurrentCycle(pool) catch |err| {
        std.debug.print("persistence-writer: cycle probe failed: {}\n", .{err});
        return err;
    };
    std.debug.print("persistence-writer: current cycle id={d}\n", .{cycle_id});

    // `admin.cycle.changed` is the wipe-rollover signal. We don't
    // trust the message payload — instead we re-probe wipe_cycles to
    // get the new authoritative cycle id. This way a malformed or
    // late-delivered notification can't pin pwriter to the wrong
    // cycle. Core NATS (best-effort): if we miss the message, the
    // boot-time probe corrects on next restart.
    const cycle_sub = try nats_client.subscribe("admin.cycle.changed", .{});
    defer nats_client.unsubscribe(cycle_sub) catch {};

    var js = nats.JetStream.Context.init(nats_client);
    var pulls: [stream_specs.len]nats.JetStream.PullSubscription = undefined;
    var pulls_initialized: usize = 0;
    defer {
        var i: usize = pulls_initialized;
        while (i > 0) {
            i -= 1;
            pulls[i].close();
        }
    }

    for (stream_specs, 0..) |spec, i| {
        try ensureStream(&js, spec.stream_name, spec.subject_filter);
        try ensureConsumer(nats_client, spec.stream_name);
        pulls[i] = try js.pullSubscribe(spec.stream_name, consumer_name);
        pulls_initialized = i + 1;
        std.debug.print(
            "persistence-writer: stream={s} subject={s} consumer={s} ready\n",
            .{ spec.stream_name, spec.subject_filter, consumer_name },
        );
    }

    var totals = [_]u64{0} ** stream_specs.len;
    var last_log_ns: i128 = std.time.nanoTimestamp();
    while (!stop_flag.load(.acquire)) {
        // pull.fetch internally calls processIncoming which dispatches
        // ALL routed messages — so cycle_sub is being filled by the
        // fetches below. Drain any pending cycle-changed notifications
        // before processing events so a rolled cycle takes effect on
        // the next handler call.
        while (cycle_sub.nextMsg()) |msg_orig| {
            var cmsg = msg_orig;
            defer cmsg.deinit();
            const new_cycle = probeCurrentCycle(pool) catch |err| {
                std.debug.print(
                    "persistence-writer: cycle re-probe failed: {}\n",
                    .{err},
                );
                continue;
            };
            if (new_cycle != cycle_id) {
                std.debug.print(
                    "persistence-writer: cycle rolled {d} -> {d}\n",
                    .{ cycle_id, new_cycle },
                );
                cycle_id = new_cycle;
            }
        }

        var any_processed = false;
        for (stream_specs, 0..) |spec, i| {
            const msgs = pulls[i].fetch(fetch_batch, fetch_timeout_ms) catch |err| {
                std.debug.print(
                    "persistence-writer: fetch err on {s}: {}\n",
                    .{ spec.stream_name, err },
                );
                continue;
            };
            if (msgs.len == 0) {
                allocator.free(msgs);
                continue;
            }
            const committed = processBatch(allocator, pool, &pulls[i], msgs, cycle_id, spec.handler) catch |err| blk: {
                std.debug.print(
                    "persistence-writer: batch err on {s}: {}\n",
                    .{ spec.stream_name, err },
                );
                break :blk 0;
            };
            totals[i] += committed;
            any_processed = true;
            for (msgs) |*m| @constCast(m).deinit();
            allocator.free(msgs);
        }
        if (!any_processed) std.Thread.sleep(idle_sleep_ns);

        const now = std.time.nanoTimestamp();
        if (now - last_log_ns >= log_interval_ns) {
            std.debug.print(
                "persistence-writer: cycle={d} market={d} handoff={d} inv={d}\n",
                .{ cycle_id, totals[0], totals[1], totals[2] },
            );
            last_log_ns = now;
        }
    }

    std.debug.print(
        "persistence-writer: shutting down (market={d} handoff={d} inv={d})\n",
        .{ totals[0], totals[1], totals[2] },
    );
}

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

fn ensureStream(
    js: *nats.JetStream.Context,
    stream_name: []const u8,
    subject_filter: []const u8,
) !void {
    if (js.streamInfo(stream_name)) |_| {
        return;
    } else |err| switch (err) {
        nats.JetStream.Error.StreamNotFound => {},
        else => return err,
    }
    _ = try js.createStream(.{
        .name = stream_name,
        .subjects = &.{subject_filter},
        .retention = .workqueue,
        .storage = .file,
    });
}

/// See `feedback_nats_zig_2_14_consumer_envelope.md`. nats-zig 0.2.2's
/// `js.createConsumer` sends the pre-2.14 envelope; we POST the 2.14
/// shape directly. Accept a re-create against an existing matching
/// config (broker returns success) and surface mismatches loudly.
fn ensureConsumer(client: *nats.Client, stream_name: []const u8) !void {
    var subject_buf: [256]u8 = undefined;
    const subject = try std.fmt.bufPrint(
        &subject_buf,
        "$JS.API.CONSUMER.CREATE.{s}.{s}",
        .{ stream_name, consumer_name },
    );

    var body_buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &body_buf,
        \\{{"stream_name":"{s}","config":{{"durable_name":"{s}","ack_policy":"explicit","deliver_policy":"all","max_deliver":-1,"ack_wait":30000000000}}}}
    ,
        .{ stream_name, consumer_name },
    );

    var msg = try client.request(subject, body, 5000);
    defer msg.deinit();

    const payload = msg.payload orelse return error.NoBrokerResponse;
    if (std.mem.indexOf(u8, payload, "\"error\":{") != null) {
        std.debug.print(
            "persistence-writer: consumer create rejected on {s}: {s}\n",
            .{ stream_name, payload },
        );
        return error.ConsumerCreateRejected;
    }
}

/// Drain a fetched batch into PG. Each event runs as a single auto-
/// committed statement (no explicit BEGIN/COMMIT) — pg.zig considers
/// the connection unrecoverable after any tx-error, which kills
/// SAVEPOINT-based per-event isolation. Auto-commit gives the same
/// isolation property cheaply: a FK violation on event N doesn't
/// affect events N±1.
///
/// Ack policy:
///   handler succeeded → ack (durable progress)
///   handler errored   → no-ack (JetStream redelivers after ack_wait)
///
/// Application-level errors (FK violation on a known-bad event) will
/// thus redeliver forever and pollute the log. The intent is that
/// such events are producer bugs that should be fixed at the source —
/// not silently dropped here. If a deadletter destination becomes
/// useful, route NAKs there explicitly.
fn processBatch(
    allocator: std.mem.Allocator,
    pool: *pg.Pool,
    pull: *nats.JetStream.PullSubscription,
    msgs: []nats.Protocol.Msg,
    cycle_id: i64,
    handler: *const fn (
        std.mem.Allocator,
        *pg.Conn,
        i64,
        []const u8,
        []const u8,
    ) anyerror!void,
) !u64 {
    var conn = try pool.acquire();
    defer conn.release();

    var acked: u64 = 0;
    for (msgs) |*m| {
        const payload = m.payload orelse {
            // Empty payload — ack and skip; nothing to write.
            pull.ack(m) catch {};
            continue;
        };
        const subject = m.subject;

        handler(allocator, conn, cycle_id, subject, payload) catch |err| {
            if (conn.err) |pg_err| {
                std.debug.print(
                    "persistence-writer: handler err on '{s}': {} — pg: {s}\n",
                    .{ subject, err, pg_err.message },
                );
            } else {
                std.debug.print(
                    "persistence-writer: handler err on '{s}': {}\n",
                    .{ subject, err },
                );
            }
            // No ack — JetStream will redeliver after ack_wait.
            // pg.zig keeps the connection in .fail state after a
            // statement error; release+reacquire forces the pool to
            // hand back a usable connection (or reconnect if needed).
            conn.release();
            conn = try pool.acquire();
            continue;
        };

        pull.ack(m) catch |err| {
            std.debug.print("persistence-writer: ack err {}\n", .{err});
            continue;
        };
        acked += 1;
    }
    return acked;
}

// ---------------------------------------------------------------------------
// Per-stream handlers. Each handler runs inside a SAVEPOINT so any error
// rolls back THIS event only and the batch tx continues.
// ---------------------------------------------------------------------------

fn handleMarketTrade(
    allocator: std.mem.Allocator,
    conn: *pg.Conn,
    cycle_id: i64,
    subject: []const u8,
    payload: []const u8,
) !void {
    _ = subject;
    var parsed = try wire.decodeMarketTrade(allocator, payload);
    defer parsed.deinit();
    const t = parsed.value;

    // Producer convention: 0 means "no FK" — stored as NULL so the
    // ON DELETE SET NULL FK semantics work without a referential row.
    const buy_order = if (t.buy_order_id == 0) null else @as(?i64, t.buy_order_id);
    const sell_order = if (t.sell_order_id == 0) null else @as(?i64, t.sell_order_id);
    const buyer = if (t.buyer_id == 0) null else @as(?i64, t.buyer_id);
    const seller = if (t.seller_id == 0) null else @as(?i64, t.seller_id);

    _ = try conn.exec(
        \\INSERT INTO market_trades
        \\  (cycle_id, buy_order_id, sell_order_id, buyer_id, seller_id,
        \\   item_def_id, quantity, price, executed_at)
        \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW())
    ,
        .{
            cycle_id,
            buy_order,
            sell_order,
            buyer,
            seller,
            t.item_def_id,
            t.quantity,
            t.price,
        },
    );
}

fn handleHandoffCell(
    allocator: std.mem.Allocator,
    conn: *pg.Conn,
    cycle_id: i64,
    subject: []const u8,
    payload: []const u8,
) !void {
    _ = subject;
    var parsed = try wire.decodeHandoffCell(allocator, payload);
    defer parsed.deinit();
    const h = parsed.value;

    _ = try conn.exec(
        \\INSERT INTO cell_handoffs
        \\  (cycle_id, entity_id,
        \\   from_cell_x, from_cell_y, to_cell_x, to_cell_y,
        \\   pos_x, pos_y, pos_z, occurred_at)
        \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, NOW())
    ,
        .{
            cycle_id,
            @as(i64, h.entity_id),
            h.from_cell_x,
            h.from_cell_y,
            h.to_cell_x,
            h.to_cell_y,
            h.pos_x,
            h.pos_y,
            h.pos_z,
        },
    );
}

fn handleInventoryChange(
    allocator: std.mem.Allocator,
    conn: *pg.Conn,
    cycle_id: i64,
    subject: []const u8,
    payload: []const u8,
) !void {
    _ = allocator;
    _ = cycle_id; // inventories.character_id PK is the wipe-scope; cycle is via characters FK
    const character_id = try wire.parseCharacterIdFromInventorySubject(subject);

    // Upsert the entire blob. version bumps on each update so a future
    // reader can detect stale snapshots.
    _ = try conn.exec(
        \\INSERT INTO inventories (character_id, version, blob, updated_at)
        \\VALUES ($1, 1, $2::jsonb, NOW())
        \\ON CONFLICT (character_id) DO UPDATE
        \\SET version = inventories.version + 1,
        \\    blob = EXCLUDED.blob,
        \\    updated_at = NOW()
    ,
        .{ character_id, payload },
    );
}
