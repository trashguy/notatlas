//! ai-sim — AI ship decision service per docs/09-ai-sim.md.
//!
//! Decisions only. ai-sim does NOT own physics — AI ships physically
//! live in ship-sim like any other ship. Per architecture memory
//! `architecture_ai_sim_decisions_only.md`: ai-sim's only output is
//! `sim.entity.<ai_ship_id>.input` at 20 Hz, indistinguishable from
//! gateway's player input. ship-sim has no AI-specific code path.
//!
//! v1 scope (this commit = step 5 / docs/09 §14, the service skeleton):
//!   - 20 Hz fixed-step tick loop (matches docs/02 §9 / docs/09 §3).
//!   - One cohort, one Lua VM (docs/09 §13 q1: cohort-per-process is
//!     the v1 default; cell-affinity sharding is post-v1).
//!   - Subscriptions:
//!       sim.entity.*.state    — world snapshot firehose
//!       env.cell.*.wind       — wind samples (drained, not yet used —
//!                                step 6 perception API consumes)
//!   - Loads `data/ai/<archetype>.yaml` on boot; instantiates a
//!     `bt.Tree` per AI ship (`--ai-ship <seq>` flags, repeatable).
//!   - Loads `data/ai/<archetype>.lua` into the cohort VM; leaves
//!     resolve as Lua globals (see dispatcher.zig).
//!   - mtime-poll file watcher (1 Hz) reloads archetype + Lua on
//!     change. Polling, not inotify — keeps the watcher portable to
//!     macOS/Windows hosts and avoids an additional syscall surface
//!     (per `build_windows_cross.md` we want the service binary to
//!     stay cross-clean).
//!
//! Non-scope this commit (step 6+):
//!   - Perception ctx (own_pose, own_vel, nearest_enemy, threats[8])
//!     pushed into the dispatcher before each tree.tick. Step 6 PR.
//!   - Batched `idx.spatial.query.radius` per AI per tick. Step 6.
//!   - Real archetype Lua (pirate_sloop.lua). Step 6 ships the actual
//!     leaves; step 5 ships placeholders so the dispatcher exercises
//!     end-to-end.
//!   - Cross-cell handoff (one cell only for v0).
//!   - Damage / sinking (separate milestone).

const std = @import("std");
const nats = @import("nats");
const notatlas = @import("notatlas");
const wire = @import("wire");
const lua = @import("lua");

const ai_state = @import("state.zig");
const dispatcher_mod = @import("dispatcher.zig");
const perception = @import("perception.zig");

const bt = notatlas.bt;
const bt_loader = notatlas.bt_loader;

const tick_period_ns: u64 = std.time.ns_per_s / 20; // 20 Hz auth tick
const log_interval_ns: u64 = std.time.ns_per_s;
const watcher_interval_ns: u64 = std.time.ns_per_s; // mtime poll cadence

/// Default cell side for ctx.cell derivation. Matches spatial-index's
/// dev default (200 m) — see `src/services/spatial_index/main.zig`.
/// Production uses 4 km per docs/06; flag to override when the world
/// manifest scales up.
const default_cell_side_m: f32 = 200.0;
/// docs/09 §3 fixed-step delta for the perception ctx.
const tick_dt: f32 = 1.0 / 20.0;

const Args = struct {
    nats_url: []const u8 = "nats://127.0.0.1:4222",
    archetype_path: []const u8 = "data/ai/pirate_sloop.yaml",
    leaves_path: []const u8 = "data/ai/pirate_sloop.lua",
    cell_side_m: f32 = default_cell_side_m,
    /// Per-kind sequence numbers (low 24 bits) of ships to drive.
    /// Top byte is `Kind.ship` (0x01) — composed at runtime.
    /// Default: ship#3 (free in drive_ship.sh's 5-ship spawn).
    ai_ship_seqs: []const u32 = &.{3},
};

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var out: Args = .{};
    var have_nats_url = false;
    var have_archetype = false;
    var have_leaves = false;
    var seqs: std.ArrayListUnmanaged(u32) = .{};
    errdefer seqs.deinit(allocator);

    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--nats")) {
            const v = args.next() orelse return error.MissingArg;
            out.nats_url = try allocator.dupe(u8, v);
            have_nats_url = true;
        } else if (std.mem.eql(u8, a, "--archetype")) {
            const v = args.next() orelse return error.MissingArg;
            out.archetype_path = try allocator.dupe(u8, v);
            have_archetype = true;
        } else if (std.mem.eql(u8, a, "--leaves")) {
            const v = args.next() orelse return error.MissingArg;
            out.leaves_path = try allocator.dupe(u8, v);
            have_leaves = true;
        } else if (std.mem.eql(u8, a, "--cell-side")) {
            out.cell_side_m = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArg);
            if (out.cell_side_m <= 0) return error.BadArg;
        } else if (std.mem.eql(u8, a, "--ai-ship")) {
            const v = args.next() orelse return error.MissingArg;
            const seq = try std.fmt.parseInt(u32, v, 10);
            if (seq > notatlas.entity_kind.seq_mask) return error.BadArg;
            try seqs.append(allocator, seq);
        } else {
            std.debug.print("ai-sim: unknown arg '{s}'\n", .{a});
            return error.BadArg;
        }
    }
    if (!have_nats_url) out.nats_url = try allocator.dupe(u8, out.nats_url);
    if (!have_archetype) out.archetype_path = try allocator.dupe(u8, out.archetype_path);
    if (!have_leaves) out.leaves_path = try allocator.dupe(u8, out.leaves_path);
    if (seqs.items.len > 0) {
        out.ai_ship_seqs = try seqs.toOwnedSlice(allocator);
    } else {
        out.ai_ship_seqs = try allocator.dupe(u32, out.ai_ship_seqs);
    }
    return out;
}

fn freeArgs(allocator: std.mem.Allocator, a: *Args) void {
    allocator.free(a.nats_url);
    allocator.free(a.archetype_path);
    allocator.free(a.leaves_path);
    allocator.free(a.ai_ship_seqs);
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

/// Load a Lua source file into `vm`. Defines whatever globals the
/// chunk declares; subsequent `getglobal(L, "leaf_name")` resolves
/// them. Equivalent of `lua.Vm.doString` but reading from a file —
/// not yet promoted into `lua_bind.zig` because ai-sim is the first
/// caller; lift it when a second caller appears (recipes per
/// docs/05).
fn loadLuaFile(vm: *lua.Vm, path: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len + 1 > path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = path_buf[0..path.len :0].ptr;

    const rc_load = lua.c.luaL_loadfilex(vm.L, path_z, null);
    if (rc_load != lua.c.OK) {
        if (lua.c.tostring(vm.L, -1)) |s| {
            std.debug.print("ai-sim: lua load error for '{s}': {s}\n", .{ path, std.mem.span(s) });
        }
        lua.c.pop(vm.L, 1);
        return error.LuaLoadFailed;
    }
    const rc_run = lua.c.pcall(vm.L, 0, 0, 0);
    if (rc_run != lua.c.OK) {
        if (lua.c.tostring(vm.L, -1)) |s| {
            std.debug.print("ai-sim: lua exec error for '{s}': {s}\n", .{ path, std.mem.span(s) });
        }
        lua.c.pop(vm.L, 1);
        return error.LuaExecFailed;
    }
}

fn statMtime(path: []const u8) !i128 {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const stat = try f.stat();
    return stat.mtime;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try parseArgs(allocator);
    defer freeArgs(allocator, &args);
    try installSignalHandlers();

    std.debug.print(
        "ai-sim: connecting to {s}; archetype={s}; leaves={s}; ai_ships={d}\n",
        .{ args.nats_url, args.archetype_path, args.leaves_path, args.ai_ship_seqs.len },
    );

    // ----- NATS connect -----
    var client = try nats.Client.connect(allocator, .{
        .servers = &.{args.nats_url},
        .name = "ai-sim",
    });
    defer client.close();

    const sub_state = try client.subscribe("sim.entity.*.state", .{});
    const sub_wind = try client.subscribe("env.cell.*.wind", .{});
    std.debug.print("ai-sim: subscribed to sim.entity.*.state, env.cell.*.wind\n", .{});

    // ----- archetype + Lua load -----
    var archetype = try bt_loader.loadFromFile(allocator, args.archetype_path);
    defer archetype.deinit();
    std.debug.print(
        "ai-sim: loaded archetype '{s}' ({d} nodes, perception_radius={d} m)\n",
        .{ archetype.archetype, archetype.nodes.len, archetype.perception_radius },
    );

    var vm = try lua.Vm.init();
    defer vm.deinit();
    try loadLuaFile(&vm, args.leaves_path);
    std.debug.print("ai-sim: lua leaves loaded from {s}\n", .{args.leaves_path});

    // init() stashes a self-pointer in the Lua registry so the
    // registered set_thrust/set_steer/set_fire helpers can find their
    // target. That stash captures the in-flight stack address — restash
    // once `disp` is in its final slot here so the helpers see the
    // right pointer for the rest of the process lifetime.
    var disp = dispatcher_mod.LuaDispatcher.init(&vm);
    disp.restash();

    // ----- cohort + AIs -----
    var cohort = ai_state.Cohort.init(allocator);
    defer cohort.deinit();

    for (args.ai_ship_seqs) |seq| {
        const ship_id = notatlas.entity_kind.pack(.ship, seq);
        const tree = try bt_loader.instantiate(allocator, &archetype);
        try cohort.addAi(ship_id, tree);
        std.debug.print("ai-sim: registered AI ship id=0x{X:0>8} (seq={d})\n", .{ ship_id, seq });
    }

    // ----- watcher state -----
    var archetype_mtime = statMtime(args.archetype_path) catch 0;
    var leaves_mtime = statMtime(args.leaves_path) catch 0;

    // ----- tick loop (mirrors ship-sim's M5.1 fixed-step accumulator) -----
    const max_ticks_per_loop: u32 = 5;
    const start_ns: u64 = @intCast(std.time.nanoTimestamp());
    var last_tick_ns: u64 = start_ns;
    var tick_n: u64 = 0;
    var last_log_ns: u64 = start_ns;
    var last_log_tick: u64 = 0;
    var last_watcher_ns: u64 = start_ns;
    var input_pubs_total: u64 = 0;
    var state_msgs_total: u64 = 0;
    var wind_msgs_total: u64 = 0;

    while (g_running.load(.acquire)) {
        try client.processIncomingTimeout(5);
        try client.maybeSendPing();

        // Drain inbound traffic. Both subs feed the cohort's world
        // model — we don't act on wind yet, but we still drain so
        // messages don't pile up in the client buffer.
        state_msgs_total += try drainStateSub(allocator, sub_state, &cohort, tick_n);
        wind_msgs_total += drainWindSub(sub_wind);

        const now_ns: u64 = @intCast(std.time.nanoTimestamp());
        var ticks_due: u32 = 0;
        while (now_ns -% last_tick_ns >= tick_period_ns and ticks_due < max_ticks_per_loop) : (ticks_due += 1) {
            input_pubs_total += try tickCohort(
                allocator,
                client,
                &cohort,
                &disp,
                tick_n,
                archetype.perception_radius,
                args.cell_side_m,
            );
            tick_n += 1;
            last_tick_ns +%= tick_period_ns;
        }

        // Polling watcher — checks mtime once a second. Reload is
        // best-effort; on failure we keep running with the old
        // archetype/leaves and log loudly.
        if (now_ns -% last_watcher_ns >= watcher_interval_ns) {
            try maybeReload(
                allocator,
                args,
                &cohort,
                &archetype,
                &vm,
                &archetype_mtime,
                &leaves_mtime,
            );
            last_watcher_ns = now_ns;
        }

        if (now_ns -% last_log_ns >= log_interval_ns) {
            const ticks_in_window = tick_n - last_log_tick;
            std.debug.print(
                "[ai-sim] {d} ticks last 1 s (target 20); {d} ais; {d} world ents; {d} state-msgs, {d} wind-msgs, {d} input-pubs / 1 s\n",
                .{ ticks_in_window, cohort.aiCount(), cohort.entityCount(), state_msgs_total, wind_msgs_total, input_pubs_total },
            );
            last_log_tick = tick_n;
            last_log_ns = now_ns;
            state_msgs_total = 0;
            wind_msgs_total = 0;
            input_pubs_total = 0;
        }
    }

    std.debug.print("ai-sim: shutting down at tick {d}\n", .{tick_n});
}

fn drainStateSub(
    allocator: std.mem.Allocator,
    sub: anytype,
    cohort: *ai_state.Cohort,
    tick: u64,
) !u64 {
    var count: u64 = 0;
    while (sub.nextMsg()) |msg| {
        var owned = msg;
        defer owned.deinit();
        const payload = owned.payload orelse continue;
        const ent_id = wire.parseEntityIdFromSubject(owned.subject) catch continue;
        const parsed = wire.decodeState(allocator, payload) catch continue;
        defer parsed.deinit();
        cohort.observeEntity(ent_id, parsed.value, tick) catch continue;
        count += 1;
    }
    return count;
}

fn drainWindSub(sub: anytype) u64 {
    // Step-5 stub: drain to keep the buffer empty, but env service
    // doesn't exist yet so payloads aren't decoded. Step 6 plugs
    // wind into the perception ctx.
    var count: u64 = 0;
    while (sub.nextMsg()) |msg| {
        var owned = msg;
        defer owned.deinit();
        count += 1;
    }
    return count;
}

/// One full tick of the cohort: build perception, BT step every AI,
/// publish any pending input. Returns the number of inputs published
/// this tick.
///
/// AIs whose own pose hasn't yet been observed on `sim.entity.*.state`
/// are skipped this tick — their leaves can't read a meaningful
/// `ctx.own_pose` yet. Same shape as a missed gateway input: ship-sim
/// keeps last-latched (which is "no input") until ai-sim catches up.
fn tickCohort(
    allocator: std.mem.Allocator,
    client: *nats.Client,
    cohort: *ai_state.Cohort,
    disp: *dispatcher_mod.LuaDispatcher,
    tick: u64,
    perception_radius_m: u32,
    cell_side_m: f32,
) !u64 {
    const now_ms: i64 = @intCast(@divFloor(@as(i128, tick) * @as(i128, std.time.ns_per_s / 20), std.time.ns_per_ms));
    var bt_ctx: bt.TickCtx = .{ .now_ms = now_ms, .dispatcher = disp.dispatcher() };

    var pubs: u64 = 0;
    for (cohort.ais.items) |*ai| {
        const p_ctx = perception.build(cohort, .{
            .ai_id = ai.id,
            .perception_radius_m = @floatFromInt(perception_radius_m),
            .cell_side_m = cell_side_m,
            .tick = tick,
            .dt = tick_dt,
        }) orelse continue;

        disp.beginAi(ai, &p_ctx);
        _ = ai.tree.tick(&bt_ctx);
        disp.endAi();

        if (ai.pending_input) |input| {
            try publishInput(allocator, client, ai.id, input);
            ai.pending_input = null;
            pubs += 1;
        }
    }
    return pubs;
}

fn publishInput(
    allocator: std.mem.Allocator,
    client: *nats.Client,
    id: u32,
    msg: wire.InputMsg,
) !void {
    var subj_buf: [64]u8 = undefined;
    const subj = try std.fmt.bufPrint(&subj_buf, "sim.entity.{d}.input", .{id});
    const buf = try wire.encodeInput(allocator, msg);
    defer allocator.free(buf);
    try client.publish(subj, buf);
}

/// mtime-poll watcher. If either the archetype YAML or the Lua
/// leaves file has changed since last poll, reload it. Reloads are
/// independent: a Lua-only edit doesn't rebuild trees, an
/// archetype-only edit doesn't reload Lua. Best-effort: on failure
/// we log and keep the old state.
fn maybeReload(
    allocator: std.mem.Allocator,
    args: Args,
    cohort: *ai_state.Cohort,
    archetype: *bt_loader.Archetype,
    vm: *lua.Vm,
    archetype_mtime: *i128,
    leaves_mtime: *i128,
) !void {
    if (statMtime(args.archetype_path)) |new_mt| {
        if (new_mt != archetype_mtime.*) {
            archetype_mtime.* = new_mt;
            reloadArchetype(allocator, args.archetype_path, cohort, archetype) catch |err| {
                std.debug.print("ai-sim: archetype reload failed ({s}); keeping previous\n", .{@errorName(err)});
            };
        }
    } else |_| {}

    if (statMtime(args.leaves_path)) |new_mt| {
        if (new_mt != leaves_mtime.*) {
            leaves_mtime.* = new_mt;
            loadLuaFile(vm, args.leaves_path) catch |err| {
                std.debug.print("ai-sim: lua reload failed ({s}); keeping previous\n", .{@errorName(err)});
                return;
            };
            std.debug.print("ai-sim: lua leaves reloaded ({s})\n", .{args.leaves_path});
        }
    } else |_| {}
}

fn reloadArchetype(
    allocator: std.mem.Allocator,
    path: []const u8,
    cohort: *ai_state.Cohort,
    archetype: *bt_loader.Archetype,
) !void {
    var fresh = try bt_loader.loadFromFile(allocator, path);
    errdefer fresh.deinit();

    // Rebuild every AI's Tree against the new archetype before we
    // tear down the old one. Per-AI cooldown / repeat state resets —
    // the alternative (mapping by node id) is brittle when the YAML
    // grows nodes.
    for (cohort.ais.items) |*ai| {
        const new_tree = try bt_loader.instantiate(allocator, &fresh);
        ai.tree.deinit(allocator);
        ai.tree = new_tree;
    }

    archetype.deinit();
    archetype.* = fresh;
    std.debug.print("ai-sim: archetype reloaded ({s}, {d} nodes)\n", .{ path, archetype.nodes.len });
}
