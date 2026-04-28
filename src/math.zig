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

    /// Rotate a vector by a unit quaternion (x,y,z,w). Uses the identity
    /// v' = v + 2·u × (u × v + w·v) where u = q.xyz; cheaper than building a
    /// 3×3 rotation matrix and matches Jolt's quaternion convention.
    pub fn rotateByQuat(v: Vec3, q: [4]f32) Vec3 {
        const u: Vec3 = .{ .x = q[0], .y = q[1], .z = q[2] };
        const w = q[3];
        const t = scale(cross(u, v), 2.0);
        return add(v, add(scale(cross(u, t), 1.0), scale(t, w)));
    }
};

/// Spherical-linear interpolation between two unit quaternions in
/// `(x, y, z, w)` order (Jolt convention). Used for sub-tick rendering
/// of physics bodies — at frame time we slerp between `pose_prev` and
/// `pose_curr` by the accumulator alpha so the visual is smooth even
/// when render rate ≫ physics rate.
///
/// Negates `b` if `dot(a, b) < 0` to take the shortest-arc path —
/// quaternions q and -q encode the same rotation but slerp without
/// the flip walks the long way around when they straddle the
/// hemisphere boundary.
///
/// For nearly-aligned inputs the trig form loses precision, so above
/// `dot > 0.9995` we fall back to nlerp (lerp + renormalize), which is
/// well-defined and visually identical at small angles.
pub fn quatSlerp(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    var b2 = b;
    var d = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
    if (d < 0) {
        b2 = .{ -b[0], -b[1], -b[2], -b[3] };
        d = -d;
    }
    if (d > 0.9995) {
        const r: [4]f32 = .{
            a[0] + (b2[0] - a[0]) * t,
            a[1] + (b2[1] - a[1]) * t,
            a[2] + (b2[2] - a[2]) * t,
            a[3] + (b2[3] - a[3]) * t,
        };
        const len2 = r[0] * r[0] + r[1] * r[1] + r[2] * r[2] + r[3] * r[3];
        if (len2 == 0) return .{ 0, 0, 0, 1 };
        const inv = 1.0 / @sqrt(len2);
        return .{ r[0] * inv, r[1] * inv, r[2] * inv, r[3] * inv };
    }
    const d_clamped = @max(@as(f32, -1.0), @min(@as(f32, 1.0), d));
    const theta_0 = std.math.acos(d_clamped);
    const theta = theta_0 * t;
    const sin_theta = @sin(theta);
    const sin_theta_0 = @sin(theta_0);
    const s0 = @cos(theta) - d * sin_theta / sin_theta_0;
    const s1 = sin_theta / sin_theta_0;
    return .{
        s0 * a[0] + s1 * b2[0],
        s0 * a[1] + s1 * b2[1],
        s0 * a[2] + s1 * b2[2],
        s0 * a[3] + s1 * b2[3],
    };
}

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

    /// Build a TRS matrix from translation + quaternion (x,y,z,w) +
    /// per-axis scale. Quaternion convention matches Jolt: x,y,z is the
    /// imaginary part, w is the scalar. Result is `T · R · S` so points
    /// are scaled, then rotated, then translated when multiplied on the
    /// right.
    pub fn trs(translation: Vec3, quat: [4]f32, scale_xyz: Vec3) Mat4 {
        const x = quat[0];
        const y = quat[1];
        const z = quat[2];
        const w = quat[3];
        const xx = x * x;
        const yy = y * y;
        const zz = z * z;
        const xy = x * y;
        const xz = x * z;
        const yz = y * z;
        const wx = w * x;
        const wy = w * y;
        const wz = w * z;
        const sx = scale_xyz.x;
        const sy = scale_xyz.y;
        const sz = scale_xyz.z;
        return .{
            .data = .{
                // col 0 = R · (sx, 0, 0, 0)
                (1 - 2 * (yy + zz)) * sx, (2 * (xy + wz)) * sx, (2 * (xz - wy)) * sx, 0,
                // col 1 = R · (0, sy, 0, 0)
                (2 * (xy - wz)) * sy, (1 - 2 * (xx + zz)) * sy, (2 * (yz + wx)) * sy, 0,
                // col 2 = R · (0, 0, sz, 0)
                (2 * (xz + wy)) * sz, (2 * (yz - wx)) * sz, (1 - 2 * (xx + yy)) * sz, 0,
                // col 3 = translation
                translation.x, translation.y, translation.z, 1,
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

test "Mat4.trs identity quaternion translates a point" {
    const m = Mat4.trs(Vec3.init(3, 5, 7), .{ 0, 0, 0, 1 }, Vec3.init(1, 1, 1));
    // m · (1,2,3,1) = (1+3, 2+5, 3+7, 1) = (4, 7, 10, 1)
    const px = m.at(0, 0) * 1 + m.at(1, 0) * 2 + m.at(2, 0) * 3 + m.at(3, 0);
    const py = m.at(0, 1) * 1 + m.at(1, 1) * 2 + m.at(2, 1) * 3 + m.at(3, 1);
    const pz = m.at(0, 2) * 1 + m.at(1, 2) * 2 + m.at(2, 2) * 3 + m.at(3, 2);
    try std.testing.expectApproxEqAbs(@as(f32, 4), px, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 7), py, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 10), pz, 1e-5);
}

test "Vec3.rotateByQuat 90deg around y rotates +x to -z" {
    const s2 = @sqrt(@as(f32, 0.5));
    const r = Vec3.rotateByQuat(Vec3.init(1, 0, 0), .{ 0, s2, 0, s2 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1), r.z, 1e-5);
}

test "Vec3.rotateByQuat identity preserves vector" {
    const v = Vec3.init(3, -7, 2);
    const r = Vec3.rotateByQuat(v, .{ 0, 0, 0, 1 });
    try std.testing.expectApproxEqAbs(v.x, r.x, 1e-5);
    try std.testing.expectApproxEqAbs(v.y, r.y, 1e-5);
    try std.testing.expectApproxEqAbs(v.z, r.z, 1e-5);
}

test "quatSlerp endpoints return inputs (up to sign)" {
    const a: [4]f32 = .{ 0, 0, 0, 1 };
    const s2 = @sqrt(@as(f32, 0.5));
    const b: [4]f32 = .{ 0, s2, 0, s2 }; // 90° around y
    const r0 = quatSlerp(a, b, 0);
    const r1 = quatSlerp(a, b, 1);
    for (0..4) |i| {
        try std.testing.expectApproxEqAbs(a[i], r0[i], 1e-6);
        try std.testing.expectApproxEqAbs(b[i], r1[i], 1e-6);
    }
}

test "quatSlerp halfway between identity and 90deg-y is 45deg-y" {
    const a: [4]f32 = .{ 0, 0, 0, 1 };
    const s2 = @sqrt(@as(f32, 0.5));
    const b: [4]f32 = .{ 0, s2, 0, s2 };
    const r = quatSlerp(a, b, 0.5);
    // 45° around y: (0, sin(22.5°), 0, cos(22.5°))
    const half = std.math.pi / 8.0;
    try std.testing.expectApproxEqAbs(@as(f32, 0), r[0], 1e-5);
    try std.testing.expectApproxEqAbs(@sin(half), r[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r[2], 1e-5);
    try std.testing.expectApproxEqAbs(@cos(half), r[3], 1e-5);

    // And the result is a unit quaternion.
    const len2 = r[0] * r[0] + r[1] * r[1] + r[2] * r[2] + r[3] * r[3];
    try std.testing.expectApproxEqAbs(@as(f32, 1), len2, 1e-5);
}

test "quatSlerp takes shortest path when inputs straddle hemisphere" {
    // Same rotation, opposite signs — slerp should walk a zero arc, not 360°.
    const a: [4]f32 = .{ 0, 0, 0, 1 };
    const b: [4]f32 = .{ 0, 0, 0, -1 };
    const r = quatSlerp(a, b, 0.5);
    // After sign-flip, b is treated as identity; midpoint should be
    // identity (or its negation — same rotation).
    const w_abs = @abs(r[3]);
    try std.testing.expectApproxEqAbs(@as(f32, 1), w_abs, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r[2], 1e-5);
}

test "quatSlerp small-angle path stays unit-length" {
    // Nearly-aligned inputs hit the nlerp branch.
    const a: [4]f32 = .{ 0, 0, 0, 1 };
    const b: [4]f32 = .{ 0.001, 0, 0, @sqrt(1.0 - 0.001 * 0.001) };
    const r = quatSlerp(a, b, 0.3);
    const len2 = r[0] * r[0] + r[1] * r[1] + r[2] * r[2] + r[3] * r[3];
    try std.testing.expectApproxEqAbs(@as(f32, 1), len2, 1e-5);
}

test "Mat4.trs 90deg-around-y rotates +x to -z" {
    // Quaternion for +90° around y: (0, sin(45°), 0, cos(45°))
    const s2 = @sqrt(@as(f32, 0.5));
    const m = Mat4.trs(Vec3.zero, .{ 0, s2, 0, s2 }, Vec3.init(1, 1, 1));
    const px = m.at(0, 0) * 1 + m.at(1, 0) * 0 + m.at(2, 0) * 0;
    const py = m.at(0, 1) * 1 + m.at(1, 1) * 0 + m.at(2, 1) * 0;
    const pz = m.at(0, 2) * 1 + m.at(1, 2) * 0 + m.at(2, 2) * 0;
    try std.testing.expectApproxEqAbs(@as(f32, 0), px, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), py, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1), pz, 1e-5);
}
