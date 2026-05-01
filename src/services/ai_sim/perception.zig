//! Per-AI perception context per docs/09 §7.1 v1 surface.
//!
//! Built once per AI per tick at the top of `tickCohort` and pushed
//! to the cohort's Lua VM as a global named `ctx`. Leaves read it
//! directly (no per-leaf args).
//!
//! v1 surface — bounded by docs/09 §7.2 reasoning: a leaf with a
//! fixed input shape is testable in isolation, and an AI with the
//! whole world in scope makes perception build dominate the tick.
//! Adding fields here is a deliberate Zig PR, not a designer
//! decision.
//!
//! Notable v1 stubs:
//!   - `wind` defaults to {dir=0, speed=0} until env service ships.
//!     env.cell.<x>_<y>.wind is drained today but not yet decoded.
//!   - `threats` (slice of nearby hostiles) is deferred to a follow-up.
//!     `lua_bind.pushValue` doesn't yet handle slice-of-struct; nearest_
//!     _enemy alone is enough for the v0 demo.
//!
//! `own_hp` is now real (post-damage-system, 2026-05-01) — sourced
//! from the firehose `StateMsg.hp` ship-sim publishes each tick.

const std = @import("std");
const notatlas = @import("notatlas");
const wire = @import("wire");
const ai_state = @import("state.zig");

pub const Vec3 = struct { x: f32, y: f32, z: f32 };
pub const Pose = struct {
    x: f32,
    y: f32,
    z: f32,
    qx: f32,
    qy: f32,
    qz: f32,
    qw: f32,
};
pub const Vel = struct { lin: Vec3, ang: Vec3 };
pub const Wind = struct { dir: f32, speed: f32 };
pub const Cell = struct { x: i32, y: i32 };
pub const Enemy = struct {
    id: u32,
    x: f32,
    y: f32,
    z: f32,
    dist: f32,
    hp: f32,
};

pub const PerceptionCtx = struct {
    tick: u64,
    dt: f32,
    own_pose: Pose,
    own_vel: Vel,
    own_hp: f32,
    wind: Wind,
    cell: Cell,
    nearest_enemy: ?Enemy,
};

pub const BuildOpts = struct {
    /// Top-byte-tagged AI ship id whose perspective we're building for.
    ai_id: u32,
    /// docs/09 §7.1 — perception_radius is per-archetype; AIs only see
    /// hostiles within this range. Drives nearest_enemy filter.
    perception_radius_m: f32,
    /// Cell side in metres — the value spatial-index runs with. Used
    /// only to derive `ctx.cell.{x,y}` from own pose; the index itself
    /// isn't queried in step 6a (we read the firehose-populated
    /// cohort.entities directly; step 6c switches to batched
    /// idx.spatial.query.radius).
    cell_side_m: f32,
    /// 20 Hz tick counter from the main loop.
    tick: u64,
    /// 1/20 — fixed-step. Future variable-rate cohort scheduling could
    /// vary this per cohort; leaves should not assume 0.05.
    dt: f32,
};

/// Build a PerceptionCtx for `opts.ai_id` from the cohort's world
/// snapshot. Returns null if we haven't yet observed the AI's own
/// pose — caller skips this tick (see main.zig tickCohort comment).
pub fn build(cohort: *const ai_state.Cohort, opts: BuildOpts) ?PerceptionCtx {
    const own = cohort.entities.get(opts.ai_id) orelse return null;

    // Step 6a does not yet have rotation in the firehose StateMsg as a
    // unit-quat; ship-sim publishes [4]f32 in StateMsg.rot. Pass it
    // through. heading_rad is also available for leaves that don't
    // want to do quat math.
    const own_pose: Pose = .{
        .x = own.x,
        .y = own.y,
        .z = own.z,
        // We don't currently keep the quat in WorldEntity (state.zig
        // collapsed StateMsg.rot at observe-time pre-step-6). Step 6b
        // can lift the quat through if a leaf needs it; for now the
        // heading angle covers steering math.
        .qx = 0,
        .qy = 0,
        .qz = std.math.sin(own.heading_rad * 0.5),
        .qw = std.math.cos(own.heading_rad * 0.5),
    };

    const own_vel: Vel = .{
        .lin = .{ .x = own.vx, .y = own.vy, .z = own.vz },
        .ang = .{ .x = 0, .y = 0, .z = 0 },
    };

    // Cell from own pose. Same floor()/cell_side math as
    // spatial-index/state.zig posToCell — duplicated here because
    // bringing the spatial-index module under ai-sim's import graph
    // would pull `nats` into a pure-data path. Fix when we factor a
    // shared `cell.zig`.
    const cell: Cell = .{
        .x = @intFromFloat(@floor(own.x / opts.cell_side_m)),
        .y = @intFromFloat(@floor(own.z / opts.cell_side_m)),
    };

    const nearest = nearestEnemy(cohort, opts.ai_id, own.x, own.y, own.z, opts.perception_radius_m);

    return .{
        .tick = opts.tick,
        .dt = opts.dt,
        .own_pose = own_pose,
        .own_vel = own_vel,
        // Real HP from the firehose (set by ship-sim's StateMsg.hp).
        // Plumbed through 2026-05-01 alongside the damage system; the
        // low_hp flee branch in pirate_sloop.lua becomes reachable.
        .own_hp = own.hp,
        .wind = .{ .dir = 0, .speed = 0 },
        .cell = cell,
        .nearest_enemy = nearest,
    };
}

fn nearestEnemy(
    cohort: *const ai_state.Cohort,
    self_id: u32,
    sx: f32,
    sy: f32,
    sz: f32,
    radius_m: f32,
) ?Enemy {
    const r2 = radius_m * radius_m;
    var best: ?Enemy = null;
    var best_d2: f32 = std.math.floatMax(f32);

    var it = cohort.entities.iterator();
    while (it.next()) |entry| {
        const id = entry.key_ptr.*;
        if (id == self_id) continue;
        // Step 6 v0 hostility: any other ship is an enemy. Player
        // capsules and projectiles are ignored. Faction rules are a
        // step-6c+ refinement.
        if (notatlas.entity_kind.kindOf(id) != .ship) continue;
        const e = entry.value_ptr.*;
        // Skip sunk ships — their row hangs around in the cohort
        // table until ship-sim's final hp=0 state msg ages out, but
        // they aren't a valid target. ship-sim removes the body the
        // tick after the hp=0 publish, so the firehose stops; this
        // filter just covers the in-flight tick.
        if (e.hp <= 0) continue;
        const dx = e.x - sx;
        const dy = e.y - sy;
        const dz = e.z - sz;
        const d2 = dx * dx + dy * dy + dz * dz;
        if (d2 > r2) continue;
        if (d2 < best_d2) {
            best_d2 = d2;
            best = .{
                .id = id,
                .x = e.x,
                .y = e.y,
                .z = e.z,
                .dist = @sqrt(d2),
                .hp = e.hp,
            };
        }
    }
    return best;
}

const testing = std.testing;

test "perception: build returns null when own pose unknown" {
    var c = ai_state.Cohort.init(testing.allocator);
    defer c.deinit();
    const ctx = build(&c, .{
        .ai_id = 0x01000003,
        .perception_radius_m = 600,
        .cell_side_m = 200,
        .tick = 0,
        .dt = 0.05,
    });
    try testing.expect(ctx == null);
}

test "perception: nearest_enemy picks closest ship within radius" {
    var c = ai_state.Cohort.init(testing.allocator);
    defer c.deinit();

    // Self at origin
    const self_id = notatlas.entity_kind.pack(.ship, 3);
    try c.observeEntity(self_id, .{ .generation = 0, .x = 0, .y = 0, .z = 0 }, 1);
    // Far ship outside radius
    const far_id = notatlas.entity_kind.pack(.ship, 2);
    try c.observeEntity(far_id, .{ .generation = 0, .x = 5000, .y = 0, .z = 0 }, 1);
    // Close ship inside radius
    const near_id = notatlas.entity_kind.pack(.ship, 1);
    try c.observeEntity(near_id, .{ .generation = 0, .x = 100, .y = 0, .z = 50 }, 1);
    // Player capsule even closer — must be ignored (kind != ship)
    const player_id = notatlas.entity_kind.pack(.player, 1);
    try c.observeEntity(player_id, .{ .generation = 0, .x = 10, .y = 0, .z = 0 }, 1);

    const ctx = build(&c, .{
        .ai_id = self_id,
        .perception_radius_m = 600,
        .cell_side_m = 200,
        .tick = 1,
        .dt = 0.05,
    }).?;
    try testing.expect(ctx.nearest_enemy != null);
    try testing.expectEqual(near_id, ctx.nearest_enemy.?.id);
}

test "perception: cell derived from own pose floor()" {
    var c = ai_state.Cohort.init(testing.allocator);
    defer c.deinit();
    const self_id = notatlas.entity_kind.pack(.ship, 3);
    try c.observeEntity(self_id, .{ .generation = 0, .x = 250, .y = 0, .z = -50 }, 1);
    const ctx = build(&c, .{
        .ai_id = self_id,
        .perception_radius_m = 600,
        .cell_side_m = 200,
        .tick = 1,
        .dt = 0.05,
    }).?;
    // x=250 → floor(250/200)=1; z=-50 → floor(-50/200)=-1
    try testing.expectEqual(@as(i32, 1), ctx.cell.x);
    try testing.expectEqual(@as(i32, -1), ctx.cell.y);
}

test "perception: nearest_enemy nil when nothing in radius" {
    var c = ai_state.Cohort.init(testing.allocator);
    defer c.deinit();
    const self_id = notatlas.entity_kind.pack(.ship, 3);
    try c.observeEntity(self_id, .{ .generation = 0, .x = 0, .y = 0, .z = 0 }, 1);
    try c.observeEntity(notatlas.entity_kind.pack(.ship, 2), .{ .generation = 0, .x = 9999, .y = 0, .z = 0 }, 1);
    const ctx = build(&c, .{
        .ai_id = self_id,
        .perception_radius_m = 600,
        .cell_side_m = 200,
        .tick = 1,
        .dt = 0.05,
    }).?;
    try testing.expect(ctx.nearest_enemy == null);
}

test "perception: nearestEnemy skips sunk ships" {
    var c = ai_state.Cohort.init(testing.allocator);
    defer c.deinit();

    const self_id = notatlas.entity_kind.pack(.ship, 3);
    try c.observeEntity(self_id, .{ .generation = 0, .x = 0, .y = 0, .z = 0, .hp = 1.0 }, 1);
    // Closer ship but sunk — must be skipped.
    const sunk_id = notatlas.entity_kind.pack(.ship, 1);
    try c.observeEntity(sunk_id, .{ .generation = 0, .x = 50, .y = 0, .z = 0, .hp = 0.0 }, 1);
    // Farther ship still alive — should win.
    const live_id = notatlas.entity_kind.pack(.ship, 2);
    try c.observeEntity(live_id, .{ .generation = 0, .x = 200, .y = 0, .z = 0, .hp = 0.5 }, 1);

    const ctx = build(&c, .{
        .ai_id = self_id,
        .perception_radius_m = 600,
        .cell_side_m = 200,
        .tick = 1,
        .dt = 0.05,
    }).?;
    try testing.expectEqual(live_id, ctx.nearest_enemy.?.id);
    try testing.expectEqual(@as(f32, 0.5), ctx.nearest_enemy.?.hp);
}

test "perception: own_hp pulled from firehose StateMsg.hp" {
    var c = ai_state.Cohort.init(testing.allocator);
    defer c.deinit();

    const self_id = notatlas.entity_kind.pack(.ship, 3);
    try c.observeEntity(self_id, .{ .generation = 0, .x = 0, .y = 0, .z = 0, .hp = 0.25 }, 1);

    const ctx = build(&c, .{
        .ai_id = self_id,
        .perception_radius_m = 600,
        .cell_side_m = 200,
        .tick = 1,
        .dt = 0.05,
    }).?;
    try testing.expectEqual(@as(f32, 0.25), ctx.own_hp);
}
