//! Wave kernel UBO consumed by `assets/shaders/water.frag`.
//!
//! Mirrors std140 layout for the `Waves` block:
//!
//! ```glsl
//! layout(set=0, binding=1) uniform Waves {
//!     vec4 a;        // (time, drag_multiplier, amplitude_m, wave_scale_m)
//!     vec4 b;        // (frequency_mult, base_time_mult, time_mult, weight_decay)
//!     vec4 c;        // (initial_iter, iterations_as_float, _, _)
//! } waves;
//! ```
//!
//! `iterations` is sent as a float (slot `c.y`) and cast to `uint` in the
//! shader — keeps the entire UBO at vec4 alignment with no uvec4 padding,
//! and the iteration count is small enough that float→uint round-trip is
//! exact.
//!
//! Same `iterations` value drives both the GPU raymarch and the CPU
//! `wave_query.waveHeight` calls used by future buoyancy code, so the
//! two surfaces agree at every (x, z, t).

const std = @import("std");
const notatlas = @import("notatlas");
const wave = notatlas.wave_query;
const math = notatlas.math;

pub const Ubo = extern struct {
    a: math.Vec4,
    b: math.Vec4,
    c: math.Vec4,

    pub fn fromParams(params: wave.WaveParams, time: f32) Ubo {
        return .{
            .a = .{
                .x = time,
                .y = params.drag_multiplier,
                .z = params.amplitude_m,
                .w = params.wave_scale_m,
            },
            .b = .{
                .x = params.frequency_mult,
                .y = params.base_time_mult,
                .z = params.time_mult,
                .w = params.weight_decay,
            },
            .c = .{
                .x = seedToInitialIter(params.seed),
                .y = @floatFromInt(params.iterations),
                .z = 0,
                .w = 0,
            },
        };
    }
};

/// Same algorithm as `wave_query.seedToInitialIter` (private there); shipped
/// here so the UBO is self-contained.
fn seedToInitialIter(seed: u64) f32 {
    var s: u64 = seed;
    s = (s ^ (s >> 30)) *% 0xBF58476D1CE4E5B9;
    s = (s ^ (s >> 27)) *% 0x94D049BB133111EB;
    s = s ^ (s >> 31);
    const u: u32 = @truncate(s);
    const fraction: f32 = @as(f32, @floatFromInt(u)) / 4294967296.0;
    return fraction * std.math.tau;
}

comptime {
    std.debug.assert(@sizeOf(Ubo) == 48);
    std.debug.assert(@offsetOf(Ubo, "a") == 0);
    std.debug.assert(@offsetOf(Ubo, "b") == 16);
    std.debug.assert(@offsetOf(Ubo, "c") == 32);
}
