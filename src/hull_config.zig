//! Resolved hull configuration. The on-disk format lives in
//! `data/hulls/<name>.yaml`, with optional `extends:` chains; the
//! loader (see `hull_loader.zig`) walks that chain, merges child
//! over parent (child wins for any field set), validates that every
//! required field is non-null at the leaf, and returns one of these.
//!
//! What used to be hard-coded ship-sim Zig constants — sail force,
//! steer torque, cannon mount + cooldown + range, sloop hp — now
//! lives here. New ship tiers (schooner, brigantine, ...) author a
//! YAML with `extends: <parent>.yaml` plus the per-tier overrides;
//! the resolved struct is the same shape regardless of how many
//! files contributed.

const std = @import("std");

/// One starboard cannon's mount + ballistics. v0 sloops have a
/// single cannon; tier-3 brigs will have a multi-cannon array,
/// each entry a Cannon. Offset is ship-local: x = lateral
/// (positive = starboard), y = above deck, z = along forward axis
/// (negative = aft).
pub const Cannon = struct {
    offset_x: f32,
    offset_y: f32,
    offset_z: f32,
    cooldown_s: f32,
    /// Max engagement range for the server-side aim-pitch solver.
    /// Targets beyond this range fall back to horizontal fire.
    range_m: f32,
};

pub const HullConfig = struct {
    /// Box half-extents (m). Forms the Jolt collision shape and the
    /// renderer's per-axis scale.
    half_extents: [3]f32,
    /// Body mass (kg).
    mass_kg: f32,
    /// Spawn HP. The damage system tracks `hp_current / hp_max`;
    /// 0 sinks the ship.
    hp_max: f32,

    /// Buoyancy column dimensions per sample.
    cell_half_height: f32,
    cell_cross_section: f32,
    drag_per_point: f32,

    /// Body-local sample positions for the buoyancy integrator.
    /// Owned by the arena that loaded this config.
    sample_points: [][3]f32,

    /// Sail force model: peak force at full trim with wind aligned
    /// at `sail_baseline_mps` along the ship's forward axis.
    sail_force_max_n: f32,
    sail_baseline_mps: f32,

    /// Lateral force at the bow per unit |steer| ∈ [0, 1].
    steer_max_n: f32,

    /// Cannon battery. v0 sloop is a single starboard cannon;
    /// schooner / brig override with N entries. Owned by the arena
    /// that loaded this config.
    cannons: []Cannon,
};
