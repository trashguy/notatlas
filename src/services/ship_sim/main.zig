//! ship-sim — 60 Hz rigid-body authority for ships AND free-agent
//! players per docs/08 §2A.
//!
//! Sub-step 1 scope (this commit): one hardcoded ship publishing
//! its pose on `sim.entity.<id>.state` at 60 Hz with stub orbital
//! motion. Closes the producer → cell-mgr fast-lane loop end-to-end
//! — cell-mgr's `relayState` already forwards inbound state msgs to
//! every visible sub. Stub motion stands in for real Jolt physics
//! while we get the wiring right.
//!
//! Subsequent sub-steps add (in order):
//!   2. Replace stub motion with Jolt rigid body + buoyancy via
//!      `physics` module, sourcing waves from `wave_query`.
//!   3. Multi-ship: ECS-style entity table with per-ship Jolt body.
//!   4. Player input subscription on `sim.entity.<player_id>.input`.
//!   5. Board / disembark transitions (M5.3 SoT pattern across the
//!      net per docs/08 §2A.2).
//!   6. Free-agent player capsule controller + water sampling.
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
const wire = @import("wire");

const sim_state = @import("state.zig");

const tick_period_ns: u64 = std.time.ns_per_s / 60; // 60 Hz auth tick

/// Hardcoded test ship parameters (sub-step 1). Will move into
/// `data/ships/*.yaml` + entity spawn protocol once spatial-index +
/// gateway are in.
const test_ship_id: u32 = 1;
const test_ship_generation: u16 = 0;
/// Orbital radius and angular velocity for the stub motion. Slow
/// enough that codec velocity range (±50 m/s) isn't exceeded —
/// 1 rad/s × 100 m = 100 m/s tangential which IS over the codec
/// limit, so we use a slower angular rate. 0.3 rad/s × 100 m = 30
/// m/s, comfortably inside.
const test_orbit_radius_m: f32 = 100.0;
const test_orbit_omega: f32 = 0.3; // rad/s

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

    std.debug.print("ship-sim [{s}]: connected; tick rate 60 Hz\n", .{args.shard});

    var state = sim_state.State.init(allocator);
    defer state.deinit();

    // Spawn the test ship. Sub-step 1 hardcodes one ship; multi-
    // ship + spatial-index spawn protocol lands in sub-step 3.
    try state.entities.put(test_ship_id, .{
        .id = .{ .id = test_ship_id, .generation = test_ship_generation },
        .kind = .ship,
        .pose = .{
            .pos = .{ test_orbit_radius_m, 0, 0 },
            .rot = .{ 0, 0, 0, 1 },
            .vel = .{ 0, 0, 0 },
        },
    });
    std.debug.print("ship-sim [{s}]: spawned test ship id={d} gen={d}\n", .{
        args.shard, test_ship_id, test_ship_generation,
    });

    // Pre-format the publish subject once — `sim.entity.1.state`
    // for sub-step 1's single-ship case. With multi-ship the
    // subject formats per-ship per-tick.
    var subj_buf: [64]u8 = undefined;
    const state_subj = try std.fmt.bufPrint(&subj_buf, "sim.entity.{d}.state", .{test_ship_id});

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
            try tick(allocator, client, &state, state_subj, tick_n);
            tick_n += 1;
            last_tick_ns +%= tick_period_ns;
        }

        // Log once per second of wall clock. Tying this to wall
        // clock (not tick count) keeps the log readable when the
        // loop falls behind temporarily.
        if (now_ns -% last_log_ns >= std.time.ns_per_s) {
            const ticks_in_window = tick_n - last_log_tick;
            std.debug.print("[ship-sim {s}] {d} entities, {d} ticks last 1 s (target 60), {d} state-pubs\n", .{
                args.shard,      state.entityCount(),
                ticks_in_window, ticks_in_window * state.entityCount(),
            });
            last_log_tick = tick_n;
            last_log_ns = now_ns;
        }
    }

    std.debug.print("ship-sim [{s}]: shutting down at tick {d}\n", .{ args.shard, tick_n });
}

/// Per-tick work — sub-step 1: stub orbital motion + state publish.
/// Subsequent sub-steps replace the motion update with a Jolt
/// `system.step(dt)` + `Buoyancy.step` over wave_query.
fn tick(
    allocator: std.mem.Allocator,
    client: *nats.Client,
    state: *sim_state.State,
    state_subj: []const u8,
    tick_n: u64,
) !void {
    // Stub orbital motion: ship circles the origin at radius 100 m,
    // 0.3 rad/s. Tangential velocity 30 m/s — well inside the
    // codec ±50 m/s velocity range. tick_n × dt = elapsed sim time.
    const t: f32 = @as(f32, @floatFromInt(tick_n)) / 60.0;
    const angle = test_orbit_omega * t;
    const x = test_orbit_radius_m * @cos(angle);
    const z = test_orbit_radius_m * @sin(angle);
    const vx = -test_orbit_radius_m * test_orbit_omega * @sin(angle);
    const vz = test_orbit_radius_m * test_orbit_omega * @cos(angle);
    // Heading along the orbit tangent (90° ahead of the radial).
    const heading = angle + std.math.pi / 2.0;

    if (state.entities.getPtr(test_ship_id)) |e| {
        e.pose.pos = .{ x, 0, z };
        e.pose.vel = .{ vx, 0, vz };
    }

    const msg: wire.StateMsg = .{
        .generation = test_ship_generation,
        .x = x,
        .y = 0,
        .z = z,
        // Yaw quaternion around +y to match heading.
        .rot = .{ 0, @sin(angle / 2.0), 0, @cos(angle / 2.0) },
        .vx = vx,
        .vy = 0,
        .vz = vz,
        .heading_rad = heading,
    };
    const buf = try wire.encodeState(allocator, msg);
    defer allocator.free(buf);
    try client.publish(state_subj, buf);
}
