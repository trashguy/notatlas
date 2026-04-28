//! M3.3 buoyancy v0. Per-sample-point Archimedes force application against
//! the wave_query heightfield, plus linear drag at each submerged sample so
//! the body damps to a steady float instead of oscillating forever.
//!
//! Each sample owns a vertical "column" of water it represents — defined by
//! `cell_half_height` (column length / 2) and `cell_cross_section` (column
//! footprint). Submerged volume in the column is approximated as
//! `cross_section × min(submerged_depth, column_height)`, capped so a deep
//! sample doesn't get unbounded force when the wave kernel rings.
//!
//! Drag is scaled by submerged fraction — a sample barely beneath the
//! surface drags less than a fully-submerged one. Without this scaling,
//! shallow contacts produce overdamping that visibly arrests the body the
//! instant any sample hits water.
//!
//! Why a separate module: the math is the engine's, not the sandbox's.
//! Reusable for ships, floating debris, and (eventually) the buoyancy-test
//! harness used at the M3.5 stability gate.

const std = @import("std");
const notatlas = @import("notatlas");
const jolt = @import("jolt.zig");

const Vec3 = notatlas.math.Vec3;
const wave_query = notatlas.wave_query;

pub const Config = struct {
    /// Body-local sample positions in meters. Forces are applied at these
    /// points after rotating into world space. For a 4m cube with a
    /// 2×2×2 grid: (±1, ±1, ±1).
    sample_points: []const [3]f32,
    /// Column extends ±cell_half_height above and below each sample's
    /// world-space y. Sized so cells tile the body in y.
    cell_half_height: f32,
    /// Footprint area shared by the column (m²). Sum across samples should
    /// equal the body's top-down cross-section.
    cell_cross_section: f32,
    /// N·s/m per submerged sample at full submersion. Total system damping
    /// at full submersion = drag_per_point × sample_points.len. Tuned for
    /// near-critical damping of the box-on-storm-waves case at M3.3.
    drag_per_point: f32 = 5000.0,
    /// 1000 kg/m³ for ocean water. Tunable later for fresh/lake biomes if
    /// they show up in `data/waves/<biome>.yaml`.
    water_density: f32 = 1000.0,
    /// Standard gravity. Lives here (not Jolt's) because buoyancy is
    /// ρ·g·V — we want CPU-side math to match whatever Jolt integrates.
    gravity: f32 = 9.81,
};

pub const Buoyancy = struct {
    cfg: Config,

    pub fn init(cfg: Config) Buoyancy {
        return .{ .cfg = cfg };
    }

    /// Apply per-tick buoyancy + drag forces to `body`. Caller must invoke
    /// `system.step` afterward for the forces to integrate.
    ///
    /// `wave` and `t` must match what the GPU water shader sees this frame
    /// — that's the load-bearing invariant (`architecture_ships_on_water`).
    pub fn step(
        self: *const Buoyancy,
        system: *jolt.System,
        body: jolt.BodyId,
        wave: wave_query.WaveParams,
        t: f32,
    ) void {
        const pos = system.getPosition(body) orelse return;
        const quat = system.getRotation(body) orelse return;
        const lin_v = system.getLinearVelocity(body) orelse return;
        const ang_v = system.getAngularVelocity(body) orelse return;

        const body_pos = Vec3.init(pos[0], pos[1], pos[2]);
        const lin_v_vec = Vec3.init(lin_v[0], lin_v[1], lin_v[2]);
        const ang_v_vec = Vec3.init(ang_v[0], ang_v[1], ang_v[2]);

        const cell_extent = 2.0 * self.cfg.cell_half_height;

        for (self.cfg.sample_points) |local| {
            const offset = Vec3.rotateByQuat(
                Vec3.init(local[0], local[1], local[2]),
                quat,
            );
            const world = Vec3.add(body_pos, offset);

            const h = wave_query.waveHeight(wave, world.x, world.z, t);
            const cell_bottom_y = world.y - self.cfg.cell_half_height;
            const submerged = std.math.clamp(h - cell_bottom_y, 0.0, cell_extent);
            if (submerged <= 0) continue;

            // F_buoy = ρ·g·V_submerged_in_this_cell.
            const f_buoy_y = self.cfg.water_density * self.cfg.gravity * self.cfg.cell_cross_section * submerged;

            // World-space velocity of this point: v_linear + ω × r where r
            // is the offset from center of mass.
            const point_v = Vec3.add(lin_v_vec, Vec3.cross(ang_v_vec, offset));

            const sub_frac = submerged / cell_extent;
            const drag_k = self.cfg.drag_per_point * sub_frac;
            const force: [3]f32 = .{
                -drag_k * point_v.x,
                f_buoy_y - drag_k * point_v.y,
                -drag_k * point_v.z,
            };
            system.addForceAtPoint(body, force, .{ world.x, world.y, world.z });
        }
    }
};
