//! M5.2 first-person free-fly camera. Owns world-space pos + yaw/pitch and
//! produces the eye/forward/fov triple the renderer needs. No gravity, no
//! collision — the deliverable is "input → view matrix," not movement
//! physics. Once M5.3 boards a ship, the camera's `pos` becomes the world
//! projection of `ship_pose ⊗ player_local_pose`; the WASD/mouse plumbing
//! built here is reused unchanged.
//!
//! Lib-level (no render deps) so unit tests run under the existing
//! `zig build test` target. Callers in the sandbox build their own
//! `render.Camera` from `pos`, `forward()`, and `fov_y`.
//!
//! Conventions match `math.zig`: y-up, -z forward at yaw=0, right-handed.
//! Mouse delta sign matches the FPS standard — moving the cursor right
//! yaws the view right, moving down pitches down. Pitch is clamped just
//! below ±π/2 so `forward()` never collapses to (0, ±1, 0) (the look-at
//! basis would degenerate).

const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;

pub const FlyCamera = struct {
    pos: Vec3,
    yaw: f32 = 0,
    pitch: f32 = 0,
    move_speed_mps: f32 = 10.0,
    /// CS:GO-equivalent at 1280×720. Doubles as the de-facto FPS default;
    /// expose later if it turns out we need per-display tuning.
    mouse_sensitivity_rad_per_px: f32 = 0.0022,
    fov_y: f32 = std.math.degreesToRadians(60.0),

    /// ~89.5°. Slightly inside ±π/2 so `forward()` keeps a non-zero
    /// horizontal component and `lookAt` doesn't degenerate.
    pub const pitch_limit: f32 = 0.499 * std.math.pi;

    pub fn forward(self: FlyCamera) Vec3 {
        const cy = @cos(self.yaw);
        const sy = @sin(self.yaw);
        const cp = @cos(self.pitch);
        const sp = @sin(self.pitch);
        return Vec3.init(-cp * sy, sp, -cp * cy);
    }

    /// World-horizontal right vector (independent of pitch). Used for
    /// strafe so look-up while strafing doesn't drift you upward.
    pub fn right(self: FlyCamera) Vec3 {
        return Vec3.init(@cos(self.yaw), 0, -@sin(self.yaw));
    }

    pub fn applyMouseDelta(self: *FlyCamera, dx_px: f32, dy_px: f32) void {
        self.yaw -= dx_px * self.mouse_sensitivity_rad_per_px;
        self.pitch -= dy_px * self.mouse_sensitivity_rad_per_px;
        self.pitch = std.math.clamp(self.pitch, -pitch_limit, pitch_limit);
        // Wrap yaw to keep the f32 mantissa happy on long runs.
        self.yaw = @mod(self.yaw + std.math.pi, std.math.tau) - std.math.pi;
    }

    pub const Move = struct {
        forward: f32 = 0,
        strafe: f32 = 0,
        up: f32 = 0,
    };

    pub fn applyMove(self: *FlyCamera, m: Move, dt: f32) void {
        const fwd = self.forward();
        // Project forward onto the world horizontal plane so WASD speed
        // doesn't change with look pitch (and you don't drift skyward
        // while walking up a hill that doesn't exist yet).
        const fwd_h = blk: {
            const len2 = fwd.x * fwd.x + fwd.z * fwd.z;
            if (len2 < 1e-6) break :blk Vec3.init(0, 0, -1);
            const inv = 1.0 / @sqrt(len2);
            break :blk Vec3.init(fwd.x * inv, 0, fwd.z * inv);
        };
        const r = self.right();
        const step = self.move_speed_mps * dt;
        self.pos = Vec3.add(self.pos, Vec3.scale(fwd_h, m.forward * step));
        self.pos = Vec3.add(self.pos, Vec3.scale(r, m.strafe * step));
        self.pos.y += m.up * step;
    }

};

test "FlyCamera forward at zero yaw/pitch points -z" {
    const fc: FlyCamera = .{ .pos = Vec3.zero };
    const f = fc.forward();
    try std.testing.expectApproxEqAbs(@as(f32, 0), f.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), f.y, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1), f.z, 1e-6);
}

test "FlyCamera yaw 90deg points -x" {
    var fc: FlyCamera = .{ .pos = Vec3.zero };
    fc.yaw = std.math.pi * 0.5;
    const f = fc.forward();
    try std.testing.expectApproxEqAbs(@as(f32, -1), f.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), f.y, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), f.z, 1e-6);
}

test "FlyCamera pitch 45deg lifts forward" {
    var fc: FlyCamera = .{ .pos = Vec3.zero };
    fc.pitch = std.math.pi * 0.25;
    const f = fc.forward();
    const s2 = @sqrt(@as(f32, 0.5));
    try std.testing.expectApproxEqAbs(@as(f32, 0), f.x, 1e-6);
    try std.testing.expectApproxEqAbs(s2, f.y, 1e-6);
    try std.testing.expectApproxEqAbs(-s2, f.z, 1e-6);
}

test "FlyCamera applyMouseDelta clamps pitch" {
    var fc: FlyCamera = .{ .pos = Vec3.zero };
    // 100,000 px down — would over-rotate; clamp must hold.
    fc.applyMouseDelta(0, 100_000.0);
    try std.testing.expect(fc.pitch >= -FlyCamera.pitch_limit);
    try std.testing.expect(fc.pitch <= FlyCamera.pitch_limit);
}

test "FlyCamera applyMove forward stays planar at any pitch" {
    var fc: FlyCamera = .{ .pos = Vec3.zero };
    fc.pitch = std.math.pi * 0.4; // looking near-up
    fc.applyMove(.{ .forward = 1 }, 1.0);
    // Looking up + W should NOT lift the position.
    try std.testing.expectApproxEqAbs(@as(f32, 0), fc.pos.y, 1e-6);
    try std.testing.expect(fc.pos.z < 0); // moved in -z
}

test "FlyCamera applyMove strafe is perpendicular to forward" {
    var fc: FlyCamera = .{ .pos = Vec3.zero };
    fc.applyMove(.{ .strafe = 1 }, 1.0);
    // yaw=0 → right is +x.
    try std.testing.expect(fc.pos.x > 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), fc.pos.z, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), fc.pos.y, 1e-6);
}
