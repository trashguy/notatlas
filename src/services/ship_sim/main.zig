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
//!   - thrust: sail trim ∈ [0, 1] (negative clamps to 0 — sails
//!     can't reverse-thrust). Force along ship-forward scales with
//!     the projection of wind velocity onto the ship's forward axis,
//!     squared, signed: `force = trim × max × sign(wind∥) × (wind∥/baseline)²`.
//!     Wind from astern pushes the bow forward; beam wind gives no
//!     forward force in v0 (lateral lift is post-Phase-1 polish);
//!     wind from ahead pushes the ship backward, modeling a square
//!     rig that can't sail upwind. Wind is hardcoded for v0
//!     (`--wind-dir`, `--wind-speed`); Phase 2 plumbs through env
//!     service.
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

/// Ships are spawned along +X starting at x=0, spaced `--spacing M`
/// apart (default 60 m, override via CLI). 60 m clears each hull
/// (4 × 2.5 × 6 m) by ~10× and keeps a small fleet (≤8 ships)
/// inside the 500 m visual tier from a sub at origin. For >8 ships
/// you typically want tighter spacing — e.g. M1.5 stress puts 30
/// ships in a 6×5 grid at 30 m.
const default_ship_spacing_m: f32 = 60.0;
const ship_spawn_y: f32 = 4.0;

/// Free-agent player capsule placeholder dimensions. Half-extents
/// for a box that proxies a 1.8 m tall capsule controller — proper
/// capsule shape is a future C ABI extension. ~70 kg mass is the
/// standard adult human assumption used in the M5.3 player module.
const player_half_extents: [3]f32 = .{ 0.2, 0.9, 0.2 };
const player_mass_kg: f32 = 70.0;
const player_spawn_y: f32 = 4.0;
/// Spawn offset in +X from origin to clear ship#1 (which lands at
/// x=0). 30 m puts the player well clear of the lead ship's hull
/// while still inside any subscriber's visual tier.
const player_spawn_x_offset: f32 = 30.0;
/// Maximum world-space distance ship-sim treats as "close enough to
/// grab a ladder" when servicing a board verb. Smaller than the
/// default ship spacing (60 m) so a player can't board a ship two
/// rows away by mistake; large enough to forgive the player floating
/// 1-2 m off the hull due to wave bob.
const board_radius_m: f32 = 8.0;
/// Walking force tuning for the free-agent capsule. 800 N against a
/// 70 kg mass is ~11 m/s² peak — equilibrium speed against the
/// buoyancy drag at one capsule sample point in calm water lands
/// around 4-5 m/s, a reasonable jog. Steer is a yaw-rate stand-in
/// applied as a lateral force at +Z (forward shoulder), giving a
/// "lean-into-turn" feel without a real character controller.
const player_walk_force_n: f32 = 800.0;
const player_strafe_force_n: f32 = 800.0;

/// Sail force tuning. With `thrust = 1.0` (sails fully trimmed) and
/// wind blowing parallel to the ship's heading at the baseline speed
/// (10 m/s), the sail produces this many newtons of forward force —
/// 60 kN against a 15 t hull is 4 m/s² peak acceleration, equilibrium
/// ~5 m/s against buoyancy drag, matching the placeholder thrust the
/// sail model replaces. `thrust` now means "sail trim" (0 = stowed,
/// 1 = full); negative values zero the sail rather than reverse-
/// thrusting. Tune in `data/ships/box.yaml` once sails get their own
/// per-hull config.
const sail_force_max_n: f32 = 60_000.0;
/// Reference wind speed for the (wind_along / baseline)² scaling in
/// the sail force model. At this wind speed running with the wind
/// (wind aligned with ship forward), thrust=1.0 gives sail_force_max_n.
/// Faster wind scales force quadratically; lighter wind likewise.
const wind_baseline_mps: f32 = 10.0;
/// v0 hardcoded wind direction (radians, world frame). Same
/// convention as ship heading: 0 = blowing toward −Z (north). Phase
/// 2 replaces with `env.cell.<x>_<y>.wind` published by the env
/// service and consumed via the wind subscription ai-sim already
/// drains. CLI: `--wind-dir <rad>`.
const default_wind_dir_rad: f32 = 0;
/// v0 hardcoded wind speed (m/s). Moderate breeze. CLI:
/// `--wind-speed <mps>`.
const default_wind_speed_mps: f32 = 10.0;
/// Cell side (m) used when looking up env-sim's per-cell wind by
/// ship pose. Must match env-sim's `--cell-side` and spatial-index's
/// `--cell-side` — all three live in the same world. CLI:
/// `--cell-side <m>`.
const default_cell_side_m: f32 = 200.0;
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

/// Cannon parameters — sub-step 5 v1 has a single starboard cannon
/// per ship at half_extent.x off centerline, 1 m above deck. Fires
/// in ship-local +x direction (= starboard), which is the standard
/// naval broadside orientation. Cooldown 1.5 s for fast iteration;
/// production cannon reloads land in a per-cannon-component config
/// later. The fire-event's `rot` is the ship's world quaternion
/// directly (FireEvent convention: muzzle direction = rotateX(rot)).
const cannon_cooldown_s: f64 = 1.5;
const cannon_offset_y: f32 = 1.0;
/// Engagement-range budget for the server-side aim-pitch solver in
/// `fireCannon`. Targets within this horizontal range get pitch
/// compensation; out-of-range or no-target → horizontal fire (the
/// pre-pitch-compensation behavior). Match-or-exceed the AI's
/// `cannon_range_m` in `data/ai/pirate_sloop.lua` so AI fires are
/// never out-of-range from the solver's perspective.
const cannon_range_m: f32 = 200.0;
const ammo_config_path = "data/ammo/cannonball.yaml";

/// v0 sloop hull HP. Cannonball direct hits are 50 HP per
/// `cannonball.yaml`, so 6 direct hits sink a sloop. Phase 2 lifts
/// this into `data/ships/<hull>.yaml` alongside mass / extents
/// (`hull_params.HullParams.hp_max`).
const sloop_max_hp: f32 = 300.0;

/// In-flight cannonballs that haven't hit anything are reaped after
/// this many seconds. With muzzle_velocity=250 m/s and a sloop's
/// cannon range ~200 m, real flights last <1 s; the rest is splash
/// budget so a high-arc lob doesn't get prematurely retired.
const projectile_lifetime_s: f64 = 6.0;

/// Hit-test bounding sphere radius (m) added to each ship's AABB
/// half-extent for cannonball impact detection. Modest fudge factor
/// — splash is in the wire payload but v0 doesn't apply splash
/// falloff (single-target hit), so this radius generously covers
/// the AABB→sphere slop and a near-miss explosion.
const projectile_hit_padding_m: f32 = 1.0;

/// YAML inputs — ship-sim must agree with the sandbox on hull + wave
/// kernel until the spawn protocol carries them on the wire. Ran from
/// project root (the build/cwd convention shared with cell-mgr).
const hull_config_path = "data/ships/box.yaml";
const wave_config_path = "data/waves/storm.yaml";

const ShipLayout = enum { line, grid, circle, duel };

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
    /// Ship-to-ship spacing in m. Interpreted per layout:
    ///   - line:   step along +X between consecutive ships
    ///   - grid:   step along both +X and +Z in the square grid
    ///   - circle: chord distance between adjacent ships on the ring
    ///             (radius is derived: `spacing / (2·sin(π/N))`)
    /// Defaults to 60 m. Tighten for stress tests where you want
    /// all ships inside one sub's visual tier.
    spacing_m: f32 = default_ship_spacing_m,
    /// Spawn arrangement. `line` is the historical default and what
    /// M1.5 stress + drive_ship.sh assume. `circle` puts ships on a
    /// ring around origin so every ship can broadside any other —
    /// good for naval-combat tests where line layout's ±π aim
    /// degeneracy bites the AI. `grid` keeps everyone clustered
    /// near origin (useful when N is large). `duel` is a 2-ship
    /// AI-tuning fixture: ship#1 at origin (heading 0 → facing -Z),
    /// ship#2 at -X by `spacing_m`. Forces the AI's broadside-aim
    /// path to rotate by ≈π — exercises the wrap-around bug that
    /// motivated the PD heading controller. Ignores --ships.
    layout: ShipLayout = .line,
    /// Number of free-agent player capsules to spawn. v1 demo: 1.
    /// Each capsule gets a per-kind-tagged id of
    /// `EntityKind.player | (i+1)` so it doesn't collide with the
    /// ship id range. Spawned at the world origin (offset along +X
    /// to clear ship#1's body).
    players: u32 = 1,
    /// Hardcoded wind direction (radians, 0 = blowing toward −Z).
    /// Phase 2 replaces with the env service's
    /// `env.cell.<x>_<y>.wind` publish; for now ship-sim runs with
    /// a constant breeze. Override via `--wind-dir <rad>`.
    wind_dir_rad: f32 = default_wind_dir_rad,
    /// Hardcoded wind speed (m/s). Override via `--wind-speed <mps>`.
    wind_speed_mps: f32 = default_wind_speed_mps,
    /// Per-ship max HP at spawn. Override for soaks where you want
    /// to harvest a lot of damage events without ships sinking out
    /// of the test (`--ship-max-hp 9999` is effectively immortal).
    /// Phase 2 lifts max HP into per-hull YAML config alongside mass.
    ship_max_hp: f32 = sloop_max_hp,
    /// Cell side (m). Used when looking up env-sim's per-cell wind
    /// by ship pose. Must match env-sim's --cell-side.
    cell_side_m: f32 = default_cell_side_m,
    /// Optional initial linear velocity for ship#1 at spawn (m/s, +X).
    /// 0 disables. Used by the cross-cell transit smoke harness to
    /// move a ship across a cell boundary without an AI or interactive
    /// driver: with `--init-vel-x 30 --wind-speed 0` ship#1 coasts
    /// along +X for several seconds before drag damps it. Other ships
    /// are unaffected.
    init_vel_x_mps: f32 = 0,
    /// Optional initial linear velocity for ship#2 (the duel target)
    /// at spawn (m/s, +X). Only honored in `--layout duel`. Lets the
    /// pitch-lead smoke put the target ship in motion so the
    /// closed-form prediction in `fireCannon` is exercised. 0 disables.
    duel_target_vel_x_mps: f32 = 0,
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
        } else if (std.mem.eql(u8, a, "--spacing")) {
            out.spacing_m = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, a, "--grid")) {
            // Backward-compat alias for --layout grid.
            out.layout = .grid;
        } else if (std.mem.eql(u8, a, "--layout")) {
            const v = args.next() orelse return error.MissingArg;
            out.layout = std.meta.stringToEnum(ShipLayout, v) orelse {
                std.debug.print("ship-sim: bad --layout '{s}' (line|grid|circle)\n", .{v});
                return error.BadArg;
            };
        } else if (std.mem.eql(u8, a, "--players")) {
            out.players = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--wind-dir")) {
            out.wind_dir_rad = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, a, "--wind-speed")) {
            out.wind_speed_mps = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArg);
            if (out.wind_speed_mps < 0) return error.BadArg;
        } else if (std.mem.eql(u8, a, "--ship-max-hp")) {
            out.ship_max_hp = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArg);
            if (out.ship_max_hp <= 0) return error.BadArg;
        } else if (std.mem.eql(u8, a, "--cell-side")) {
            out.cell_side_m = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArg);
            if (out.cell_side_m <= 0) return error.BadArg;
        } else if (std.mem.eql(u8, a, "--init-vel-x")) {
            out.init_vel_x_mps = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, a, "--duel-target-vel-x")) {
            out.duel_target_vel_x_mps = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArg);
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

fn loadAmmo(gpa: std.mem.Allocator, rel_path: []const u8) !notatlas.projectile.AmmoParams {
    const abs = try std.fs.cwd().realpathAlloc(gpa, rel_path);
    defer gpa.free(abs);
    return notatlas.yaml_loader.loadAmmoFromFile(gpa, abs);
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
/// failure the partial body is destroyed before returning. `id` is
/// expected to be top-byte-tagged (`EntityKind.ship | seq`) per
/// memory `architecture_entity_id_kind_tag.md`.
fn spawnShip(
    allocator: std.mem.Allocator,
    state: *sim_state.State,
    phys: *physics.System,
    hull: notatlas.hull_params.HullParams,
    id: u32,
    spawn_pos: [3]f32,
    max_hp: f32,
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
        .hp_current = max_hp,
        .hp_max = max_hp,
    });
}

/// Create a free-agent player capsule body + state subject and
/// insert into `entities`. Body is a tall thin box proxying a 1.8 m
/// capsule (real capsule shape is a future jolt_c_api extension).
/// `id` is expected to be top-byte-tagged (`EntityKind.player | seq`).
fn spawnFreeAgentPlayer(
    allocator: std.mem.Allocator,
    state: *sim_state.State,
    phys: *physics.System,
    id: u32,
    spawn_pos: [3]f32,
) !void {
    const body = try phys.createBox(.{
        .half_extents = player_half_extents,
        .position = spawn_pos,
        .motion = .dynamic,
        .mass_override_kg = player_mass_kg,
    });
    errdefer phys.destroyBody(body);

    const subj = try std.fmt.allocPrint(allocator, "sim.entity.{d}.state", .{id});
    errdefer allocator.free(subj);

    try state.entities.put(id, .{
        .id = .{ .id = id, .generation = 0 },
        .kind = .free_agent,
        .pose = .{
            .pos = spawn_pos,
            .rot = .{ 0, 0, 0, 1 },
            .vel = .{ 0, 0, 0 },
        },
        .body_id = body,
        .state_subj = subj,
    });
}

/// Single sample point at the capsule body center for free-agent
/// player buoyancy. Static const lifetime — `BuoyancyConfig`
/// borrows the slice and ship-sim runs for the process lifetime.
const player_buoy_sample_points = [_][3]f32{.{ 0, 0, 0 }};

/// Buoyancy config for a free-agent player capsule — single sample
/// point at the body center, light drag tuned so the player bobs at
/// the surface rather than sinking. Smaller cell-cross-section than
/// a hull (0.4 × 0.4 m box footprint vs 4 × 6 m hull), so the
/// buoyancy force per metre of submersion is small; 70 kg vs hull's
/// ~15 t means the player hits equilibrium near the surface quickly.
const player_buoy_cfg: physics.BuoyancyConfig = .{
    .sample_points = &player_buoy_sample_points,
    .cell_half_height = 0.5,
    .cell_cross_section = 0.16,
    .drag_per_point = 250.0,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try parseArgs(allocator);
    defer allocator.free(args.nats_url);
    defer allocator.free(args.shard);
    try installSignalHandlers();

    var hull = try loadHull(allocator, hull_config_path);
    defer hull.deinit(allocator);
    const wave_params = try loadWaves(allocator, wave_config_path);
    const ammo = try loadAmmo(allocator, ammo_config_path);
    std.debug.print(
        "ship-sim [{s}]: hull half_extents=({d:.2},{d:.2},{d:.2}) mass={d} kg, {d} buoyancy samples; wave seed={d} amp={d:.2} m; cannonball muzzle_v={d:.0} m/s splash={d:.1} m; wind dir={d:.2} rad speed={d:.1} m/s\n",
        .{
            args.shard,
            hull.half_extents[0],
            hull.half_extents[1],
            hull.half_extents[2],
            hull.mass_kg,
            hull.sample_points.len,
            wave_params.seed,
            wave_params.amplitude_m,
            ammo.muzzle_velocity_mps,
            ammo.splash_radius_m,
            args.wind_dir_rad,
            args.wind_speed_mps,
        },
    );

    physics.init();
    defer physics.shutdown();
    var phys = try physics.System.init(.{});
    defer phys.deinit();

    var buoy_ship = physics.Buoyancy.init(buoyancyConfigFromHull(hull));
    var buoy_player = physics.Buoyancy.init(player_buoy_cfg);

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
    // Wind from env-sim. Drained each tick into a per-cell cache;
    // applyShipInputForces looks up wind by ship pose. If env-sim
    // isn't running, the cache stays empty and we fall back to the
    // CLI args (--wind-dir, --wind-speed). Same graceful-degradation
    // pattern as the existing services.
    const sub_wind = try client.subscribe("env.cell.*.wind", .{});
    std.debug.print(
        "ship-sim [{s}]: connected; tick rate 60 Hz; subscribed to sim.entity.*.input, env.cell.*.wind\n",
        .{args.shard},
    );

    var wind_cache: std.AutoHashMapUnmanaged([2]i32, [2]f32) = .{};
    defer wind_cache.deinit(allocator);

    var state = sim_state.State.init(allocator);
    defer state.deinit(&phys);

    // Spawn N ships. Layout drives placement; ship ids carry the
    // EntityKind.ship top-byte tag — matched by the input router
    // and spatial-index when routing by kind.
    const ship_kind = notatlas.entity_kind.Kind.ship;
    switch (args.layout) {
        .grid => {
            const cols: u32 = @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(args.ships)))));
            const half_extent: f32 = @as(f32, @floatFromInt(cols - 1)) * 0.5 * args.spacing_m;
            var i: u32 = 0;
            while (i < args.ships) : (i += 1) {
                const id: u32 = notatlas.entity_kind.pack(ship_kind, i + 1);
                const col = i % cols;
                const row = i / cols;
                const x: f32 = @as(f32, @floatFromInt(col)) * args.spacing_m - half_extent;
                const z: f32 = @as(f32, @floatFromInt(row)) * args.spacing_m - half_extent;
                const pos: [3]f32 = .{ x, ship_spawn_y, z };
                try spawnShip(allocator, &state, &phys, hull, id, pos, args.ship_max_hp);
            }
            std.debug.print(
                "ship-sim [{s}]: spawned {d} ships in {d}-col grid, spacing {d:.0} m, half-extent {d:.0} m\n",
                .{ args.shard, args.ships, cols, args.spacing_m, half_extent },
            );
        },
        .circle => {
            // Chord-spacing model: --spacing is the gap between
            // neighbours on the ring. Radius = chord / (2·sin(π/N)).
            // For N=1 we degenerate to "ship at origin" (radius 0)
            // and skip the divide.
            const n_f: f32 = @floatFromInt(args.ships);
            const radius: f32 = if (args.ships <= 1)
                0
            else
                args.spacing_m / (2.0 * std.math.sin(std.math.pi / n_f));
            var i: u32 = 0;
            while (i < args.ships) : (i += 1) {
                const id: u32 = notatlas.entity_kind.pack(ship_kind, i + 1);
                const angle: f32 = 2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / n_f;
                const x: f32 = radius * std.math.cos(angle);
                const z: f32 = radius * std.math.sin(angle);
                const pos: [3]f32 = .{ x, ship_spawn_y, z };
                try spawnShip(allocator, &state, &phys, hull, id, pos, args.ship_max_hp);
            }
            std.debug.print(
                "ship-sim [{s}]: spawned {d} ships on circle radius {d:.0} m, chord spacing {d:.0} m\n",
                .{ args.shard, args.ships, radius, args.spacing_m },
            );
        },
        .line => {
            var i: u32 = 0;
            while (i < args.ships) : (i += 1) {
                const id: u32 = notatlas.entity_kind.pack(ship_kind, i + 1);
                const pos: [3]f32 = .{ @as(f32, @floatFromInt(i)) * args.spacing_m, ship_spawn_y, 0 };
                try spawnShip(allocator, &state, &phys, hull, id, pos, args.ship_max_hp);
            }
            std.debug.print(
                "ship-sim [{s}]: spawned {d} ships in line at x=[0..{d:.0}] m, spacing {d:.0} m\n",
                .{ args.shard, args.ships, @as(f32, @floatFromInt(args.ships - 1)) * args.spacing_m, args.spacing_m },
            );
        },
        .duel => {
            // Hard-coded N=2 regardless of the user's --ships. ship#1
            // at origin (heading 0 → facing -Z); ship#2 along -X at
            // --spacing. Bearing ship#1→ship#2 = -π/2; broadside-
            // desired heading = -π/2 - π/2 = -π — the boundary case
            // wrap_angle picks arbitrarily. Pair with --wind-speed 0
            // to neutralize the sail force and isolate steering.
            const id1: u32 = notatlas.entity_kind.pack(ship_kind, 1);
            const id2: u32 = notatlas.entity_kind.pack(ship_kind, 2);
            try spawnShip(allocator, &state, &phys, hull, id1, .{ 0, ship_spawn_y, 0 }, args.ship_max_hp);
            try spawnShip(allocator, &state, &phys, hull, id2, .{ -args.spacing_m, ship_spawn_y, 0 }, args.ship_max_hp);
            // Snap the per-tick log's ship count to what we actually
            // spawned — the ticker subtracts args.ships from total
            // entity count to derive free-agent count.
            args.ships = 2;
            std.debug.print(
                "ship-sim [{s}]: spawned 2 ships in duel layout — ship#1 at origin, ship#2 at -{d:.0} m on +X axis\n",
                .{ args.shard, args.spacing_m },
            );
        },
    }

    // Optional kick: cross-cell transit smoke needs ship#1 in motion
    // without an AI or interactive driver. `--init-vel-x` sets the
    // body's linear velocity directly; with `--wind-speed 0` no sail
    // force kicks in to alter it, and Jolt damping bleeds the velocity
    // off over time — enough to traverse a 200 m cell at v=30 m/s in
    // ~7 s of coast.
    if (args.init_vel_x_mps != 0) {
        const ship1_id: u32 = notatlas.entity_kind.pack(ship_kind, 1);
        if (state.entities.get(ship1_id)) |e| {
            phys.setLinearVelocity(e.body_id, .{ args.init_vel_x_mps, 0, 0 });
            std.debug.print(
                "ship-sim [{s}]: ship#1 init velocity set to ({d:.1}, 0, 0) m/s\n",
                .{ args.shard, args.init_vel_x_mps },
            );
        }
    }
    if (args.layout == .duel and args.duel_target_vel_x_mps != 0) {
        const ship2_id: u32 = notatlas.entity_kind.pack(ship_kind, 2);
        if (state.entities.get(ship2_id)) |e| {
            phys.setLinearVelocity(e.body_id, .{ args.duel_target_vel_x_mps, 0, 0 });
            std.debug.print(
                "ship-sim [{s}]: ship#2 (duel target) init velocity set to ({d:.1}, 0, 0) m/s\n",
                .{ args.shard, args.duel_target_vel_x_mps },
            );
        }
    }

    // Spawn N free-agent player capsules. Each gets a tagged id
    // (`EntityKind.player | seq`) and is placed offset along +X from
    // origin so it doesn't intersect ship#1's hull. v1 demo: 1
    // player. Future spawn protocol replaces this with login-driven
    // creation.
    {
        const player_kind = notatlas.entity_kind.Kind.player;
        var i: u32 = 0;
        while (i < args.players) : (i += 1) {
            const id: u32 = notatlas.entity_kind.pack(player_kind, i + 1);
            const x: f32 = player_spawn_x_offset + @as(f32, @floatFromInt(i)) * 2.0;
            const pos: [3]f32 = .{ x, player_spawn_y, 0 };
            try spawnFreeAgentPlayer(allocator, &state, &phys, id, pos);
        }
        std.debug.print(
            "ship-sim [{s}]: spawned {d} free-agent player capsule(s) starting id=0x{X:0>8} at x={d:.0} m\n",
            .{ args.shard, args.players, notatlas.entity_kind.pack(player_kind, 1), player_spawn_x_offset },
        );
    }
    phys.optimizeBroadPhase();

    // M5.1 fixed-step accumulator — catch up if the loop falls
    // behind, spiral-cap at 5 ticks/loop. Same pattern as the
    // sandbox.
    const max_ticks_per_loop: u32 = 5;
    const start_ns: u64 = @intCast(std.time.nanoTimestamp());
    var last_tick_ns: u64 = start_ns;
    var tick_n: u64 = 0;
    var phys_t: f32 = 0;
    // Absolute world clock — f64 because the wipe cycle is ~10 weeks.
    // FireEvent.fire_time_s is f64 by design (the lag-comp rewind
    // buffer indexes against it). Advances by phys_dt_fixed per tick.
    var world_time_s: f64 = 0;
    var last_log_tick: u64 = 0;
    var last_log_ns: u64 = start_ns;

    while (g_running.load(.acquire)) {
        try client.processIncomingTimeout(5);
        try client.maybeSendPing();

        // Drain inbound input msgs — latches input on the right
        // drive target (ship or capsule, depending on whether the
        // player is aboard) and processes board/disembark verbs
        // inline. Mutations are safe here because phys.step hasn't
        // been called yet for the upcoming tick.
        try drainInputSub(allocator, client, sub_input, &state, &phys);
        // Drain env-sim wind updates into the per-cell cache. Best-
        // effort: malformed payloads dropped silently.
        drainWindSub(allocator, sub_wind, &wind_cache);

        const now_ns: u64 = @intCast(std.time.nanoTimestamp());
        var ticks_due: u32 = 0;
        while (now_ns -% last_tick_ns >= tick_period_ns and ticks_due < max_ticks_per_loop) : (ticks_due += 1) {
            try tick(allocator, client, &state, &phys, &buoy_ship, &buoy_player, wave_params, phys_t, hull.half_extents, world_time_s, ammo, args.wind_dir_rad, args.wind_speed_mps, &wind_cache, args.cell_side_m);
            tick_n += 1;
            phys_t += phys_dt_fixed;
            world_time_s += @as(f64, phys_dt_fixed);
            last_tick_ns +%= tick_period_ns;
        }

        if (now_ns -% last_log_ns >= std.time.ns_per_s) {
            const ticks_in_window = tick_n - last_log_tick;
            // Pose readout for ship #1 — single-line proof-of-life
            // that physics is alive without flooding the log when
            // N is large. Ship#1 id is now top-byte-tagged (0x01000001).
            const ship1_id = notatlas.entity_kind.pack(.ship, 1);
            const lead = state.entities.get(ship1_id) orelse unreachable;
            const lead_pos = phys.getPosition(lead.body_id) orelse lead.pose.pos;
            std.debug.print(
                "[ship-sim {s}] {d} ships, {d} free-agent, {d} aboard, {d} ticks last 1 s (target 60); ship#1 pos=({d:.2},{d:.2},{d:.2}) ; ~{d} state-pubs/s\n",
                .{
                    args.shard,                args.ships,
                    state.entityCount() - args.ships,
                    state.passengerCount(),    ticks_in_window,
                    lead_pos[0],               lead_pos[1],
                    lead_pos[2],               ticks_in_window * @as(u64, state.entityCount()),
                },
            );
            last_log_tick = tick_n;
            last_log_ns = now_ns;
        }
    }

    std.debug.print("ship-sim [{s}]: shutting down at tick {d}\n", .{ args.shard, tick_n });
}

/// Publish a FireMsg on `sim.entity.<id>.fire` for `e`'s starboard
/// cannon. Muzzle pose: ship pose offset by (half_extent.x, 1.0, 0)
/// in ship-local frame (= 1 m above deck, on the starboard side at
/// midships). Fire direction: ship-local +x rotated by ship rot
/// (FireEvent convention — `rotateX(rot)` is the muzzle forward).
fn fireCannon(
    allocator: std.mem.Allocator,
    client: *nats.Client,
    phys: *physics.System,
    state: *sim_state.State,
    e: *const sim_state.Entity,
    hull_half_extents: [3]f32,
    world_time_s: f64,
    ammo: notatlas.projectile.AmmoParams,
) !void {
    const pos = phys.getPosition(e.body_id) orelse return;
    const rot = phys.getRotation(e.body_id) orelse return;

    // Strip pitch/roll from the ship's rotation. Cannons are gimbal-
    // mounted at the gunport (gameplay assumption — real square-rig
    // cannons heeled with the ship and were duly inaccurate, but
    // forcing the AI to learn wave-pitch lead would be a deep skill
    // tax for v0). Yaw-only basis means muzzle position + firing
    // direction don't tilt with the swell — predictable arc per shot.
    const yaw = yawFromQuat(rot);
    const yaw_quat = notatlas.math.quatYaw(yaw);

    const local_offset: notatlas.math.Vec3 = .{
        .x = hull_half_extents[0],
        .y = cannon_offset_y,
        .z = 0,
    };
    const world_offset = notatlas.math.Vec3.rotateByQuat(local_offset, yaw_quat);
    const muzzle_pos: [3]f32 = .{
        pos[0] + world_offset.x,
        pos[1] + world_offset.y,
        pos[2] + world_offset.z,
    };

    // Pitch compensation with target-velocity lead. Closed-form
    // ballistic solver: for muzzle.y above target by h at horizontal
    // range R, with muzzle velocity v,
    //
    //   a = g·R² / (2v²)
    //   tan(θ_p) = (R ± √(R² − 4a(a − h))) / (2a)         (low-arc root)
    //
    // For a stationary target this is one-shot. For a moving target
    // the *aim point* — where we predict the target will be when
    // the cannonball arrives — depends on flight time, which depends
    // on the pitch we're solving for. Solve via fixed-point iteration:
    // start with the target's current pose, compute pitch + flight
    // time, advance the aim point along target velocity, repeat.
    // Converges in 2–3 iterations for typical sloop ranges.
    //
    // Lead is PITCH-only — yaw stays starboard (broadside fixed-aim
    // per docs/03 §8: players aim the ship, not the cannon). This
    // handles approach/retreat motion. Cross-track motion remains
    // uncompensated; that's where the EVE-transversal model lands
    // (`design_eve_transversal_hit_model.md`).
    //
    // No target in range, or solver discriminant < 0 (out of reach)
    // → horizontal shot.
    var pitch_rad: f32 = 0;
    {
        var nearest_d2: f32 = cannon_range_m * cannon_range_m;
        var nearest_pos: [3]f32 = .{ 0, 0, 0 };
        var nearest_vel: [3]f32 = .{ 0, 0, 0 };
        var nearest_id: ?u32 = null;
        var it = state.entities.iterator();
        while (it.next()) |kv| {
            if (kv.key_ptr.* == e.id.id) continue;
            if (kv.value_ptr.kind != .ship) continue;
            const tp = phys.getPosition(kv.value_ptr.body_id) orelse continue;
            const dx = tp[0] - muzzle_pos[0];
            const dz = tp[2] - muzzle_pos[2];
            const d2 = dx * dx + dz * dz;
            if (d2 < nearest_d2) {
                nearest_d2 = d2;
                nearest_pos = tp;
                nearest_vel = phys.getLinearVelocity(kv.value_ptr.body_id) orelse .{ 0, 0, 0 };
                nearest_id = kv.key_ptr.*;
            }
        }
        if (nearest_id != null) {
            const v = ammo.muzzle_velocity_mps;
            // Initial aim point: target's current pose. Refine over
            // a few iterations using the predicted flight time.
            var aim_x: f32 = nearest_pos[0];
            var aim_y: f32 = nearest_pos[1];
            var aim_z: f32 = nearest_pos[2];
            var lead_iter: u32 = 0;
            while (lead_iter < 3) : (lead_iter += 1) {
                const dx = aim_x - muzzle_pos[0];
                const dz = aim_z - muzzle_pos[2];
                const range_m = @sqrt(dx * dx + dz * dz);
                const h = muzzle_pos[1] - aim_y;
                const a_coef = (notatlas.projectile.g_mps2 * range_m * range_m) / (2.0 * v * v);
                const disc = range_m * range_m - 4.0 * a_coef * (a_coef - h);
                if (disc < 0) break; // out of range — keep last pitch (or 0)
                const x_lo = (range_m - @sqrt(disc)) / (2.0 * a_coef);
                pitch_rad = std.math.atan(x_lo);
                const t_flight = range_m / (v * @cos(pitch_rad));
                aim_x = nearest_pos[0] + nearest_vel[0] * t_flight;
                aim_y = nearest_pos[1] + nearest_vel[1] * t_flight;
                aim_z = nearest_pos[2] + nearest_vel[2] * t_flight;
            }
        }
    }

    // aim_quat = yaw · pitch — apply pitch in ship-local frame
    // first (around local +Z, the aft axis), then yaw to world.
    // rotateX(aim_quat) gives the world-frame muzzle direction the
    // FireEvent + projectile module use.
    const half_p = pitch_rad * 0.5;
    const pitch_quat: [4]f32 = .{ 0, 0, @sin(half_p), @cos(half_p) };
    const aim_quat = notatlas.math.quatMul(yaw_quat, pitch_quat);

    const msg: wire.FireMsg = .{
        .generation = e.id.generation,
        .fire_time_s = world_time_s,
        .mx = muzzle_pos[0],
        .my = muzzle_pos[1],
        .mz = muzzle_pos[2],
        .rx = aim_quat[0],
        .ry = aim_quat[1],
        .rz = aim_quat[2],
        .rw = aim_quat[3],
        .charge = 1.0,
        .ammo_muzzle_velocity_mps = ammo.muzzle_velocity_mps,
        .ammo_mass_kg = ammo.mass_kg,
        .ammo_splash_radius_m = ammo.splash_radius_m,
        .ammo_splash_damage_hp = ammo.splash_damage_hp,
    };

    // Track the cannonball server-side so the next ticks can resolve
    // impact. Append BEFORE publishing — if the publish fails the
    // tracking entry will be reaped by lifetime expiry, which is the
    // less-bad failure mode (a rendered shot with no damage authority
    // would feel worse than the inverse).
    try state.projectiles.append(state.allocator, .{
        .weapon_id = e.id.id,
        .fire_time_s = world_time_s,
        .muzzle_pos = muzzle_pos,
        .muzzle_rot = aim_quat,
        .charge = 1.0,
        .ammo_muzzle_velocity_mps = ammo.muzzle_velocity_mps,
        .ammo_mass_kg = ammo.mass_kg,
        .ammo_splash_radius_m = ammo.splash_radius_m,
        .ammo_splash_damage_hp = ammo.splash_damage_hp,
    });

    var subj_buf: [64]u8 = undefined;
    const subj = try std.fmt.bufPrint(&subj_buf, "sim.entity.{d}.fire", .{e.id.id});
    const buf = try wire.encodeFire(allocator, msg);
    defer allocator.free(buf);
    try client.publish(subj, buf);
}

/// Drain pending `sim.entity.*.input` msgs, route latched input to
/// the correct drive target, and apply board/disembark transitions
/// inline. Unknown / missing entity ids are silently dropped.
///
/// Routing per docs/08 §2A:
///   - Untagged or `Kind.ship` ids → drive the ship directly (M3
///     fixture path; legacy ids without the kind tag fall through
///     here too).
///   - `Kind.player` ids → if the player is in `passengers`, route
///     thrust/steer/fire to their attached ship (the "input drives
///     the helm while aboard" v1 simplification — future
///     deck-walking will split this further). Otherwise route to
///     the free-agent capsule entity.
///
/// `board` / `disembark` verbs are edge-triggered — the transition
/// fires inline if the player is in a state that supports the
/// requested transition. This is safe to do here (between ticks)
/// because ship-sim hasn't called `phys.step` yet for the upcoming
/// tick.
/// Drain `env.cell.*.wind` into the per-cell cache. Malformed
/// payloads or unparseable subjects are dropped silently.
/// applyShipInputForces consumes by ship pose.
fn drainWindSub(
    allocator: std.mem.Allocator,
    sub: anytype,
    cache: *std.AutoHashMapUnmanaged([2]i32, [2]f32),
) void {
    while (sub.nextMsg()) |msg| {
        var owned = msg;
        defer owned.deinit();
        const payload = owned.payload orelse continue;
        const cell = wire.parseCellFromWindSubject(owned.subject) catch continue;
        const parsed = wire.decodeWind(allocator, payload) catch continue;
        defer parsed.deinit();
        cache.put(allocator, .{ cell.x, cell.z }, .{ parsed.value.vx, parsed.value.vz }) catch {};
    }
}

/// Look up wind for a world position by computing its cell and
/// checking the env-sim cache. Falls back to (sin(d), -cos(d))×s
/// from the CLI defaults if no env publish has been received for
/// that cell yet — same convention as ship-sim's --wind-dir.
fn windAtPos(
    cache: *const std.AutoHashMapUnmanaged([2]i32, [2]f32),
    pos: [3]f32,
    cell_side_m: f32,
    fallback_dir_rad: f32,
    fallback_speed_mps: f32,
) [2]f32 {
    const cx: i32 = @intFromFloat(@floor(pos[0] / cell_side_m));
    const cz: i32 = @intFromFloat(@floor(pos[2] / cell_side_m));
    if (cache.get(.{ cx, cz })) |v| return v;
    return .{
        fallback_speed_mps * std.math.sin(fallback_dir_rad),
        -fallback_speed_mps * std.math.cos(fallback_dir_rad),
    };
}

fn drainInputSub(
    allocator: std.mem.Allocator,
    client: *nats.Client,
    sub: anytype,
    state: *sim_state.State,
    phys: *physics.System,
) !void {
    while (sub.nextMsg()) |msg| {
        var owned = msg;
        defer owned.deinit();
        const payload = owned.payload orelse continue;
        const ent_id = wire.parseEntityIdFromInputSubject(owned.subject) catch continue;
        const parsed = wire.decodeInput(allocator, payload) catch continue;
        defer parsed.deinit();

        const kind = notatlas.entity_kind.kindOf(ent_id);

        // Edge-triggered transitions first — board/disembark mutate
        // the entity table, so any subsequent latched-input write
        // must look up the (possibly new) target afterward.
        if (kind == .player) {
            if (parsed.value.board) {
                applyBoard(allocator, client, state, phys, ent_id) catch |err| {
                    std.debug.print("ship-sim: board failed for player 0x{X:0>8} ({s})\n", .{ ent_id, @errorName(err) });
                };
            }
            if (parsed.value.disembark) {
                applyDisembark(allocator, client, state, phys, ent_id) catch |err| {
                    std.debug.print("ship-sim: disembark failed for player 0x{X:0>8} ({s})\n", .{ ent_id, @errorName(err) });
                };
            }
        }

        // Pick the latched-input target after any transition above.
        const target_id = if (kind == .player and state.passengers.get(ent_id) != null)
            state.passengers.get(ent_id).?.ship_id
        else
            ent_id;

        const target = state.entities.getPtr(target_id) orelse continue;
        target.input = .{
            .thrust = std.math.clamp(parsed.value.thrust, -1.0, 1.0),
            .steer = std.math.clamp(parsed.value.steer, -1.0, 1.0),
            .fire = parsed.value.fire,
        };
    }
}

/// Locate the nearest `Kind.ship` entity in `state.entities` whose
/// world position is within `radius_m` of `pos`. Returns the ship's
/// id, or null if no ship is in range.
fn findNearestShip(
    state: *const sim_state.State,
    phys: *physics.System,
    pos: [3]f32,
    radius_m: f32,
) ?u32 {
    var best_id: ?u32 = null;
    var best_d2: f32 = radius_m * radius_m;
    var it = state.entities.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.kind != .ship) continue;
        const ship_pos = phys.getPosition(kv.value_ptr.body_id) orelse continue;
        const dx = ship_pos[0] - pos[0];
        const dy = ship_pos[1] - pos[1];
        const dz = ship_pos[2] - pos[2];
        const d2 = dx * dx + dy * dy + dz * dz;
        if (d2 <= best_d2) {
            best_d2 = d2;
            best_id = kv.key_ptr.*;
        }
    }
    return best_id;
}

/// Compute conjugate (inverse) of a unit quaternion (x,y,z,w).
fn quatConjugate(q: [4]f32) [4]f32 {
    return .{ -q[0], -q[1], -q[2], q[3] };
}

/// Board transition (free-agent → passenger) per docs/08 §2A.2.
/// Picks the nearest ship within `board_radius_m`, computes the
/// player's ship-local pose, destroys the capsule body, drops the
/// player from `entities`, adds them to `passengers`, and publishes
/// an `AttachMsg` to `idx.spatial.attach.<player_id>` so spatial-
/// index can synthesize the cell-exit delta.
fn applyBoard(
    allocator: std.mem.Allocator,
    client: *nats.Client,
    state: *sim_state.State,
    phys: *physics.System,
    player_id: u32,
) !void {
    if (state.passengers.get(player_id) != null) return; // already aboard
    const player_entry = state.entities.getPtr(player_id) orelse return;
    if (player_entry.kind != .free_agent) return;

    const player_pos = phys.getPosition(player_entry.body_id) orelse return;
    const ship_id = findNearestShip(state, phys, player_pos, board_radius_m) orelse return;

    const ship_entry = state.entities.getPtr(ship_id).?;
    const ship_pos = phys.getPosition(ship_entry.body_id) orelse return;
    const ship_rot = phys.getRotation(ship_entry.body_id) orelse return;

    // local = inverse(ship_rot) ⊗ (player_pos - ship_pos)
    const delta: notatlas.math.Vec3 = .{
        .x = player_pos[0] - ship_pos[0],
        .y = player_pos[1] - ship_pos[1],
        .z = player_pos[2] - ship_pos[2],
    };
    const local = notatlas.math.Vec3.rotateByQuat(delta, quatConjugate(ship_rot));

    // Drop the capsule body + state subject; passenger entry holds
    // the ship-local pose only.
    var moved = player_entry.*;
    _ = state.entities.remove(player_id);
    moved.deinit(allocator, phys);

    try state.passengers.put(player_id, .{
        .player_id = player_id,
        .ship_id = ship_id,
        .local_pose = .{
            .pos = .{ local.x, local.y, local.z },
            .rot = .{ 0, 0, 0, 1 }, // ship-local heading is identity for v1
            .vel = .{ 0, 0, 0 },
        },
    });

    try publishAttach(allocator, client, .{
        .player_id = player_id,
        .attached_ship_id = ship_id,
        .x = player_pos[0],
        .y = player_pos[1],
        .z = player_pos[2],
    });

    std.debug.print(
        "ship-sim: player 0x{X:0>8} BOARDED ship 0x{X:0>8} at world ({d:.1},{d:.1},{d:.1}) local ({d:.2},{d:.2},{d:.2})\n",
        .{ player_id, ship_id, player_pos[0], player_pos[1], player_pos[2], local.x, local.y, local.z },
    );
}

/// Disembark transition (passenger → free-agent) per docs/08 §2A.2.
/// Reconstructs the world pose as `ship_pose ⊗ local_pose`,
/// recreates the capsule body at that pose with the lever-arm
/// inherited velocity (`ship.lin_vel + ship.ang_vel × world_off`),
/// drops the passenger entry, and publishes an `AttachMsg` with
/// `attached_ship_id == 0` so spatial-index synthesizes a cell-enter
/// delta.
fn applyDisembark(
    allocator: std.mem.Allocator,
    client: *nats.Client,
    state: *sim_state.State,
    phys: *physics.System,
    player_id: u32,
) !void {
    const passenger_entry = state.passengers.get(player_id) orelse return;
    const ship_entry = state.entities.getPtr(passenger_entry.ship_id) orelse return;
    const ship_pos = phys.getPosition(ship_entry.body_id) orelse return;
    const ship_rot = phys.getRotation(ship_entry.body_id) orelse return;
    const ship_lin_v = phys.getLinearVelocity(ship_entry.body_id) orelse [_]f32{ 0, 0, 0 };
    const ship_ang_v = phys.getAngularVelocity(ship_entry.body_id) orelse [_]f32{ 0, 0, 0 };

    const local: notatlas.math.Vec3 = .{
        .x = passenger_entry.local_pose.pos[0],
        .y = passenger_entry.local_pose.pos[1],
        .z = passenger_entry.local_pose.pos[2],
    };
    const world_off = notatlas.math.Vec3.rotateByQuat(local, ship_rot);
    const world_pos: [3]f32 = .{
        ship_pos[0] + world_off.x,
        ship_pos[1] + world_off.y,
        ship_pos[2] + world_off.z,
    };

    // Lever-arm inheritance: a point rigidly attached to a rotating
    // body has world-frame velocity `lin_v + ang_v × r` where `r` is
    // the world-frame offset from the body's center. Without this a
    // jumper off a moving ship would drop straight down — Atlas-
    // faithful but unsatisfying once velocity-inherit is cheap.
    const ang_v_vec: notatlas.math.Vec3 = .{ .x = ship_ang_v[0], .y = ship_ang_v[1], .z = ship_ang_v[2] };
    const cross = notatlas.math.Vec3.cross(ang_v_vec, world_off);
    const inherited_v: [3]f32 = .{
        ship_lin_v[0] + cross.x,
        ship_lin_v[1] + cross.y,
        ship_lin_v[2] + cross.z,
    };

    _ = state.passengers.remove(player_id);

    spawnFreeAgentPlayer(allocator, state, phys, player_id, world_pos) catch |err| {
        // Failed to recreate body — re-insert passenger entry to
        // keep state consistent. Player remains aboard.
        state.passengers.put(player_id, passenger_entry) catch {};
        return err;
    };

    // Apply inherited velocity to the freshly-spawned capsule.
    const new_entry = state.entities.getPtr(player_id) orelse unreachable;
    phys.setLinearVelocity(new_entry.body_id, inherited_v);

    try publishAttach(allocator, client, .{
        .player_id = player_id,
        .attached_ship_id = 0,
        .x = world_pos[0],
        .y = world_pos[1],
        .z = world_pos[2],
    });

    std.debug.print(
        "ship-sim: player 0x{X:0>8} DISEMBARKED ship 0x{X:0>8} → world ({d:.1},{d:.1},{d:.1}) v=({d:.2},{d:.2},{d:.2})\n",
        .{ player_id, passenger_entry.ship_id, world_pos[0], world_pos[1], world_pos[2], inherited_v[0], inherited_v[1], inherited_v[2] },
    );
}

/// Publish an `AttachMsg` on `idx.spatial.attach.<player_id>` so
/// spatial-index can synthesize the cell-exit (board) or cell-enter
/// (disembark) delta. Allocates a JSON payload per call — same
/// pattern as the per-tick state pubs.
fn publishAttach(
    allocator: std.mem.Allocator,
    client: *nats.Client,
    msg: wire.AttachMsg,
) !void {
    var subj_buf: [64]u8 = undefined;
    const subj = try std.fmt.bufPrint(&subj_buf, "idx.spatial.attach.{d}", .{msg.player_id});
    const buf = try wire.encodeAttach(allocator, msg);
    defer allocator.free(buf);
    try client.publish(subj, buf);
}


/// Walk the in-flight projectile list, evaluate each against ship
/// AABBs, apply damage on hit, retire on hit or lifetime expiry.
/// Returns the count of impacts resolved this tick (logged at the
/// 1 Hz cadence so we can see hit rate without per-impact spam).
///
/// Self-exclusion: a ship's own cannonball can't hit it. Without
/// this the muzzle pose (which sits inside the firing ship's AABB
/// for the first frame of flight) would self-damage every shot.
///
/// v0 single-target: the first ship the trajectory enters consumes
/// the round. Splash falloff onto secondary ships in radius is a
/// damage-tuning polish item past Phase 1.
fn resolveProjectileImpacts(
    allocator: std.mem.Allocator,
    client: *nats.Client,
    state: *sim_state.State,
    phys: *physics.System,
    hull_half_extents: [3]f32,
    world_time_s: f64,
) !u32 {
    var hits: u32 = 0;
    var i: usize = 0;
    while (i < state.projectiles.items.len) {
        const p = state.projectiles.items[i];
        const dt = @as(f32, @floatCast(world_time_s - p.fire_time_s));
        if (dt > projectile_lifetime_s) {
            _ = state.projectiles.swapRemove(i);
            continue;
        }

        const ev: notatlas.projectile.FireEvent = .{
            .weapon = .{ .id = p.weapon_id, .generation = 0 },
            .fire_time_s = p.fire_time_s,
            .muzzle = .{
                .pos = p.muzzle_pos,
                .rot = p.muzzle_rot,
                .vel = .{ 0, 0, 0 },
            },
            .charge = p.charge,
            .ammo = .{
                .muzzle_velocity_mps = p.ammo_muzzle_velocity_mps,
                .mass_kg = p.ammo_mass_kg,
                .splash_radius_m = p.ammo_splash_radius_m,
                .splash_damage_hp = p.ammo_splash_damage_hp,
            },
        };
        const proj_pos = notatlas.projectile.predict(ev, dt);

        var hit_id: ?u32 = null;
        var ent_it = state.entities.iterator();
        while (ent_it.next()) |entry| {
            const ent = entry.value_ptr;
            if (ent.kind != .ship) continue;
            if (ent.id.id == p.weapon_id) continue;
            if (ent.isSunk()) continue;
            const ship_pos = phys.getPosition(ent.body_id) orelse continue;
            const dx = @abs(proj_pos[0] - ship_pos[0]);
            const dy = @abs(proj_pos[1] - ship_pos[1]);
            const dz = @abs(proj_pos[2] - ship_pos[2]);
            if (dx <= hull_half_extents[0] + projectile_hit_padding_m and
                dy <= hull_half_extents[1] + projectile_hit_padding_m and
                dz <= hull_half_extents[2] + projectile_hit_padding_m)
            {
                hit_id = ent.id.id;
                break;
            }
        }

        if (hit_id) |victim_id| {
            const victim = state.entities.getPtr(victim_id).?;
            const damage = p.ammo_splash_damage_hp;
            const remaining = victim.applyDamage(damage);
            try publishDamage(allocator, client, .{
                .victim_id = victim_id,
                .source_id = p.weapon_id,
                .damage = damage,
                .fire_time_s = p.fire_time_s,
                .hit_x = proj_pos[0],
                .hit_y = proj_pos[1],
                .hit_z = proj_pos[2],
                .remaining_hp = remaining,
            });
            std.debug.print(
                "ship-sim: hit 0x{X:0>8} ← 0x{X:0>8} for {d:.0} hp (remaining {d:.2})\n",
                .{ victim_id, p.weapon_id, damage, remaining },
            );
            hits += 1;
            _ = state.projectiles.swapRemove(i);
            continue;
        }
        i += 1;
    }
    return hits;
}

fn publishDamage(
    allocator: std.mem.Allocator,
    client: *nats.Client,
    msg: wire.DamageMsg,
) !void {
    var subj_buf: [64]u8 = undefined;
    const subj = try std.fmt.bufPrint(&subj_buf, "sim.entity.{d}.damage", .{msg.victim_id});
    const buf = try wire.encodeDamage(allocator, msg);
    defer allocator.free(buf);
    try client.publish(subj, buf);
}

/// Reap any ship whose hp dropped to zero this tick. Passengers are
/// ejected via `applyDisembark` so they re-spawn as free-agent
/// capsules at the ship's last pose with lever-arm-inherited velocity
/// (and spatial-index sees a clean cell-enter delta on their attach
/// subject). Buffer of 64 sunk-ids per tick is generous for a v0
/// where AI shoots one ship at a time; bump or move to ArrayList if
/// mass-sinkings become a thing.
fn destroySunkShips(
    allocator: std.mem.Allocator,
    client: *nats.Client,
    state: *sim_state.State,
    phys: *physics.System,
) !u32 {
    var sunk_buf: [64]u32 = undefined;
    var n: usize = 0;
    var it = state.entities.iterator();
    while (it.next()) |entry| {
        const e = entry.value_ptr;
        if (e.kind == .ship and e.isSunk()) {
            if (n >= sunk_buf.len) break;
            sunk_buf[n] = e.id.id;
            n += 1;
        }
    }
    if (n == 0) return 0;

    for (sunk_buf[0..n]) |ship_id| {
        // Snapshot passenger ids first — applyDisembark mutates the
        // passengers map.
        var pids: [16]u32 = undefined;
        var pi: usize = 0;
        var pit = state.passengers.iterator();
        while (pit.next()) |pe| {
            if (pe.value_ptr.ship_id == ship_id and pi < pids.len) {
                pids[pi] = pe.value_ptr.player_id;
                pi += 1;
            }
        }
        for (pids[0..pi]) |pid| {
            applyDisembark(allocator, client, state, phys, pid) catch |err| {
                std.debug.print(
                    "ship-sim: forced disembark failed for player 0x{X:0>8} on sinking ship 0x{X:0>8} ({s})\n",
                    .{ pid, ship_id, @errorName(err) },
                );
            };
        }

        const e = state.entities.getPtr(ship_id) orelse continue;
        std.debug.print("ship-sim: ship 0x{X:0>8} SUNK\n", .{ship_id});
        e.deinit(allocator, phys);
        _ = state.entities.remove(ship_id);
    }
    return @intCast(n);
}

/// Apply latched input as forces on a ship body before buoyancy +
/// integration. Thrust = force along ship-forward at the body center
/// (no torque). Steer = lateral force at the bow point
/// (forward × half_extent.z) → yaw torque + small lateral skid.
fn applyShipInputForces(
    phys: *physics.System,
    e: *const sim_state.Entity,
    half_extents: [3]f32,
    wind_world_xz: [2]f32,
) void {
    if (e.input.thrust == 0 and e.input.steer == 0) return;
    const pos = phys.getPosition(e.body_id) orelse return;
    const rot = phys.getRotation(e.body_id) orelse return;

    const forward_world = notatlas.math.Vec3.rotateByQuat(ship_forward_local, rot);
    const center: [3]f32 = .{ pos[0], pos[1], pos[2] };

    // Sail model. `thrust` ∈ [-1, 1] is interpreted as sail trim
    // (negative clamps to 0 — sails can't reverse-thrust the hull).
    // Wind velocity vector in world frame is supplied by the caller
    // (sampled from env-sim's per-cell publish, falling back to the
    // CLI defaults when env-sim is offline).
    //
    // Forward force magnitude scales with the projection of wind
    // onto the ship's forward axis, signed and squared:
    //   force = trim × max × sign(wind∥) × (wind∥ / wind_baseline)²
    //
    // → wind from astern (wind∥ > 0) pushes the bow forward.
    // → beam wind (wind∥ ≈ 0) gives zero forward force; lateral
    //   "leeway" via beam-reach lift is post-Phase-1 polish.
    // → wind from ahead (wind∥ < 0) pushes the ship backward, with
    //   magnitude clamped by the same trim factor — modeling a
    //   square-rigger that can't sail upwind. A real fore-and-aft
    //   rig would change sign here; v0 sloop is square-rig-shaped.
    if (e.input.thrust != 0) {
        const sail_trim = if (e.input.thrust > 0) e.input.thrust else 0;
        if (sail_trim > 0) {
            const wind_along =
                wind_world_xz[0] * forward_world.x +
                wind_world_xz[1] * forward_world.z;
            const norm = wind_along / wind_baseline_mps;
            const sign: f32 = if (wind_along >= 0) 1.0 else -1.0;
            const f = sail_trim * sail_force_max_n * sign * norm * norm;
            const force: [3]f32 = .{
                forward_world.x * f,
                forward_world.y * f,
                forward_world.z * f,
            };
            phys.addForceAtPoint(e.body_id, force, center);
        }
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

/// Free-agent player walking forces. Thrust = forward in world-frame
/// (player capsule has no rotation tracking yet — rotation = identity
/// always — so "forward" is hardcoded -Z, matching the
/// `ship_forward_local` convention). Steer = strafe lateral. Both are
/// applied at the body center; the capsule is upright-locked
/// implicitly because we never apply torque.
fn applyPlayerInputForces(
    phys: *physics.System,
    e: *const sim_state.Entity,
) void {
    if (e.input.thrust == 0 and e.input.steer == 0) return;
    const pos = phys.getPosition(e.body_id) orelse return;
    const center: [3]f32 = .{ pos[0], pos[1], pos[2] };

    if (e.input.thrust != 0) {
        const f = player_walk_force_n * e.input.thrust;
        // Walk forward = -Z in world frame (capsule rot is identity).
        const force: [3]f32 = .{ 0, 0, -f };
        phys.addForceAtPoint(e.body_id, force, center);
    }
    if (e.input.steer != 0) {
        const f = player_strafe_force_n * e.input.steer;
        // Strafe right = +X in world frame.
        const force: [3]f32 = .{ f, 0, 0 };
        phys.addForceAtPoint(e.body_id, force, center);
    }
}

/// Per-tick work — input forces (per kind) + cannon fire (ships
/// only, rate-limited) → buoyancy (per kind) → single system-wide
/// `phys.step` → per-entity pose readback + state publish.
///
/// `phys_t` is the simulation clock at tick start (advances by
/// exactly `phys_dt_fixed` each tick); buoyancy reads the wave kernel
/// at this time so successive ticks integrate against a coherent
/// surface. `world_time_s` is the absolute world clock used for
/// fire-event timestamps (f64 to span wipe cycle).
fn tick(
    allocator: std.mem.Allocator,
    client: *nats.Client,
    state: *sim_state.State,
    phys: *physics.System,
    buoy_ship: *const physics.Buoyancy,
    buoy_player: *const physics.Buoyancy,
    wave_params: notatlas.wave_query.WaveParams,
    phys_t: f32,
    hull_half_extents: [3]f32,
    world_time_s: f64,
    ammo: notatlas.projectile.AmmoParams,
    wind_dir_rad: f32,
    wind_speed_mps: f32,
    wind_cache: *const std.AutoHashMapUnmanaged([2]i32, [2]f32),
    cell_side_m: f32,
) !void {
    // Input forces first, then buoyancy. Order doesn't physically
    // matter — Jolt sums all forces between steps — but reads as
    // "what the player wants → what the water does → integrate."
    var input_it = state.entities.valueIterator();
    while (input_it.next()) |e| switch (e.kind) {
        .ship => {
            const ship_pos = phys.getPosition(e.body_id) orelse e.pose.pos;
            const wind_xz = windAtPos(wind_cache, ship_pos, cell_side_m, wind_dir_rad, wind_speed_mps);
            applyShipInputForces(phys, e, hull_half_extents, wind_xz);
        },
        .free_agent => applyPlayerInputForces(phys, e),
    };

    // Cannon fire — ships only, rate-limited per entity. Free-agent
    // capsules have no cannon (yet); their `fire` latch is ignored.
    // Done before buoyancy for no particular reason; FireEvent's
    // muzzle pose is read from Jolt at this point so it reflects the
    // just-applied input forces (cannon is on a moving deck — pose
    // is good enough at 60 Hz).
    var fire_it = state.entities.valueIterator();
    while (fire_it.next()) |e| {
        if (e.kind != .ship) continue;
        if (e.input.fire and world_time_s >= e.next_fire_allowed_s) {
            try fireCannon(allocator, client, phys, state, e, hull_half_extents, world_time_s, ammo);
            e.next_fire_allowed_s = world_time_s + cannon_cooldown_s;
        }
    }

    // Buoyancy + drag — per-kind config. Ships use the hull-derived
    // multi-sample-point grid; free-agent capsules use the lighter
    // single-sample placeholder. Both forces accumulate in Jolt and
    // integrate in the single step call that follows.
    var it = state.entities.valueIterator();
    while (it.next()) |e| switch (e.kind) {
        .ship => buoy_ship.step(phys, e.body_id, wave_params, phys_t),
        .free_agent => buoy_player.step(phys, e.body_id, wave_params, phys_t),
    };

    // Single system-wide integration step. One collision step per
    // tick — Jolt sub-stepping is not yet load-bearing here; if it
    // becomes one (high-velocity tunneling at 60 Hz), bump.
    phys.step(phys_dt_fixed, 1);

    // Resolve cannonball impacts using the just-stepped ship poses.
    // Hits deduct hp_current and publish DamageMsg. Sinking is
    // deferred to AFTER the state publish so the final state msg
    // for a sunk ship carries hp = 0.
    _ = try resolveProjectileImpacts(allocator, client, state, phys, hull_half_extents, world_time_s);

    // Read back + publish per entity. Passengers do NOT publish —
    // their pose flows through the ship's tier-3 boarded stream
    // (currently a future tier-3 detail; for v1 the silence on the
    // player's state subject is what spatial-index uses, alongside
    // the AttachMsg, to drive the cell-mgr unsubscribe). Allocates
    // a JSON buffer per state pub — same hot-path note as before;
    // M7 binary codec replaces this.
    var pub_it = state.entities.valueIterator();
    while (pub_it.next()) |e| {
        const pos = phys.getPosition(e.body_id) orelse continue;
        const rot = phys.getRotation(e.body_id) orelse continue;
        const lin_v = phys.getLinearVelocity(e.body_id) orelse continue;
        const ang_v = phys.getAngularVelocity(e.body_id) orelse [_]f32{ 0, 0, 0 };

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
            .hp = e.hpFraction(),
            .angvel_y = ang_v[1],
        };
        const buf = try wire.encodeState(allocator, msg);
        defer allocator.free(buf);
        try client.publish(e.state_subj, buf);
    }

    // Reap sunk ships AFTER publishing the final hp=0 state msg.
    // Passengers are ejected via the existing disembark path so
    // spatial-index gets a clean cell-enter delta and the player's
    // state subject restarts publishing.
    _ = try destroySunkShips(allocator, client, state, phys);
}
