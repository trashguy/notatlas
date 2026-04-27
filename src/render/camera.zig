//! Pinhole camera + UBO layout consumed by `assets/shaders/ocean.vert`.
//!
//! UBO matches GLSL std140 for two consecutive mat4s: 128 bytes, no padding
//! needed (mat4 already 16-byte aligned).

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
/// `Camera { mat4 view; mat4 proj; }` block in ocean.vert.
pub const Ubo = extern struct {
    view: math.Mat4,
    proj: math.Mat4,

    pub fn fromCamera(cam: Camera) Ubo {
        return .{ .view = cam.view(), .proj = cam.projection() };
    }
};
