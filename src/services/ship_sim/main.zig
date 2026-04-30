//! ship-sim — 60 Hz rigid-body authority for ships AND free-agent
//! players per docs/08 §2A.
//!
//! Sub-step 2 scope: replace stub orbital motion with Jolt rigid body
//! + buoyancy against the deterministic wave kernel. Same M3 init
//! pattern the sandbox runs (src/main.zig:130-200) — ship is a Jolt
//! dynamic box, per-tick `Buoyancy.step` applies Archimedes + drag at
//! sample points, then `phys.step(1/60, 1)` integrates. Pose is read
//! back from Jolt and published on `sim.entity.<id>.state`.
//!
//! This is the first time engine subsystems (physics + buoyancy +
//! wave_query) run headless outside the sandbox. The same scalar wave
//! field the GPU raymarches in M2 is the one buoyancy queries here —
//! load-bearing per `architecture_ships_on_water` memory.
//!
//! Subsequent sub-steps:
//!   3. Multi-ship: ECS-style entity table with per-ship Jolt body.
//!   4. Player input subscription on `sim.entity.<player_id>.input`.
//!   5. Board / disembark transitions (M5.3 SoT pattern).
//!   6. Free-agent player capsule controller + water sampling.
//!
//! HA story per docs/08 §7.4: Phase 1 ship-sim is single-process.
//! Crash loses ~5 s of state. Phase 2+ adds JetStream KV checkpoints.
//!
//! The 60 Hz tick is locked per docs/02 §9 / docs/08 §5.2. The tight-
//! loop floor uses a 5 ms `processIncomingTimeout` budget — same
//! pattern as cell-mgr per memory `feedback_nats_zig_poll_budget.md`.

const std = @import("std");
const nats = @import("nats");
const notatlas = @import("notatlas");
const physics = @import("physics");
const wire = @import("wire");

const sim_state = @import("state.zig");

const tick_period_ns: u64 = std.time.ns_per_s / 60; // 60 Hz auth tick
const phys_dt_fixed: f32 = 1.0 / 60.0;

/// Hardcoded test ship parameters (sub-step 2). Will move into
/// per-entity spawn protocol once spatial-index + gateway are in.
const test_ship_id: u32 = 1;
const test_ship_generation: u16 = 0;

/// YAML inputs — ship-sim must agree with the sandbox on hull + wave
/// kernel until the spawn protocol carries them on the wire. Ran from
/// project root (the build/cwd convention shared with cell-mgr).
const hull_config_path = "data/ships/box.yaml";
const wave_config_path = "data/waves/storm.yaml";

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

fn loadHull(gpa: std.mem.Allocator, rel_path: []const u8) !notatlas.hull_params.HullParams {
    const abs = try std.fs.cwd().realpathAlloc(gpa, rel_path);
    defer gpa.free(abs);
    return notatlas.yaml_loader.loadHullFromFile(gpa, abs);
}

fn loadWaves(gpa: std.mem.Allocator, rel_path: []const u8) !notatlas.wave_query.WaveParams {
    const abs = try std.fs.cwd().realpathAlloc(gpa, rel_path);
    defer gpa.free(abs);
    return notatlas.yaml_loader.loadFromFile(gpa, abs);
}

fn buoyancyConfigFromHull(hull: notatlas.hull_params.HullParams) physics.BuoyancyConfig {
    return .{
        .sample_points = hull.sample_points,
        .cell_half_height = hull.cell_half_height,
        .cell_cross_section = hull.cell_cross_section,
        .drag_per_point = hull.drag_per_point,
    };
}

/// yaw extracted from a unit quaternion (x,y,z,w). Y-up convention,
/// rotation around +y. Same formula the cluster builder will want
/// once heading is meaningful (mean-heading aggregation per
/// replication.zig). For pure pitch/roll the result is undefined
/// in principle but stable in practice (~0).
fn yawFromQuat(q: [4]f32) f32 {
    const x = q[0];
    const y = q[1];
    const z = q[2];
    const w = q[3];
    return std.math.atan2(2.0 * (w * y + x * z), 1.0 - 2.0 * (y * y + x * x));
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);
    defer allocator.free(args.nats_url);
    defer allocator.free(args.shard);
    try installSignalHandlers();

    // Load hull + wave kernel before the NATS connect so a missing /
    // malformed YAML fails fast without leaving a dangling client.
    var hull = try loadHull(allocator, hull_config_path);
    defer hull.deinit(allocator);
    const wave_params = try loadWaves(allocator, wave_config_path);
    std.debug.print(
        "ship-sim [{s}]: hull half_extents=({d:.2},{d:.2},{d:.2}) mass={d} kg, {d} buoyancy samples; wave seed={d} amp={d:.2} m\n",
        .{
            args.shard,
            hull.half_extents[0],
            hull.half_extents[1],
            hull.half_extents[2],
            hull.mass_kg,
            hull.sample_points.len,
            wave_params.seed,
            wave_params.amplitude_m,
        },
    );

    // Jolt — same M3 init pattern as the sandbox. Single dynamic body
    // at the test ship's id; future multi-ship is a per-entity body
    // map driven by spawn deltas.
    physics.init();
    defer physics.shutdown();
    var phys = try physics.System.init(.{});
    defer phys.deinit();

    // Drop from above SL so buoyancy is visible in the first second
    // of logs — same comfort the sandbox uses.
    const spawn_pos: [3]f32 = .{ 0, 4, 0 };
    const body_id = try phys.createBox(.{
        .half_extents = hull.half_extents,
        .position = spawn_pos,
        .motion = .dynamic,
        .mass_override_kg = hull.mass_kg,
    });
    phys.optimizeBroadPhase();

    var buoy = physics.Buoyancy.init(buoyancyConfigFromHull(hull));

    std.debug.print("ship-sim [{s}]: connecting to {s}\n", .{ args.shard, args.nats_url });

    var client = try nats.Client.connect(allocator, .{
        .servers = &.{args.nats_url},
        .name = "ship-sim",
    });
    defer client.close();

    std.debug.print("ship-sim [{s}]: connected; tick rate 60 Hz\n", .{args.shard});

    var state = sim_state.State.init(allocator);
    defer state.deinit();

    // Spawn the test ship in the local entity table (mirrors Jolt's
    // body for stats / log purposes; the body is the source of truth).
    try state.entities.put(test_ship_id, .{
        .id = .{ .id = test_ship_id, .generation = test_ship_generation },
        .kind = .ship,
        .pose = .{
            .pos = spawn_pos,
            .rot = .{ 0, 0, 0, 1 },
            .vel = .{ 0, 0, 0 },
        },
    });
    std.debug.print("ship-sim [{s}]: spawned test ship id={d} gen={d} at ({d:.1},{d:.1},{d:.1})\n", .{
        args.shard, test_ship_id, test_ship_generation,
        spawn_pos[0], spawn_pos[1], spawn_pos[2],
    });

    var subj_buf: [64]u8 = undefined;
    const state_subj = try std.fmt.bufPrint(&subj_buf, "sim.entity.{d}.state", .{test_ship_id});

    // M5.1 fixed-step accumulator — catch up if the loop falls
    // behind, spiral-cap at 5 ticks/loop. Same pattern as the
    // sandbox; identical to sub-step 1.
    const max_ticks_per_loop: u32 = 5;
    const start_ns: u64 = @intCast(std.time.nanoTimestamp());
    var last_tick_ns: u64 = start_ns;
    var tick_n: u64 = 0;
    var phys_t: f32 = 0;
    var last_log_tick: u64 = 0;
    var last_log_ns: u64 = start_ns;

    while (g_running.load(.acquire)) {
        try client.processIncomingTimeout(5);
        try client.maybeSendPing();

        const now_ns: u64 = @intCast(std.time.nanoTimestamp());
        var ticks_due: u32 = 0;
        while (now_ns -% last_tick_ns >= tick_period_ns and ticks_due < max_ticks_per_loop) : (ticks_due += 1) {
            try tick(allocator, client, &state, state_subj, &phys, &buoy, body_id, wave_params, phys_t);
            tick_n += 1;
            phys_t += phys_dt_fixed;
            last_tick_ns +%= tick_period_ns;
        }

        if (now_ns -% last_log_ns >= std.time.ns_per_s) {
            const ticks_in_window = tick_n - last_log_tick;
            const pos = phys.getPosition(body_id) orelse spawn_pos;
            const lin_v = phys.getLinearVelocity(body_id) orelse .{ 0, 0, 0 };
            std.debug.print(
                "[ship-sim {s}] {d} entities, {d} ticks last 1 s (target 60); ship pos=({d:.2},{d:.2},{d:.2}) v=({d:.2},{d:.2},{d:.2})\n",
                .{
                    args.shard,            state.entityCount(),
                    ticks_in_window,       pos[0],
                    pos[1],                pos[2],
                    lin_v[0],              lin_v[1],
                    lin_v[2],
                },
            );
            last_log_tick = tick_n;
            last_log_ns = now_ns;
        }
    }

    std.debug.print("ship-sim [{s}]: shutting down at tick {d}\n", .{ args.shard, tick_n });
}

/// Per-tick work — sub-step 2: buoyancy + Jolt step + state publish.
/// `phys_t` is the simulation clock at tick start (advances by exactly
/// `phys_dt_fixed` each tick); buoyancy reads the wave kernel at this
/// time so successive ticks integrate against a coherent surface.
fn tick(
    allocator: std.mem.Allocator,
    client: *nats.Client,
    state: *sim_state.State,
    state_subj: []const u8,
    phys: *physics.System,
    buoy: *const physics.Buoyancy,
    body_id: physics.BodyId,
    wave_params: notatlas.wave_query.WaveParams,
    phys_t: f32,
) !void {
    buoy.step(phys, body_id, wave_params, phys_t);
    phys.step(phys_dt_fixed, 1);

    const pos = phys.getPosition(body_id) orelse return error.JoltMissingPosition;
    const rot = phys.getRotation(body_id) orelse return error.JoltMissingRotation;
    const lin_v = phys.getLinearVelocity(body_id) orelse return error.JoltMissingLinearVelocity;

    // Mirror the just-stepped pose into the local entity table so the
    // log + future cluster work see a coherent view.
    if (state.entities.getPtr(test_ship_id)) |e| {
        e.pose.pos = pos;
        e.pose.rot = rot;
        e.pose.vel = lin_v;
    }

    const msg: wire.StateMsg = .{
        .generation = test_ship_generation,
        .x = pos[0],
        .y = pos[1],
        .z = pos[2],
        .rot = rot,
        .vx = lin_v[0],
        .vy = lin_v[1],
        .vz = lin_v[2],
        .heading_rad = yawFromQuat(rot),
    };
    const buf = try wire.encodeState(allocator, msg);
    defer allocator.free(buf);
    try client.publish(state_subj, buf);
}
