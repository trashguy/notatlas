//! Pinhole camera + UBO layout consumed by `assets/shaders/ocean.vert` and
//! `ocean.frag`.
//!
//! UBO is std140: two consecutive mat4s (128 B) plus a vec4 eye (16 B) =
//! 144 B total. `eye.xyz` is the world-space camera position used by the
//! fragment stage for view-direction, fresnel, and the underwater fog gate;
//! `eye.w` is unused padding (mat4 follows on a 16 B boundary, so no
//! explicit padding is needed before it either).

const std = @import("std");
const notatlas = @import("notatlas");
const math = notatlas.math;

pub const Camera = struct {
    eye: math.Vec3,
    target: math.Vec3,
    up: math.Vec3 = math.Vec3.up,
    fov_y: f32, // radians
    aspect: f32,
    near: f32 = 0.1,
    far: f32 = 1000.0,

    pub fn view(self: Camera) math.Mat4 {
        return math.Mat4.lookAt(self.eye, self.target, self.up);
    }

    pub fn projection(self: Camera) math.Mat4 {
        return math.Mat4.perspective(self.fov_y, self.aspect, self.near, self.far);
    }
};

/// Uniform buffer payload. Field order and layout MUST match the
/// `Camera { mat4 view; mat4 proj; vec4 eye; }` block in ocean.vert / ocean.frag.
pub const Ubo = extern struct {
    view: math.Mat4,
    proj: math.Mat4,
    eye: math.Vec4,

    pub fn fromCamera(cam: Camera) Ubo {
        return .{
            .view = cam.view(),
            .proj = cam.projection(),
            .eye = .{ .x = cam.eye.x, .y = cam.eye.y, .z = cam.eye.z, .w = 1.0 },
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(Ubo) == 144);
    std.debug.assert(@offsetOf(Ubo, "view") == 0);
    std.debug.assert(@offsetOf(Ubo, "proj") == 64);
    std.debug.assert(@offsetOf(Ubo, "eye") == 128);
}
