//! ship-sim — 60 Hz rigid-body authority for ships AND free-agent
//! players per docs/08 §2A.
//!
//! Skeleton scope (this commit): NATS connect, 60 Hz fixed-step
//! tick loop with the M5.1 accumulator pattern, signal-handled
//! shutdown, per-tick log line. No actual entity state yet — the
//! `state.entities` table is empty and no `sim.entity.<id>.state`
//! publishes happen.
//!
//! Subsequent sub-steps add (in order):
//!   1. Single hardcoded ship: Jolt rigid body + buoyancy +
//!      `sim.entity.<id>.state` publish at 60 Hz.
//!   2. Multi-ship: ECS-style entity table with per-ship Jolt body.
//!   3. Player input subscription on `sim.entity.<player_id>.input`.
//!   4. Board / disembark transitions (M5.3 SoT pattern across the
//!      net per docs/08 §2A.2).
//!   5. Free-agent player capsule controller + water sampling.
//!
//! HA story per docs/08 §7.4: Phase 1 ship-sim is single-process.
//! Crash loses ~5 s of state. Phase 2+ adds JetStream KV checkpoints.
//!
//! The 60 Hz tick is locked per docs/02 §9 / docs/08 §5.2 (the auth
//! tick for the player + ship-sim layer). The tight-loop floor uses
//! a 5 ms `processIncomingTimeout` budget — same pattern as cell-mgr
//! per memory `feedback_nats_zig_poll_budget.md`.

const std = @import("std");
const nats = @import("nats");
const notatlas = @import("notatlas");

const sim_state = @import("state.zig");

const tick_period_ns: u64 = std.time.ns_per_s / 60; // 60 Hz auth tick

const Args = struct {
    /// Shard identifier — for now just a tag in log lines so multiple
    /// ship-sim instances are distinguishable. Sharding by
    /// entity-id range is Phase 2+ scaling work.
    shard: []const u8 = "0",
    nats_url: []const u8 = "nats://127.0.0.1:4222",
};

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip exe

    var out: Args = .{};
    var have_nats_url = false;
    var have_shard = false;
    errdefer {
        if (have_nats_url) allocator.free(out.nats_url);
        if (have_shard) allocator.free(out.shard);
    }
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--nats")) {
            const v = args.next() orelse return error.MissingArg;
            out.nats_url = try allocator.dupe(u8, v);
            have_nats_url = true;
        } else if (std.mem.eql(u8, a, "--shard")) {
            const v = args.next() orelse return error.MissingArg;
            out.shard = try allocator.dupe(u8, v);
            have_shard = true;
        } else {
            std.debug.print("ship-sim: unknown arg '{s}'\n", .{a});
            return error.BadArg;
        }
    }
    if (!have_nats_url) out.nats_url = try allocator.dupe(u8, out.nats_url);
    if (!have_shard) out.shard = try allocator.dupe(u8, out.shard);
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

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);
    defer allocator.free(args.nats_url);
    defer allocator.free(args.shard);
    try installSignalHandlers();

    std.debug.print("ship-sim [{s}]: connecting to {s}\n", .{ args.shard, args.nats_url });

    var client = try nats.Client.connect(allocator, .{
        .servers = &.{args.nats_url},
        .name = "ship-sim",
    });
    defer client.close();

    std.debug.print("ship-sim [{s}]: connected; tick rate 60 Hz; entity table empty (skeleton)\n", .{args.shard});

    var state = sim_state.State.init(allocator);
    defer state.deinit();

    // M5.1 fixed-step accumulator pattern: catch up rather than reset
    // so a long pause (log flush, GC) doesn't compress multiple
    // ticks into one — we get exactly one tick per period over the
    // long run. Spiral cap at 5 ticks/loop prevents the death-
    // spiral case where the loop falls so far behind it can't catch
    // up.
    const max_ticks_per_loop: u32 = 5;
    const start_ns: u64 = @intCast(std.time.nanoTimestamp());
    var last_tick_ns: u64 = start_ns;
    var tick_n: u64 = 0;
    var last_log_tick: u64 = 0;
    var last_log_ns: u64 = start_ns;

    while (g_running.load(.acquire)) {
        // 5 ms poll budget keeps the tight-loop floor at ~200 Hz,
        // well above the 60 Hz tick. Same pattern as cell-mgr.
        try client.processIncomingTimeout(5);
        try client.maybeSendPing();

        // Drive the tick if at least one period has elapsed; catch
        // up to N ticks if we fell behind.
        const now_ns: u64 = @intCast(std.time.nanoTimestamp());
        var ticks_due: u32 = 0;
        while (now_ns -% last_tick_ns >= tick_period_ns and ticks_due < max_ticks_per_loop) : (ticks_due += 1) {
            tick(&state, tick_n);
            tick_n += 1;
            last_tick_ns +%= tick_period_ns;
        }

        // Log once per second of wall clock. Tying this to wall
        // clock (not tick count) keeps the log readable when the
        // loop falls behind temporarily.
        if (now_ns -% last_log_ns >= std.time.ns_per_s) {
            const ticks_in_window = tick_n - last_log_tick;
            std.debug.print("[ship-sim {s}] {d} entities, {d} ticks last 1 s (target 60)\n", .{
                args.shard,      state.entityCount(),
                ticks_in_window,
            });
            last_log_tick = tick_n;
            last_log_ns = now_ns;
        }
    }

    std.debug.print("ship-sim [{s}]: shutting down at tick {d}\n", .{ args.shard, tick_n });
}

/// Per-tick work. Skeleton: nothing. Subsequent sub-steps add Jolt
/// stepping, buoyancy application, pose publishing.
fn tick(_: *sim_state.State, _: u64) void {}
