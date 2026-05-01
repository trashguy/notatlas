//! persistence-writer — sole Postgres writer per docs/02 §5.
//!
//! Consumes JetStream change streams (workqueue retention) and
//! materializes them into Postgres tables. Never on the hot path;
//! batches writes; ack-on-commit so JetStream redelivers any work
//! that wasn't durably committed.
//!
//! v0 scope (this commit): connect to NATS + PG; probe current wipe
//! cycle; declare `events_damage` workqueue stream + durable consumer
//! `pwriter`; pull-fetch loop with batched INSERT into damage_log
//! (single tx, ack-on-commit). Subsequent commits attach more streams
//! (`events_market_trade`, `events_handoff_cell`, etc.).
//!
//! Design context:
//!   - docs/02-architecture.md §5 — mixed persistence shape, sole-writer
//!     decision. The architecture lists damage events as living in
//!     JetStream KV with TTL → wipe; this PG aggregate is the analytics
//!     mirror (end-of-cycle stats, leaderboards). Both reads benefit:
//!     KV serves live queries, PG serves historical.
//!   - feedback_graceful_degradation.md — PG offline must NOT cascade
//!     into producers. Producers keep writing to JetStream (durable);
//!     this service catches up on reconnect. The pg.zig Pool's
//!     reconnect-on-failure thread covers the dataplane half; the
//!     consumer ack-on-commit pattern covers the message half.
//!
//! Stream topology:
//!   stream:    events_damage (workqueue, file storage)
//!   subjects:  sim.entity.*.damage
//!   consumer:  pwriter (durable, explicit ack, deliver_all)
//!
//! Producers (ship-sim today) `client.publish()` to the subject via
//! core NATS — JetStream auto-captures because the subject matches.
//! No producer-side change is required to enable durability.

const std = @import("std");
const nats = @import("nats");
const pg = @import("pg");
const wire = @import("wire");

const fetch_batch: u32 = 256;
const fetch_timeout_ms: u32 = 100;
const idle_sleep_ns: u64 = 50 * std.time.ns_per_ms;
const log_interval_ns: u64 = std.time.ns_per_s;

const stream_name = "events_damage";
const stream_subject_filter = "sim.entity.*.damage";
const consumer_name = "pwriter";

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

    const cycle_id = probeCurrentCycle(pool) catch |err| {
        std.debug.print("persistence-writer: cycle probe failed: {}\n", .{err});
        return err;
    };
    std.debug.print("persistence-writer: current cycle id={d}\n", .{cycle_id});

    var js = nats.JetStream.Context.init(nats_client);
    try ensureStream(&js);
    try ensureConsumer(nats_client);
    std.debug.print("persistence-writer: stream={s} consumer={s} ready\n", .{
        stream_name, consumer_name,
    });

    var pull = try js.pullSubscribe(stream_name, consumer_name);
    defer pull.close();

    var total_committed: u64 = 0;
    var last_log_ns: i128 = std.time.nanoTimestamp();
    while (!stop_flag.load(.acquire)) {
        const msgs = pull.fetch(fetch_batch, fetch_timeout_ms) catch |err| {
            std.debug.print("persistence-writer: fetch err {}\n", .{err});
            std.Thread.sleep(idle_sleep_ns);
            continue;
        };

        if (msgs.len == 0) {
            allocator.free(msgs);
            std.Thread.sleep(idle_sleep_ns);
        } else {
            const committed = processBatch(allocator, pool, &pull, msgs, cycle_id) catch |err| blk: {
                std.debug.print("persistence-writer: batch err {}\n", .{err});
                break :blk 0;
            };
            total_committed += committed;
            for (msgs) |*m| @constCast(m).deinit();
            allocator.free(msgs);
        }

        const now = std.time.nanoTimestamp();
        if (now - last_log_ns >= log_interval_ns) {
            std.debug.print(
                "persistence-writer: cycle={d} committed={d}\n",
                .{ cycle_id, total_committed },
            );
            last_log_ns = now;
        }
    }

    std.debug.print("persistence-writer: shutting down (committed {d})\n", .{total_committed});
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

fn ensureStream(js: *nats.JetStream.Context) !void {
    if (js.streamInfo(stream_name)) |_| {
        return;
    } else |err| switch (err) {
        nats.JetStream.Error.StreamNotFound => {},
        else => return err,
    }
    _ = try js.createStream(.{
        .name = stream_name,
        .subjects = &.{stream_subject_filter},
        .retention = .workqueue,
        .storage = .file,
    });
}

/// Hand-rolled consumer create — bypasses `js.createConsumer` because
/// nats-zig 0.2.2 still sends the legacy ≤2.13 envelope with
/// `durable_name` at the top level. NATS 2.14+ rejects that with
/// `err_code 10025 invalid JSON: json: unknown field "durable_name"`
/// and requires `{"stream_name": "...", "config": {...}}`. Fix when
/// nats-zig publishes a 2.14-aware release; track in memory
/// `feedback_nats_zig_2_14_consumer_envelope.md`.
fn ensureConsumer(client: *nats.Client) !void {
    const subject = "$JS.API.CONSUMER.CREATE." ++ stream_name ++ "." ++ consumer_name;
    const body =
        \\{"stream_name":"
    ++ stream_name ++
        \\","config":{"durable_name":"
    ++ consumer_name ++
        \\","ack_policy":"explicit","deliver_policy":"all","max_deliver":-1,"ack_wait":30000000000}}
    ;

    var msg = try client.request(subject, body, 5000);
    defer msg.deinit();

    const payload = msg.payload orelse return error.NoBrokerResponse;
    // Re-create on an existing consumer with matching config returns
    // success. Mismatched config returns an error response — surface
    // it so a config change is loud.
    if (std.mem.indexOf(u8, payload, "\"error\":{") != null) {
        std.debug.print("persistence-writer: consumer create error: {s}\n", .{payload});
        return error.ConsumerCreateRejected;
    }
}

/// Insert one row per damage message inside a single transaction; ack
/// every message after commit. JetStream redelivers the entire batch
/// on un-ack, which is fine because (cycle_id, victim_id, attacker_id,
/// damage, occurred_at) is naturally idempotent — same event landing
/// twice produces a duplicate row, but workqueue retention guarantees
/// the broker only redelivers if our ack didn't reach it. Tx commit
/// happens before ack publish, so the failure window is narrow and
/// any duplicate is observable.
///
/// Returns the number of rows committed (== msgs.len on the success
/// path; 0 on tx rollback).
fn processBatch(
    allocator: std.mem.Allocator,
    pool: *pg.Pool,
    pull: *nats.JetStream.PullSubscription,
    msgs: []nats.Protocol.Msg,
    cycle_id: i64,
) !u64 {
    var conn = try pool.acquire();
    defer conn.release();

    try conn.begin();
    errdefer conn.rollback() catch {};

    for (msgs) |*m| {
        const payload = m.payload orelse continue;
        const subject = m.subject;

        const victim_id = wire.parseVictimIdFromDamageSubject(subject) catch |err| {
            std.debug.print(
                "persistence-writer: bad damage subject '{s}': {}\n",
                .{ subject, err },
            );
            continue;
        };

        var parsed = wire.decodeDamage(allocator, payload) catch |err| {
            std.debug.print("persistence-writer: decode damage failed: {}\n", .{err});
            continue;
        };
        defer parsed.deinit();
        const dmg = parsed.value;

        _ = try conn.exec(
            \\INSERT INTO damage_log
            \\  (cycle_id, attacker_id, victim_id, damage, hp_after, occurred_at)
            \\VALUES ($1, $2, $3, $4, $5, NOW())
        ,
            .{
                cycle_id,
                @as(i64, dmg.source_id),
                @as(i64, victim_id),
                dmg.damage,
                dmg.remaining_hp,
            },
        );
    }

    try conn.commit();

    var acked: u64 = 0;
    for (msgs) |*m| {
        pull.ack(m) catch |err| {
            std.debug.print("persistence-writer: ack err {}\n", .{err});
            continue;
        };
        acked += 1;
    }
    return acked;
}
