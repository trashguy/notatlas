//! ship-sim — 60 Hz rigid-body authority for ships AND free-agent
//! players per docs/08 §2A.
//!
//! Sub-step 4 scope: input subscription. Wildcard NATS sub on
//! `sim.entity.*.input` consumes the gateway's TCP→NATS publish
//! path; per-tick the latched-most-recent input for each ship is
//! applied as forces before buoyancy + the system step. Closes the
//! end-to-end player-control loop: a length-prefixed JSON `InputMsg`
//! frame from a TCP client moves a ship on the wave.
//!
//! Force model:
//!   - thrust: force along ship-forward (rotated −Z), magnitude
//!     `thrust × THRUST_MAX_N`. Equilibrium speed against buoyancy
//!     drag is reached in a few seconds.
//!   - steer: lateral force at the bow point (forward × half-extent.z),
//!     magnitude `steer × STEER_MAX_N`. Generates a yaw torque
//!     plus a small lateral thrust — the latter is realistic-ish
//!     "skidding into a turn" behaviour for a flat-bottomed box hull.
//!
//! Force application order: input forces first → buoyancy → phys.step.
//! Buoyancy adds drag proportional to point velocity, so lateral skid
//! gets damped naturally.
//!
//! Sub-step 3 scope (still): multi-ship via ECS-style entity table.
//! State.zig owns per-entity Jolt body + cached publish subject;
//! main.zig spawns N ships at startup (default 5, override with
//! `--ships N`) spread along +X so they're all in one cell and
//! visible from any subscriber. Per tick: walk entities, apply
//! input + buoyancy forces; `phys.step(1/60, 1)` once advances ALL
//! bodies; walk entities again to read pose and publish per-entity
//! state msgs.
//!
//! Subsequent sub-steps:
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

/// Ships are spawned along +X starting at x=0, spaced `ship_spacing_m`
/// apart. 60 m clears each hull (4 × 2.5 × 6 m) by ~10× and keeps the
/// fleet inside the 500 m visual tier from a sub at origin so all
/// ships register on the gateway's per-second tally.
const ship_spacing_m: f32 = 60.0;
const ship_spawn_y: f32 = 4.0;

/// Force tuning for `thrust = ±1.0`. 60 kN against a 15 t hull is
/// 4 m/s² peak acceleration — equilibrium speed against the
/// buoyancy drag at 8 sample points × ~15 kN/(m/s) per point lands
/// in the 4-6 m/s range (a few hundred m of travel per minute,
/// realistic-ish naval feel for v0). Tune in `data/ships/box.yaml`
/// once the input loop drives a real ship config and not the M3
/// box.
const thrust_max_n: f32 = 60_000.0;
/// Steer applies a lateral force at the bow → torque around +y.
/// 30 kN at the bow (~3 m forward) gives 90 kN·m torque on a hull
/// with rough rotational inertia ~30,000 kg·m² → 3 rad/s² peak —
/// turns from rest to a 90° heading in ~1 s of sustained input,
/// which feels responsive without being twitchy.
const steer_max_n: f32 = 30_000.0;
/// Local-frame ship forward direction. Convention: −Z is forward
/// (matches the sandbox's M5.3 player composition where bow is
/// toward −Z when yaw=0).
const ship_forward_local: notatlas.math.Vec3 = .{ .x = 0, .y = 0, .z = -1 };

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
    /// Number of ships to spawn. Each gets its own Jolt body, its
    /// own state subject, and contributes to the per-tick fanout.
    /// Stays small until the spawn protocol arrives — at sub-step 3
    /// we hardcode-spawn so the chain has actual N>1 traffic to
    /// stress.
    ships: u32 = 5,
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
        } else if (std.mem.eql(u8, a, "--ships")) {
            out.ships = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArg, 10);
            if (out.ships == 0) return error.BadArg;
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
/// rotation around +y.
fn yawFromQuat(q: [4]f32) f32 {
    const x = q[0];
    const y = q[1];
    const z = q[2];
    const w = q[3];
    return std.math.atan2(2.0 * (w * y + x * z), 1.0 - 2.0 * (y * y + x * x));
}

/// Spawn a single ship: create Jolt body, allocate cached state
/// subject, insert into the entity table. Caller owns `phys`; on
/// failure the partial body is destroyed before returning.
fn spawnShip(
    allocator: std.mem.Allocator,
    state: *sim_state.State,
    phys: *physics.System,
    hull: notatlas.hull_params.HullParams,
    id: u32,
    spawn_pos: [3]f32,
) !void {
    const body = try phys.createBox(.{
        .half_extents = hull.half_extents,
        .position = spawn_pos,
        .motion = .dynamic,
        .mass_override_kg = hull.mass_kg,
    });
    errdefer phys.destroyBody(body);

    const subj = try std.fmt.allocPrint(allocator, "sim.entity.{d}.state", .{id});
    errdefer allocator.free(subj);

    try state.entities.put(id, .{
        .id = .{ .id = id, .generation = 0 },
        .kind = .ship,
        .pose = .{
            .pos = spawn_pos,
            .rot = .{ 0, 0, 0, 1 },
            .vel = .{ 0, 0, 0 },
        },
        .body_id = body,
        .state_subj = subj,
    });
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);
    defer allocator.free(args.nats_url);
    defer allocator.free(args.shard);
    try installSignalHandlers();

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

    physics.init();
    defer physics.shutdown();
    var phys = try physics.System.init(.{});
    defer phys.deinit();

    var buoy = physics.Buoyancy.init(buoyancyConfigFromHull(hull));

    std.debug.print("ship-sim [{s}]: connecting to {s}\n", .{ args.shard, args.nats_url });

    var client = try nats.Client.connect(allocator, .{
        .servers = &.{args.nats_url},
        .name = "ship-sim",
    });
    defer client.close();

    // Wildcard subscribe — ship-sim doesn't know which entity ids
    // it owns until spawn, and gateway-driven inputs may target any
    // of them by id. Per-tick we drain pending input msgs, parse
    // the entity id out of the subject, and update the matching
    // entity's latched input. Unknown ids are ignored.
    const sub_input = try client.subscribe("sim.entity.*.input", .{});
    std.debug.print(
        "ship-sim [{s}]: connected; tick rate 60 Hz; subscribed to sim.entity.*.input\n",
        .{args.shard},
    );

    var state = sim_state.State.init(allocator);
    defer state.deinit(&phys);

    // Spawn N ships along +X. Ids 1..N, positions (i × spacing, y, 0).
    var i: u32 = 0;
    while (i < args.ships) : (i += 1) {
        const id: u32 = i + 1;
        const pos: [3]f32 = .{ @as(f32, @floatFromInt(i)) * ship_spacing_m, ship_spawn_y, 0 };
        try spawnShip(allocator, &state, &phys, hull, id, pos);
    }
    phys.optimizeBroadPhase();
    std.debug.print(
        "ship-sim [{s}]: spawned {d} ships at x=[0..{d:.0}] m, spacing {d:.0} m\n",
        .{ args.shard, args.ships, @as(f32, @floatFromInt(args.ships - 1)) * ship_spacing_m, ship_spacing_m },
    );

    // M5.1 fixed-step accumulator — catch up if the loop falls
    // behind, spiral-cap at 5 ticks/loop. Same pattern as the
    // sandbox.
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

        // Drain inbound input msgs into the latched-input slot of
        // their matching entity. Done outside the tick to keep the
        // tick body deterministic — between two ticks we apply
        // whatever's the most recent input we've seen.
        try drainInputSub(allocator, sub_input, &state);

        const now_ns: u64 = @intCast(std.time.nanoTimestamp());
        var ticks_due: u32 = 0;
        while (now_ns -% last_tick_ns >= tick_period_ns and ticks_due < max_ticks_per_loop) : (ticks_due += 1) {
            try tick(allocator, client, &state, &phys, &buoy, wave_params, phys_t, hull.half_extents);
            tick_n += 1;
            phys_t += phys_dt_fixed;
            last_tick_ns +%= tick_period_ns;
        }

        if (now_ns -% last_log_ns >= std.time.ns_per_s) {
            const ticks_in_window = tick_n - last_log_tick;
            // Pose readout for ship #1 — single-line proof-of-life
            // that physics is alive without flooding the log when
            // N is large.
            const lead = state.entities.get(1) orelse unreachable;
            const lead_pos = phys.getPosition(lead.body_id) orelse lead.pose.pos;
            std.debug.print(
                "[ship-sim {s}] {d} ships, {d} ticks last 1 s (target 60); ship#1 pos=({d:.2},{d:.2},{d:.2}) ; ~{d} state-pubs/s\n",
                .{
                    args.shard,                                args.ships,
                    ticks_in_window,                           lead_pos[0],
                    lead_pos[1],                               lead_pos[2],
                    ticks_in_window * @as(u64, args.ships),
                },
            );
            last_log_tick = tick_n;
            last_log_ns = now_ns;
        }
    }

    std.debug.print("ship-sim [{s}]: shutting down at tick {d}\n", .{ args.shard, tick_n });
}

/// Drain pending `sim.entity.*.input` msgs and update latched input
/// on the matching entities. Unknown / missing entity ids are
/// silently dropped — gateway hasn't been informed of the spawn set
/// (no spawn protocol yet), so spurious inputs are expected.
fn drainInputSub(
    allocator: std.mem.Allocator,
    sub: anytype,
    state: *sim_state.State,
) !void {
    while (sub.nextMsg()) |msg| {
        var owned = msg;
        defer owned.deinit();
        const payload = owned.payload orelse continue;
        const ent_id = wire.parseEntityIdFromInputSubject(owned.subject) catch continue;
        const e = state.entities.getPtr(ent_id) orelse continue;
        const parsed = wire.decodeInput(allocator, payload) catch continue;
        defer parsed.deinit();
        e.input = .{
            .thrust = std.math.clamp(parsed.value.thrust, -1.0, 1.0),
            .steer = std.math.clamp(parsed.value.steer, -1.0, 1.0),
        };
    }
}

/// Apply latched input as forces on `e`'s Jolt body before
/// buoyancy + integration. Thrust = force along ship-forward at the
/// body center (no torque). Steer = lateral force at the bow point
/// (forward × half_extent.z) → yaw torque + small lateral skid.
fn applyInputForces(
    phys: *physics.System,
    e: *const sim_state.Entity,
    half_extents: [3]f32,
) void {
    if (e.input.thrust == 0 and e.input.steer == 0) return;
    const pos = phys.getPosition(e.body_id) orelse return;
    const rot = phys.getRotation(e.body_id) orelse return;

    const forward_world = notatlas.math.Vec3.rotateByQuat(ship_forward_local, rot);
    const center: [3]f32 = .{ pos[0], pos[1], pos[2] };

    if (e.input.thrust != 0) {
        const f = thrust_max_n * e.input.thrust;
        const force: [3]f32 = .{
            forward_world.x * f,
            forward_world.y * f,
            forward_world.z * f,
        };
        phys.addForceAtPoint(e.body_id, force, center);
    }

    if (e.input.steer != 0) {
        // Lateral = forward × +y (right-hand rule gives ship's
        // local +X = "starboard" as +steer direction).
        const up: notatlas.math.Vec3 = .{ .x = 0, .y = 1, .z = 0 };
        const lateral = notatlas.math.Vec3.cross(forward_world, up);
        const f = steer_max_n * e.input.steer;
        const force: [3]f32 = .{
            lateral.x * f,
            lateral.y * f,
            lateral.z * f,
        };
        // Apply at the bow: center + forward × half_extent.z.
        const bow_offset_m = half_extents[2];
        const bow: [3]f32 = .{
            pos[0] + forward_world.x * bow_offset_m,
            pos[1] + forward_world.y * bow_offset_m,
            pos[2] + forward_world.z * bow_offset_m,
        };
        phys.addForceAtPoint(e.body_id, force, bow);
    }
}

/// Per-tick work — sub-step 4: input forces → buoyancy → single
/// system-wide `phys.step` → per-entity pose readback + state
/// publish.
///
/// `phys_t` is the simulation clock at tick start (advances by
/// exactly `phys_dt_fixed` each tick); buoyancy reads the wave kernel
/// at this time so successive ticks integrate against a coherent
/// surface.
fn tick(
    allocator: std.mem.Allocator,
    client: *nats.Client,
    state: *sim_state.State,
    phys: *physics.System,
    buoy: *const physics.Buoyancy,
    wave_params: notatlas.wave_query.WaveParams,
    phys_t: f32,
    hull_half_extents: [3]f32,
) !void {
    // Input forces first, then buoyancy. Order doesn't physically
    // matter — Jolt sums all forces between steps — but reads as
    // "what the player wants → what the water does → integrate."
    var input_it = state.entities.valueIterator();
    while (input_it.next()) |e| applyInputForces(phys, e, hull_half_extents);

    // Apply buoyancy + drag to every entity before stepping. Forces
    // accumulate inside Jolt and integrate in the single step call
    // that follows.
    var it = state.entities.valueIterator();
    while (it.next()) |e| buoy.step(phys, e.body_id, wave_params, phys_t);

    // Single system-wide integration step. One collision step per
    // tick — Jolt sub-stepping is not yet load-bearing here; if it
    // becomes one (high-velocity tunneling at 60 Hz), bump.
    phys.step(phys_dt_fixed, 1);

    // Read back + publish per entity. Allocates / frees a JSON
    // buffer per ship — known hot-path inefficiency that goes away
    // when wire/StateMsg moves to the M7 binary codec.
    var pub_it = state.entities.valueIterator();
    while (pub_it.next()) |e| {
        const pos = phys.getPosition(e.body_id) orelse continue;
        const rot = phys.getRotation(e.body_id) orelse continue;
        const lin_v = phys.getLinearVelocity(e.body_id) orelse continue;

        e.pose.pos = pos;
        e.pose.rot = rot;
        e.pose.vel = lin_v;

        const msg: wire.StateMsg = .{
            .generation = e.id.generation,
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
        try client.publish(e.state_subj, buf);
    }
}
