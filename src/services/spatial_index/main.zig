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
//!   - radius queries: `idx.spatial.query.radius` (NATS
//!     request/reply). Brute-force O(N) over the per-entity pose
//!     table; primary consumer will be M9 lag-comp's hit detection
//!     once it lands. v1 caps result count at the request's
//!     `max_results` (default 256) to bound payload size.
//!   - aboard-ship gating: ship-sim publishes
//!     `idx.spatial.attach.<player_id>` on each board / disembark
//!     transition (docs/08 §2A.2). spatial-index subscribes and
//!     synthesizes the cell delta:
//!       board (`attached_ship_id != 0`)  → exit delta on the
//!           player's last cell + forget from the membership table
//!           so the player's state subject going silent doesn't
//!           leave a stale entry.
//!       disembark (`attached_ship_id == 0`) → enter delta at the
//!           reported world pose so cell-mgr resubscribes before
//!           ship-sim's next state msg lands.
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
    const sub_attach = try client.subscribe("idx.spatial.attach.*", .{});
    const sub_query = try client.subscribe("idx.spatial.query.radius", .{});
    std.debug.print(
        "spatial-index: subscribed to sim.entity.*.state, idx.spatial.attach.*, idx.spatial.query.radius\n",
        .{},
    );

    var state = idx_state.State.init(allocator, args.cell_side_m);
    defer state.deinit();

    var deltas_total: u64 = 0;
    var msgs_total: u64 = 0;
    var attach_msgs_total: u64 = 0;
    var queries_total: u64 = 0;
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

        const attach_drained = drainAttachSub(allocator, sub_attach, &state, client) catch |err| blk: {
            std.debug.print("spatial-index: attach drain error ({s})\n", .{@errorName(err)});
            break :blk DrainStats{};
        };
        attach_msgs_total += attach_drained.msgs;
        deltas_total += attach_drained.deltas;

        const queries_drained = drainQuerySub(allocator, sub_query, &state, client) catch |err| blk: {
            std.debug.print("spatial-index: query drain error ({s})\n", .{@errorName(err)});
            break :blk @as(u32, 0);
        };
        queries_total += queries_drained;

        const now_ns: u64 = @intCast(std.time.nanoTimestamp());
        if (now_ns -% last_log_ns >= log_interval_ns) {
            std.debug.print(
                "[spatial-index] {d} entities tracked; {d} state, {d} attach, {d} queries, {d} deltas / 1 s\n",
                .{ state.entityCount(), msgs_total, attach_msgs_total, queries_total, deltas_total },
            );
            msgs_total = 0;
            attach_msgs_total = 0;
            queries_total = 0;
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

        const t = state.observe(ent_id, .{ parsed.value.x, parsed.value.y, parsed.value.z }) catch continue;
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

/// Drain `idx.spatial.attach.*` and synthesize cell deltas for the
/// board / disembark transitions. Per docs/08 §2A.2:
///   - board   (`attached_ship_id != 0`): publish exit on the
///     player's last cell, forget from the table. The player's state
///     subject going silent will not leave a stale entry.
///   - disembark (`attached_ship_id == 0`): observe the player at
///     the reported world pose, publish enter on the resulting cell.
///     A subsequent `sim.entity.<player_id>.state` msg in the same
///     cell returns null from `observe` so we don't double-publish.
fn drainAttachSub(
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
        const player_id = wire.parsePlayerIdFromAttachSubject(owned.subject) catch continue;
        const parsed = wire.decodeAttach(allocator, payload) catch continue;
        defer parsed.deinit();
        if (parsed.value.player_id != player_id) continue; // subject/body mismatch — drop
        stats.msgs += 1;

        if (parsed.value.attached_ship_id != 0) {
            // Board: emit exit on last-known cell, drop from table.
            const old_cell = state.forget(player_id) orelse continue;
            try publishDelta(allocator, client, old_cell, .{
                .op = .exit,
                .id = player_id,
                .generation = 0,
                .x = parsed.value.x,
                .y = parsed.value.y,
                .z = parsed.value.z,
            });
            stats.deltas += 1;
        } else {
            // Disembark: classify the new world pose, emit enter.
            const t = state.observe(player_id, .{ parsed.value.x, parsed.value.y, parsed.value.z }) catch continue;
            if (t == null) continue;
            try publishDelta(allocator, client, t.?.new_cell, .{
                .op = .enter,
                .id = player_id,
                .generation = 0,
                .x = parsed.value.x,
                .y = parsed.value.y,
                .z = parsed.value.z,
            });
            stats.deltas += 1;
        }
    }
    return stats;
}

/// Maximum entities returned in a single radius-query reply. Caps
/// payload size at ~256 × 16 B-ish JSON ≈ 4 KB per reply, well below
/// NATS's 1 MB default. Requests with a higher `max_results` are
/// silently capped at this constant.
const max_query_results: u32 = 256;

/// Drain `idx.spatial.query.radius` requests and reply on each
/// caller's `reply_to` inbox. Brute-force O(N) — see
/// `state.queryRadius` for the query primitive. Requests with no
/// `reply_to` (a fire-and-forget mistake) are dropped silently;
/// malformed payloads are dropped silently. Returns the number of
/// queries handled this drain.
fn drainQuerySub(
    allocator: std.mem.Allocator,
    sub: anytype,
    state: *idx_state.State,
    client: *nats.Client,
) !u32 {
    var handled: u32 = 0;
    while (sub.nextMsg()) |msg| {
        var owned = msg;
        defer owned.deinit();
        const payload = owned.payload orelse continue;
        const reply_to = owned.reply_to orelse continue;
        const parsed = wire.decodeRadiusQuery(allocator, payload) catch continue;
        defer parsed.deinit();

        const cap_u32 = @min(parsed.value.max_results, max_query_results);
        const cap: usize = @intCast(cap_u32);

        var entries_buf: [max_query_results]idx_state.QueryEntry = undefined;
        const result = idx_state.queryRadius(
            state,
            .{ parsed.value.x, parsed.value.y, parsed.value.z },
            parsed.value.radius_m,
            entries_buf[0..cap],
        );

        // Translate idx_state.QueryEntry → wire.QueryEntry on the
        // way out so the spatial-index module stays
        // dependency-free.
        var wire_entries = try allocator.alloc(wire.QueryEntry, result.written);
        defer allocator.free(wire_entries);
        for (entries_buf[0..result.written], 0..) |e, i| {
            wire_entries[i] = .{ .id = e.id, .x = e.pos[0], .y = e.pos[1], .z = e.pos[2] };
        }

        const reply: wire.RadiusResultMsg = .{
            .truncated = result.truncated,
            .entries = wire_entries,
        };
        const buf = try wire.encodeRadiusResult(allocator, reply);
        defer allocator.free(buf);
        try client.publish(reply_to, buf);
        handled += 1;
    }
    return handled;
}
