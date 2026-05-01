//! persistence-writer — sole Postgres writer per docs/02 §5.
//!
//! Consumes JetStream change streams (workqueue retention) and
//! materializes them into Postgres tables. Never on the hot path;
//! batches writes; ack-on-success so JetStream redelivers any work
//! that wasn't durably committed.
//!
//! v0 scope (this commit): build wiring, NATS connect, PG connect,
//! current-cycle probe, signal-driven shutdown. No streams declared,
//! no consumers running. Subsequent commits attach the
//! `events.damage` workqueue stream as the first consumer, then
//! `events.market.trade`, `events.handoff.cell`, etc.
//!
//! Design context:
//!   - docs/02-architecture.md §5 — mixed persistence shape, sole-writer
//!     decision. Damage/event log is JetStream KV (live) plus this
//!     PG aggregate (analytics, end-of-cycle stats).
//!   - feedback_graceful_degradation.md — PG offline must NOT cascade
//!     into producers. Producers keep writing to JetStream (durable);
//!     this service catches up on reconnect. The pg.zig Pool's
//!     reconnect-on-failure thread covers the dataplane half; the
//!     consumer ack pattern covers the message half.

const std = @import("std");
const nats = @import("nats");
const pg = @import("pg");

const tick_period_ns: u64 = std.time.ns_per_s / 10; // 10 Hz heartbeat
const log_interval_ns: u64 = std.time.ns_per_s;

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

    // Probe: which wipe cycle are we in? Surfacing this on boot makes
    // every operator action — even an accidental restart — log the
    // cycle context. Important when the same binary spans multiple
    // wipes during dev.
    const cycle_id = probeCurrentCycle(pool) catch |err| {
        std.debug.print("persistence-writer: cycle probe failed: {}\n", .{err});
        return err;
    };
    std.debug.print("persistence-writer: current cycle id={d}\n", .{cycle_id});

    // v0 idle loop. Real consumer attachment lands in the next commit.
    var last_log_ns: i128 = std.time.nanoTimestamp();
    while (!stop_flag.load(.acquire)) {
        std.Thread.sleep(tick_period_ns);
        const now = std.time.nanoTimestamp();
        if (now - last_log_ns >= log_interval_ns) {
            std.debug.print("persistence-writer: idle (cycle {d})\n", .{cycle_id});
            last_log_ns = now;
        }
    }

    std.debug.print("persistence-writer: shutting down\n", .{});
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
