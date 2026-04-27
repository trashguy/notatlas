//! Ocean shading UBO consumed by `assets/shaders/water.frag`.
//!
//! Mirrors std140 layout:
//!
//! ```glsl
//! layout(set=0, binding=2) uniform OceanParams {
//!     vec4 shallow_color;      // rgb + 0
//!     vec4 deep_color;
//!     vec4 fog_color;
//!     vec4 foam;               // (crest_threshold, crest_width, fog_density, _pad)
//! } ocean;
//! ```
//!
//! `fog_density` shares the `foam` vec4 because std140 pads each scalar
//! to 16 B otherwise — packing keeps the UBO at 4×vec4 = 64 B.

const std = @import("std");
const notatlas = @import("notatlas");
const math = notatlas.math;
const params_mod = notatlas.ocean_params;

pub const Ubo = extern struct {
    shallow_color: math.Vec4,
    deep_color: math.Vec4,
    fog_color: math.Vec4,
    foam: math.Vec4, // (crest_threshold, crest_width, fog_density, _pad)

    pub fn fromParams(p: params_mod.OceanParams) Ubo {
        return .{
            .shallow_color = .{ .x = p.shallow_color[0], .y = p.shallow_color[1], .z = p.shallow_color[2], .w = 0 },
            .deep_color = .{ .x = p.deep_color[0], .y = p.deep_color[1], .z = p.deep_color[2], .w = 0 },
            .fog_color = .{ .x = p.fog_color[0], .y = p.fog_color[1], .z = p.fog_color[2], .w = 0 },
            .foam = .{ .x = p.crest_curvature_threshold, .y = p.crest_width, .z = p.fog_density, .w = 0 },
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(Ubo) == 64);
    std.debug.assert(@offsetOf(Ubo, "shallow_color") == 0);
    std.debug.assert(@offsetOf(Ubo, "deep_color") == 16);
    std.debug.assert(@offsetOf(Ubo, "fog_color") == 32);
    std.debug.assert(@offsetOf(Ubo, "foam") == 48);
}
