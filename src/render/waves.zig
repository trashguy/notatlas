//! Wave UBO layout consumed by `assets/shaders/ocean.vert`.
//!
//! Mirrors std140 layout for the `Waves` block:
//!
//! ```glsl
//! struct Component {
//!     vec4 dir_amp_steep;       // (dir.x, dir.z, amplitude, steepness)
//!     vec4 wavelen_speed_phi;   // (wavelength, speed, phi, _pad)
//! };
//! layout(set=0, binding=1) uniform Waves {
//!     int   count;
//!     float time;
//!     vec2  _pad0;
//!     Component components[MAX_COMPONENTS];
//! } waves;
//! ```
//!
//! Per-component phase offset `phi` is precomputed CPU-side via
//! `wave_query.componentPhase`. The shader can't reproduce splitmix64
//! (no u64 in core GLSL), so we ship phi alongside the params instead.

const std = @import("std");
const notatlas = @import("notatlas");
const wave = notatlas.wave_query;
const math = notatlas.math;

/// Max components packed in the UBO. Real configs use 2-5 (calm/choppy/storm).
/// Increase if a wave config exceeds this; rebuild required.
pub const MAX_COMPONENTS: u32 = 8;

pub const GerstnerUbo = extern struct {
    /// (dir.x, dir.z, amplitude, steepness)
    dir_amp_steep: math.Vec4,
    /// (wavelength, speed, phi, _pad)
    wavelen_speed_phi: math.Vec4,
};

pub const Ubo = extern struct {
    count: u32,
    time: f32,
    _pad0: [2]f32 = .{ 0, 0 },
    components: [MAX_COMPONENTS]GerstnerUbo,

    /// Build a UBO snapshot from a WaveParams + current time. Phases are
    /// derived from the seed via `wave_query.componentPhase`. Inactive slots
    /// (idx >= count) are zeroed; the shader skips them via the count guard.
    pub fn fromParams(params: wave.WaveParams, time: f32) Ubo {
        std.debug.assert(params.components.len <= MAX_COMPONENTS);
        var out: Ubo = .{
            .count = @intCast(params.components.len),
            .time = time,
            .components = std.mem.zeroes([MAX_COMPONENTS]GerstnerUbo),
        };
        for (params.components, 0..) |c, i| {
            const phi = wave.componentPhase(params.seed, i);
            out.components[i] = .{
                .dir_amp_steep = .{
                    .x = c.direction[0],
                    .y = c.direction[1],
                    .z = c.amplitude,
                    .w = c.steepness,
                },
                .wavelen_speed_phi = .{
                    .x = c.wavelength,
                    .y = c.speed,
                    .z = phi,
                    .w = 0,
                },
            };
        }
        return out;
    }
};

// std140 layout asserted at build time. If any of these trip, the GLSL
// `Waves` block in ocean.vert will read garbage.
comptime {
    std.debug.assert(@sizeOf(GerstnerUbo) == 32);
    std.debug.assert(@offsetOf(GerstnerUbo, "dir_amp_steep") == 0);
    std.debug.assert(@offsetOf(GerstnerUbo, "wavelen_speed_phi") == 16);
    std.debug.assert(@offsetOf(Ubo, "count") == 0);
    std.debug.assert(@offsetOf(Ubo, "time") == 4);
    std.debug.assert(@offsetOf(Ubo, "components") == 16);
    std.debug.assert(@sizeOf(Ubo) == 16 + MAX_COMPONENTS * 32);
}
