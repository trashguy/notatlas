//! Ocean shading / foam / underwater fog parameters consumed by
//! `assets/shaders/water.frag`. Loaded from `data/ocean.yaml`.
//!
//! Slimmed at the M2.5 → afl_ext rewrite: `scatter`, `fresnel_pow`, and
//! `sun_specular` were removed because the new shader uses Schlick (fixed
//! exponent 5) and a `pow(720) * 210` sun disc — there's nothing for those
//! fields to drive any more.

const std = @import("std");

pub const OceanParams = struct {
    /// Subsurface tint near crests (linear RGB; no gamma).
    shallow_color: [3]f32,
    /// Subsurface tint deep in troughs.
    deep_color: [3]f32,

    /// Smoothstep midpoint of the foam mask, applied to `1 - n.y`.
    /// 0 = foam everywhere, 1 = never. ~0.3 is a good storm setting.
    crest_curvature_threshold: f32,
    /// Half-width of the smoothstep around the threshold.
    crest_width: f32,

    /// Color of the underwater fog.
    fog_color: [3]f32,
    /// Exponential fog coefficient (per meter). Only applied when the
    /// camera is below y=0; the fragment shader gates on `cam.eye.y < 0`.
    fog_density: f32,

    pub const default: OceanParams = .{
        .shallow_color = .{ 0.10, 0.45, 0.55 },
        .deep_color = .{ 0.02, 0.08, 0.18 },
        .crest_curvature_threshold = 0.30,
        .crest_width = 0.10,
        .fog_color = .{ 0.05, 0.18, 0.22 },
        .fog_density = 0.08,
    };
};
