//! cell-mgr — fanout service for one (or, eventually, more) spatial
//! cell. M6.3 scope: connect to NATS, subscribe to membership +
//! subscriber registration subjects, maintain in-memory entity +
//! subscriber tables, run a 30 Hz fanout tick that logs the per-tick
//! count. M6.4 wires the actual tier filter into the tick body.
//!
//! Process model per docs/08 §2.4: single binary, configured at
//! runtime with a cell id. Phase 1 default deployment is one process
//! per cell; the binary doesn't know whether it's packed or sub-cell-
//! split until args say so. M6.3 only handles the 1:1 case.
//!
//! Single-threaded poll loop. nats-zig's `poll()` is non-blocking, so
//! we drain it in a tight inner loop, then check whether the 33 ms
//! tick is due, then sleep ~1 ms to avoid burning a core. Splitting
//! out a dedicated tick thread is unnecessary at 30 Hz.

const std = @import("std");
const nats = @import("nats");

const wire = @import("wire.zig");
const cm_state = @import("state.zig");

const tick_period_ns: u64 = std.time.ns_per_s / 30; // 30 Hz fanout

const Args = struct {
    cell_x: i32 = 0,
    cell_y: i32 = 0,
    nats_url: []const u8 = "nats://127.0.0.1:4222",
};

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip exe

    var out: Args = .{};
    var have_nats_url = false;
    errdefer if (have_nats_url) allocator.free(out.nats_url);
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--cell")) {
            const v = args.next() orelse return error.MissingArg;
            // Format: "<x>_<y>" e.g. "0_0", "-3_4"
            const us = std.mem.indexOfScalar(u8, v, '_') orelse return error.BadCellArg;
            out.cell_x = try std.fmt.parseInt(i32, v[0..us], 10);
            out.cell_y = try std.fmt.parseInt(i32, v[us + 1 ..], 10);
        } else if (std.mem.eql(u8, a, "--nats")) {
            const v = args.next() orelse return error.MissingArg;
            // Args memory is freed when iterator deinits — dup to outlive it.
            out.nats_url = try allocator.dupe(u8, v);
            have_nats_url = true;
        } else {
            std.debug.print("cell-mgr: unknown arg '{s}'\n", .{a});
            return error.BadArg;
        }
    }
    if (!have_nats_url) {
        // Caller still frees out.nats_url uniformly; default needs a
        // duped copy too.
        out.nats_url = try allocator.dupe(u8, out.nats_url);
    }
    return out;
}

// Process exit flag flipped by SIGINT/SIGTERM. Atomic so the signal
// handler can write while the main loop reads.
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

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);
    defer allocator.free(args.nats_url);
    try installSignalHandlers();

    // Subject names live with cell coords baked in — saves us repeating
    // the same fmt in every drain loop iteration.
    const delta_subj = try std.fmt.allocPrint(allocator, "idx.spatial.cell.{d}_{d}.delta", .{ args.cell_x, args.cell_y });
    defer allocator.free(delta_subj);
    const sub_subj = try std.fmt.allocPrint(allocator, "cm.cell.{d}_{d}.subscribe", .{ args.cell_x, args.cell_y });
    defer allocator.free(sub_subj);
    const unsub_subj = try std.fmt.allocPrint(allocator, "cm.cell.{d}_{d}.unsubscribe", .{ args.cell_x, args.cell_y });
    defer allocator.free(unsub_subj);

    std.debug.print("cell-mgr [{d}_{d}]: connecting to {s}\n", .{ args.cell_x, args.cell_y, args.nats_url });

    var client = try nats.Client.connect(allocator, .{
        .servers = &.{args.nats_url},
        .name = "cell-mgr",
    });
    defer client.close();

    const sub_delta = try client.subscribe(delta_subj, .{});
    const sub_sub = try client.subscribe(sub_subj, .{});
    const sub_unsub = try client.subscribe(unsub_subj, .{});

    std.debug.print("cell-mgr [{d}_{d}]: subscribed to {s}, {s}, {s}\n", .{ args.cell_x, args.cell_y, delta_subj, sub_subj, unsub_subj });

    var state = cm_state.State.init(allocator);
    defer state.deinit();

    var last_tick_ns: u64 = @intCast(std.time.nanoTimestamp());
    var tick_n: u64 = 0;

    while (g_running.load(.acquire)) {
        // Drain inbound socket — fills sub.pending lists for each
        // active subscription. processIncoming reads with a short
        // timeout (currently 100 ms in nats-zig); that gates our tick
        // when the socket is idle. Acceptable for the M6.3 skeleton —
        // tighter cadence under no-traffic is a nats-zig API issue
        // (configurable poll budget) we'll address as load grows.
        try client.processIncoming();

        try drainDeltaSub(allocator, sub_delta, &state);
        try drainSubscribeSub(allocator, sub_sub, &state, .enter);
        try drainSubscribeSub(allocator, sub_unsub, &state, .exit);

        try client.maybeSendPing();

        const now_ns: u64 = @intCast(std.time.nanoTimestamp());
        if (now_ns -% last_tick_ns >= tick_period_ns) {
            tick_n += 1;
            std.debug.print("[cell {d}_{d}] tick {d}: {d} entities, {d} subscribers\n", .{
                args.cell_x, args.cell_y, tick_n, state.entityCount(), state.subscriberCount(),
            });
            // Catch-up rather than reset: if we missed several tick
            // boundaries (long log flush, GC pause) we still publish
            // exactly one tick per period — same model as the M5.1
            // physics accumulator.
            last_tick_ns +%= tick_period_ns;
        }
    }

    std.debug.print("cell-mgr [{d}_{d}]: shutting down\n", .{ args.cell_x, args.cell_y });
}

fn drainDeltaSub(allocator: std.mem.Allocator, sub: *nats.Subscription, state: *cm_state.State) !void {
    while (sub.nextMsg()) |msg| {
        var owned = msg;
        defer owned.deinit();
        const parsed = wire.decodeDelta(allocator, owned.payload orelse "") catch |err| {
            std.debug.print("cell-mgr: bad delta payload ({s}): {s}\n", .{ @errorName(err), owned.payload orelse "" });
            continue;
        };
        defer parsed.deinit();
        _ = try state.applyDelta(parsed.value);
    }
}

/// `expected_op` is the op these messages should carry — the subject
/// already encoded the intent (subscribe vs unsubscribe), so we
/// override whatever the harness put in the body. Keeps the
/// subscribe/unsubscribe paths from getting swapped by a buggy
/// publisher.
fn drainSubscribeSub(allocator: std.mem.Allocator, sub: *nats.Subscription, state: *cm_state.State, expected_op: wire.Op) !void {
    while (sub.nextMsg()) |msg| {
        var owned = msg;
        defer owned.deinit();
        const parsed = wire.decodeSubscribe(allocator, owned.payload orelse "") catch |err| {
            std.debug.print("cell-mgr: bad subscribe payload ({s}): {s}\n", .{ @errorName(err), owned.payload orelse "" });
            continue;
        };
        defer parsed.deinit();
        var msg_value = parsed.value;
        msg_value.op = expected_op;
        _ = try state.applySubscribe(msg_value);
    }
}
