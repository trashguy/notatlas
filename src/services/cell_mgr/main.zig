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
const fanout_mod = @import("fanout.zig");
const notatlas = @import("notatlas");
const replication = notatlas.replication;
const pose_codec = notatlas.pose_codec;

const slow_tick_period_ns: u64 = std.time.ns_per_s / 30; // 30 Hz slow-lane (clusters)
const fast_tick_period_ns: u64 = std.time.ns_per_s / 60; // 60 Hz fast-lane (batched state msgs)

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
    // Fast-lane: per-entity state stream. Wildcard subscription pulls
    // every entity's state msgs in this cluster — cell-mgr decides
    // per-entity which sub gets the relay. Production scoping (only
    // entities IN this cell) lands when spatial-index publishes a
    // per-cell aggregate stream; for M-stack we filter by entity-
    // table membership in the relay handler.
    const sub_state = try client.subscribe("sim.entity.*.state", .{});
    // Fire events per docs/03 §8 — broadcast to subs at visual+
    // tier from the muzzle. Wildcard subscription pulls all
    // weapons' fire events; per-fire geometry filter happens in
    // `Fanout.relayFire`.
    const sub_fire = try client.subscribe("sim.entity.*.fire", .{});

    std.debug.print("cell-mgr [{d}_{d}]: subscribed to {s}, {s}, {s}, sim.entity.*.state, sim.entity.*.fire\n", .{ args.cell_x, args.cell_y, delta_subj, sub_subj, unsub_subj });

    var state = cm_state.State.init(allocator);
    defer state.deinit();

    var fanout = fanout_mod.Fanout.init(allocator, replication.TierThresholds.default);
    defer fanout.deinit();

    var nats_sink_ctx: NatsSinkCtx = .{ .client = client };
    const sink: fanout_mod.Sink = .{ .ctx = &nats_sink_ctx, .publishFn = NatsSinkCtx.publish };
    // Separate sink for fire events — routes to `gw.client.<id>.fire`
    // (vs the cmd subject for state/cluster) so receivers parse the
    // two streams independently.
    var nats_fire_sink_ctx: NatsFireSinkCtx = .{ .client = client };
    const fire_sink: fanout_mod.Sink = .{ .ctx = &nats_fire_sink_ctx, .publishFn = NatsFireSinkCtx.publish };

    const start_ns: u64 = @intCast(std.time.nanoTimestamp());
    var last_slow_ns: u64 = start_ns;
    var last_fast_ns: u64 = start_ns;
    var slow_tick_n: u64 = 0;
    var state_msgs_since_log: u64 = 0;
    var fast_pushes_since_log: u64 = 0;
    var fast_publishes_since_log: u64 = 0;
    var fire_msgs_since_log: u64 = 0;
    var fire_forwards_since_log: u64 = 0;

    while (g_running.load(.acquire)) {
        // 5 ms poll budget keeps the tight-loop floor at ~200 Hz — well
        // above both ticks (60 Hz fast / 30 Hz slow) so the deadline
        // checks below see ~3 polls per fast window. nats-zig v0.2.2
        // introduced processIncomingTimeout; pre-v0.2.2 only had the
        // 100 ms hardcoded path which capped the loop at ~10 Hz.
        try client.processIncomingTimeout(5);

        try drainDeltaSub(allocator, sub_delta, &state);
        try drainSubscribeSub(allocator, sub_sub, &state, &fanout, .enter);
        try drainSubscribeSub(allocator, sub_unsub, &state, &fanout, .exit);
        const drained = try drainStateSub(allocator, sub_state, &state, &fanout);
        state_msgs_since_log += drained.msgs;
        fast_pushes_since_log += drained.pushes;
        const fire_drained = try drainFireSub(allocator, sub_fire, &state, &fanout, fire_sink);
        fire_msgs_since_log += fire_drained.msgs;
        fire_forwards_since_log += fire_drained.forwards;

        try client.maybeSendPing();

        const now_ns: u64 = @intCast(std.time.nanoTimestamp());

        // Fast lane: 60 Hz batched flush of accumulated state msgs.
        if (now_ns -% last_fast_ns >= fast_tick_period_ns) {
            fast_publishes_since_log += try fanout.flushBatches(sink);
            last_fast_ns +%= fast_tick_period_ns;
        }

        // Slow lane: 30 Hz cluster pass. Catch-up rather than reset —
        // if we missed several tick boundaries (long log flush, GC
        // pause) we still publish exactly one tick per period.
        if (now_ns -% last_slow_ns >= slow_tick_period_ns) {
            slow_tick_n += 1;
            const slow_publishes = try fanout.runTick(&state, sink);
            std.debug.print("[cell {d}_{d}] tick {d}: {d} ents, {d} subs, {d} slow-pubs, {d} state-msgs in / {d} pushed / {d} batched-pubs, {d} fires in / {d} fire-fwds (since prev log)\n", .{
                args.cell_x,          args.cell_y,             slow_tick_n,
                state.entityCount(),  state.subscriberCount(), slow_publishes,
                state_msgs_since_log, fast_pushes_since_log,   fast_publishes_since_log,
                fire_msgs_since_log,  fire_forwards_since_log,
            });
            state_msgs_since_log = 0;
            fast_pushes_since_log = 0;
            fast_publishes_since_log = 0;
            fire_msgs_since_log = 0;
            fire_forwards_since_log = 0;
            last_slow_ns +%= slow_tick_period_ns;
        }
    }

    std.debug.print("cell-mgr [{d}_{d}]: shutting down\n", .{ args.cell_x, args.cell_y });
}

/// NATS-backed Sink: formats `gw.client.<id>.cmd` into a stack
/// buffer, then publishes via the supplied client. No per-tick allocs
/// — the subject buffer is a fixed array, and nats-zig's publish path
/// uses its own internal write buffer.
const NatsSinkCtx = struct {
    client: *nats.Client,

    fn publish(ctx: *anyopaque, client_id: u64, payload: []const u8) anyerror!void {
        const self: *NatsSinkCtx = @ptrCast(@alignCast(ctx));
        var subject_buf: [fanout_mod.max_subject_len]u8 = undefined;
        const subject = try std.fmt.bufPrint(&subject_buf, "gw.client.{d}.cmd", .{client_id});
        try self.client.publish(subject, payload);
    }
};

/// NATS-backed sink for fire events — writes to `gw.client.<id>.fire`
/// instead of `.cmd` so receivers parse the event stream
/// independently of the state-update stream.
const NatsFireSinkCtx = struct {
    client: *nats.Client,

    fn publish(ctx: *anyopaque, client_id: u64, payload: []const u8) anyerror!void {
        const self: *NatsFireSinkCtx = @ptrCast(@alignCast(ctx));
        var subject_buf: [fanout_mod.max_subject_len]u8 = undefined;
        const subject = try std.fmt.bufPrint(&subject_buf, "gw.client.{d}.fire", .{client_id});
        try self.client.publish(subject, payload);
    }
};

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

/// Drain `sim.entity.*.state` msgs: parse the entity id from each
/// subject, decode the JSON payload, update the entity's pose in
/// `state` if known (no-op otherwise — cross-cell entities aren't in
/// our table), then call `relayState` to **append** the record into
/// every visual+ subscriber's pending batch. Actual NATS publishes
/// happen in the 60 Hz fast-lane flush tick. Returns counters so the
/// per-tick log can show fast-lane volume.
const StateDrainCounts = struct { msgs: u64, pushes: u64 };

fn drainStateSub(
    allocator: std.mem.Allocator,
    sub: *nats.Subscription,
    state: *cm_state.State,
    fanout: *fanout_mod.Fanout,
) !StateDrainCounts {
    var msgs: u64 = 0;
    var pushes: u64 = 0;
    while (sub.nextMsg()) |msg| {
        var owned = msg;
        defer owned.deinit();
        const ent_id_raw = wire.parseEntityIdFromSubject(owned.subject) catch |err| {
            std.debug.print("cell-mgr: bad state subject ({s}): {s}\n", .{ @errorName(err), owned.subject });
            continue;
        };
        const parsed = wire.decodeState(allocator, owned.payload orelse "") catch |err| {
            std.debug.print("cell-mgr: bad state payload ({s}): {s}\n", .{ @errorName(err), owned.payload orelse "" });
            continue;
        };
        defer parsed.deinit();
        msgs += 1;

        // Update local entity table if the entity belongs to this
        // cell. Returns false for unknown ids (cross-cell case) and
        // for stale-generation msgs — neither blocks the relay.
        // Stale-generation gating happens inside relayState so it
        // applies uniformly across cell-bounded and cross-cell cases.
        _ = state.applyState(ent_id_raw, parsed.value);

        const ent_id: replication.EntityId = .{ .id = ent_id_raw, .generation = parsed.value.generation };
        const pose: pose_codec.Pose = .{
            .pos = .{ parsed.value.x, parsed.value.y, parsed.value.z },
            .rot = parsed.value.rot,
            .vel = .{ parsed.value.vx, parsed.value.vy, parsed.value.vz },
        };
        pushes += try fanout.relayState(state, ent_id, pose, null);
    }
    return .{ .msgs = msgs, .pushes = pushes };
}

/// Drain `sim.entity.*.fire` msgs and broadcast each to subs at
/// visual+ tier from the muzzle pose (per docs/03 §8). Per-fire
/// payload is the raw inbound JSON `wire.FireMsg` — forwarded byte-
/// for-byte. Unlike state msgs there's no batching: fires are sparse
/// one-shot events. Returns counters so the per-tick log shows
/// fire-lane volume.
const FireDrainCounts = struct { msgs: u64, forwards: u64 };

fn drainFireSub(
    allocator: std.mem.Allocator,
    sub: *nats.Subscription,
    state: *cm_state.State,
    fanout: *fanout_mod.Fanout,
    fire_sink: fanout_mod.Sink,
) !FireDrainCounts {
    var msgs: u64 = 0;
    var forwards: u64 = 0;
    while (sub.nextMsg()) |msg| {
        var owned = msg;
        defer owned.deinit();
        const payload = owned.payload orelse continue;
        // Decode just enough to extract the muzzle position for
        // the geometry filter; the full FireMsg JSON forwards
        // byte-for-byte to receivers.
        const parsed = wire.decodeFire(allocator, payload) catch |err| {
            std.debug.print("cell-mgr: bad fire payload ({s}): {s}\n", .{ @errorName(err), payload });
            continue;
        };
        defer parsed.deinit();
        msgs += 1;

        const muzzle_pos: [3]f32 = .{ parsed.value.mx, parsed.value.my, parsed.value.mz };
        forwards += try fanout.relayFire(state, muzzle_pos, payload, fire_sink);
    }
    return .{ .msgs = msgs, .forwards = forwards };
}

/// `expected_op` is the op these messages should carry — the subject
/// already encoded the intent (subscribe vs unsubscribe), so we
/// override whatever the harness put in the body. Keeps the
/// subscribe/unsubscribe paths from getting swapped by a buggy
/// publisher. Mirrors state changes into the fanout buffer pool so
/// runTick can find a pre-grown buffer for every subscriber.
fn drainSubscribeSub(allocator: std.mem.Allocator, sub: *nats.Subscription, state: *cm_state.State, fanout: *fanout_mod.Fanout, expected_op: wire.Op) !void {
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
        const changed = try state.applySubscribe(msg_value);
        if (changed) switch (expected_op) {
            .enter => try fanout.ensureSubscriber(msg_value.client_id),
            .exit => fanout.removeSubscriber(msg_value.client_id),
        };
    }
}
