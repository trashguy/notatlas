//! spatial-index — entity ↔ cell membership oracle per docs/02 §1.4
//! / docs/08 §7.1.
//!
//! Subscribes to the global state firehose (`sim.entity.*.state`),
//! classifies each entity into a cell by floor() division of its
//! pos.x / pos.z, and emits cell-delta events on transitions:
//!
//!   idx.spatial.cell.<old>.delta { op: exit,  id, gen, x, y, z }
//!   idx.spatial.cell.<new>.delta { op: enter, id, gen, x, y, z }
//!
//! cell-mgr is the consumer of these deltas (per docs/08 §2.1).
//! Until this service shipped, cell-mgr's deltas were faked by the
//! cell-mgr-harness; this commit replaces that fake with real,
//! pose-driven deltas.
//!
//! v1 scope:
//!   - single-process (HA active/standby N=3 per docs/08 §7.1 is
//!     a sub-step — the "standbys subscribe to the same firehose
//!     and stay state-current" pattern works because cell-mgr is
//!     already JetStream-consumer-shaped).
//!   - cell-only deltas (no `idx.spatial.query` radius queries
//!     yet — that's a separate sub-step).
//!   - no aboard-ship gating (the boarded-tier / free-agent split
//!     per docs/08 §2A.2 lives at ship-sim's spawn / board /
//!     disembark transitions, not here).
//!   - generation tag passed through verbatim (entity recycling
//!     handling lives at consumers via stale-gen rejection).
//!
//! The 5 ms `processIncomingTimeout` budget matches cell-mgr +
//! ship-sim per memory `feedback_nats_zig_poll_budget.md`.

const std = @import("std");
const nats = @import("nats");
const notatlas = @import("notatlas");
const wire = @import("wire");

const idx_state = @import("state.zig");

/// 200 m default cell side: small enough that ship-sim's M1.5 grid
/// (6 × 5 ships at 30 m, half-extent ~75 m) sits in cell 0_0 but a
/// thrust input across ~200 m of travel produces a visible cell
/// transition. Production locked default is 4 km per docs/06 — set
/// via `--cell-side` when the world manifest grows multi-cell content.
const default_cell_side_m: f32 = 200.0;

/// Per-second log interval, matching cell-mgr's cadence so the
/// service mesh logs scan as one tape.
const log_interval_ns: u64 = std.time.ns_per_s;

const Args = struct {
    nats_url: []const u8 = "nats://127.0.0.1:4222",
    cell_side_m: f32 = default_cell_side_m,
};

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var out: Args = .{};
    var have_nats_url = false;
    errdefer if (have_nats_url) allocator.free(out.nats_url);
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--nats")) {
            const v = args.next() orelse return error.MissingArg;
            out.nats_url = try allocator.dupe(u8, v);
            have_nats_url = true;
        } else if (std.mem.eql(u8, a, "--cell-side")) {
            out.cell_side_m = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArg);
            if (out.cell_side_m <= 0) return error.BadArg;
        } else {
            std.debug.print("spatial-index: unknown arg '{s}'\n", .{a});
            return error.BadArg;
        }
    }
    if (!have_nats_url) out.nats_url = try allocator.dupe(u8, out.nats_url);
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
    try installSignalHandlers();

    std.debug.print("spatial-index: connecting to {s}; cell_side={d:.0} m\n", .{ args.nats_url, args.cell_side_m });

    var client = try nats.Client.connect(allocator, .{
        .servers = &.{args.nats_url},
        .name = "spatial-index",
    });
    defer client.close();

    const sub_state = try client.subscribe("sim.entity.*.state", .{});
    std.debug.print("spatial-index: subscribed to sim.entity.*.state\n", .{});

    var state = idx_state.State.init(allocator, args.cell_side_m);
    defer state.deinit();

    var deltas_total: u64 = 0;
    var msgs_total: u64 = 0;
    var last_log_ns: u64 = @intCast(std.time.nanoTimestamp());

    while (g_running.load(.acquire)) {
        try client.processIncomingTimeout(5);
        try client.maybeSendPing();

        const observed = drainStateSub(allocator, sub_state, &state, client) catch |err| blk: {
            std.debug.print("spatial-index: drain error ({s})\n", .{@errorName(err)});
            break :blk DrainStats{};
        };
        msgs_total += observed.msgs;
        deltas_total += observed.deltas;

        const now_ns: u64 = @intCast(std.time.nanoTimestamp());
        if (now_ns -% last_log_ns >= log_interval_ns) {
            std.debug.print(
                "[spatial-index] {d} entities tracked; {d} state msgs / {d} deltas in last 1 s\n",
                .{ state.entityCount(), msgs_total, deltas_total },
            );
            msgs_total = 0;
            deltas_total = 0;
            last_log_ns = now_ns;
        }
    }

    std.debug.print("spatial-index: shutting down ({d} entities tracked)\n", .{state.entityCount()});
}

const DrainStats = struct {
    msgs: u32 = 0,
    deltas: u32 = 0,
};

fn drainStateSub(
    allocator: std.mem.Allocator,
    sub: anytype,
    state: *idx_state.State,
    client: *nats.Client,
) !DrainStats {
    var stats: DrainStats = .{};
    while (sub.nextMsg()) |msg| {
        var owned = msg;
        defer owned.deinit();
        const payload = owned.payload orelse continue;
        const ent_id = wire.parseEntityIdFromSubject(owned.subject) catch continue;
        const parsed = wire.decodeState(allocator, payload) catch continue;
        defer parsed.deinit();
        stats.msgs += 1;

        const t = state.observe(ent_id, parsed.value.x, parsed.value.z) catch continue;
        if (t == null) continue;
        const transition = t.?;

        const pos_y = parsed.value.y;
        if (transition.old_cell) |old| {
            try publishDelta(allocator, client, old, .{
                .op = .exit,
                .id = ent_id,
                .generation = parsed.value.generation,
                .x = parsed.value.x,
                .y = pos_y,
                .z = parsed.value.z,
                .rot = parsed.value.rot,
                .vx = parsed.value.vx,
                .vy = parsed.value.vy,
                .vz = parsed.value.vz,
                .heading_rad = parsed.value.heading_rad,
            });
            stats.deltas += 1;
        }
        try publishDelta(allocator, client, transition.new_cell, .{
            .op = .enter,
            .id = ent_id,
            .generation = parsed.value.generation,
            .x = parsed.value.x,
            .y = pos_y,
            .z = parsed.value.z,
            .rot = parsed.value.rot,
            .vx = parsed.value.vx,
            .vy = parsed.value.vy,
            .vz = parsed.value.vz,
            .heading_rad = parsed.value.heading_rad,
        });
        stats.deltas += 1;
    }
    return stats;
}

fn publishDelta(
    allocator: std.mem.Allocator,
    client: *nats.Client,
    cell: idx_state.CellId,
    msg: wire.DeltaMsg,
) !void {
    var subj_buf: [64]u8 = undefined;
    const subj = try std.fmt.bufPrint(&subj_buf, "idx.spatial.cell.{d}_{d}.delta", .{ cell.x, cell.z });
    const buf = try wire.encodeDelta(allocator, msg);
    defer allocator.free(buf);
    try client.publish(subj, buf);
}
