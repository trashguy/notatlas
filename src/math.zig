//! Vec3 / Vec4 / Mat4 + view & projection helpers.
//!
//! Mat4 is column-major (data[col*4 + row]); GLSL `mat4` is column-major and
//! reads the buffer contiguously, so a Mat4 uploaded as 64 bytes is read by
//! the shader as four columns with no swizzling.
//!
//! Right-handed world (y up, -z forward) → Vulkan NDC (y down, z in [0,1]).
//! `perspective` and `lookAt` are the conversion seam.

const std = @import("std");

pub const Vec3 = extern struct {
    x: f32,
    y: f32,
    z: f32,

    pub const zero: Vec3 = .{ .x = 0, .y = 0, .z = 0 };
    pub const up: Vec3 = .{ .x = 0, .y = 1, .z = 0 };

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn scale(a: Vec3, s: f32) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    pub fn length(a: Vec3) f32 {
        return @sqrt(dot(a, a));
    }

    pub fn normalize(a: Vec3) Vec3 {
        const len = length(a);
        if (len == 0) return zero;
        const inv = 1.0 / len;
        return .{ .x = a.x * inv, .y = a.y * inv, .z = a.z * inv };
    }
};

pub const Vec4 = extern struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub fn init(x: f32, y: f32, z: f32, w: f32) Vec4 {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }
};

/// Column-major 4x4. data[col*4 + row].
pub const Mat4 = extern struct {
    data: [16]f32,

    pub const identity: Mat4 = .{ .data = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    } };

    pub fn at(self: Mat4, col: u32, row: u32) f32 {
        return self.data[col * 4 + row];
    }

    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var out: Mat4 = undefined;
        var col: u32 = 0;
        while (col < 4) : (col += 1) {
            var row: u32 = 0;
            while (row < 4) : (row += 1) {
                var sum: f32 = 0;
                var k: u32 = 0;
                while (k < 4) : (k += 1) {
                    sum += a.at(k, row) * b.at(col, k);
                }
                out.data[col * 4 + row] = sum;
            }
        }
        return out;
    }

    /// Right-handed look-at. Eye looks toward `target` with `up` roughly up.
    /// Output is the world→view transform; multiply by points expressed in
    /// world space to get view-space coordinates.
    pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
        const f = Vec3.normalize(Vec3.sub(target, eye)); // forward (-z in view)
        const s = Vec3.normalize(Vec3.cross(f, up)); // right (+x)
        const u = Vec3.cross(s, f); // recomputed up (+y)

        return .{
            .data = .{
                // col 0
                s.x,               u.x,               -f.x,             0,
                // col 1
                s.y,               u.y,               -f.y,             0,
                // col 2
                s.z,               u.z,               -f.z,             0,
                // col 3
                -Vec3.dot(s, eye), -Vec3.dot(u, eye), Vec3.dot(f, eye), 1,
            },
        };
    }

    /// Right-handed perspective for Vulkan NDC: y points down, z ∈ [0,1].
    /// `fov_y` is the vertical field of view in radians. `aspect` is W/H.
    pub fn perspective(fov_y: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const f = 1.0 / @tan(fov_y * 0.5);
        var out: Mat4 = .{ .data = std.mem.zeroes([16]f32) };
        out.data[0] = f / aspect; // [0][0]
        out.data[5] = -f; // [1][1] (Vulkan y-flip)
        out.data[10] = far / (near - far); // [2][2]
        out.data[11] = -1; // [2][3]
        out.data[14] = (near * far) / (near - far); // [3][2]
        return out;
    }
};

test "Mat4 identity multiplication" {
    const m: Mat4 = .{ .data = .{
        1,  2,  3,  4,
        5,  6,  7,  8,
        9,  10, 11, 12,
        13, 14, 15, 16,
    } };
    const r = Mat4.mul(Mat4.identity, m);
    try std.testing.expectEqualSlices(f32, &m.data, &r.data);
    const r2 = Mat4.mul(m, Mat4.identity);
    try std.testing.expectEqualSlices(f32, &m.data, &r2.data);
}

test "Mat4 perspective maps near/far to 0/1" {
    const eps: f32 = 1e-4;
    const p = Mat4.perspective(std.math.pi / 3.0, 16.0 / 9.0, 0.1, 100.0);

    // Point at (0,0,-near) in view space → clip.z / clip.w should be 0.
    // clip = p * (0,0,-0.1,1)
    const near_clip_z = p.at(2, 2) * -0.1 + p.at(3, 2) * 1.0;
    const near_clip_w = p.at(2, 3) * -0.1 + p.at(3, 3) * 1.0;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), near_clip_z / near_clip_w, eps);

    // Point at -far → clip.z / clip.w should be 1.
    const far_clip_z = p.at(2, 2) * -100.0 + p.at(3, 2) * 1.0;
    const far_clip_w = p.at(2, 3) * -100.0 + p.at(3, 3) * 1.0;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), far_clip_z / far_clip_w, eps);
}

test "Mat4 lookAt places eye at origin in view space" {
    const eps: f32 = 1e-5;
    const eye = Vec3.init(10, 5, 7);
    const view = Mat4.lookAt(eye, Vec3.zero, Vec3.up);

    // view * eye should land at (0,0,0,1).
    const c = .{
        view.at(0, 0) * eye.x + view.at(1, 0) * eye.y + view.at(2, 0) * eye.z + view.at(3, 0),
        view.at(0, 1) * eye.x + view.at(1, 1) * eye.y + view.at(2, 1) * eye.z + view.at(3, 1),
        view.at(0, 2) * eye.x + view.at(1, 2) * eye.y + view.at(2, 2) * eye.z + view.at(3, 2),
    };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), c[0], eps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), c[1], eps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), c[2], eps);
}

test "Vec3 cross is right-handed" {
    const x = Vec3.init(1, 0, 0);
    const y = Vec3.init(0, 1, 0);
    const z = Vec3.cross(x, y);
    try std.testing.expectEqual(@as(f32, 0), z.x);
    try std.testing.expectEqual(@as(f32, 0), z.y);
    try std.testing.expectEqual(@as(f32, 1), z.z);
}
