//! Hull configuration loaded from `data/ships/<hull>.yaml`. Drives both
//! the Jolt rigid body (mass + half-extents) and the buoyancy module
//! (sample points + cell geometry + drag).
//!
//! The file is the single source of truth for what a "ship hull" is at
//! v0 — render scale, physics shape, buoyant behaviour all derive from
//! these numbers. M5 will likely split out a separate render mesh, but
//! for the M3 box the cube mesh is implicit.

const std = @import("std");

pub const HullParams = struct {
    /// Box half-extents (m). Forms the Jolt collision shape and the
    /// renderer's per-axis scale (× 2 of the unit cube mesh).
    half_extents: [3]f32,
    /// Body mass. Equilibrium submersion ≈ mass / (V_total × ρ_water).
    mass_kg: f32,

    /// Buoyancy column dimensions per sample.
    cell_half_height: f32,
    cell_cross_section: f32,
    drag_per_point: f32,

    /// Body-local sample positions. Owned by the caller's allocator —
    /// `deinit` frees them.
    sample_points: [][3]f32,

    pub fn deinit(self: HullParams, gpa: std.mem.Allocator) void {
        gpa.free(self.sample_points);
    }
};
