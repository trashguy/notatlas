//! M5.3 player entity. Owns yaw/pitch (head), pos (feet), and an optional
//! ship attachment. When attached, all three fields are interpreted in
//! ship-local frame; when unattached, in world frame. The frame change at
//! `boardShip` / `disembark` is a one-shot transform (the SoT-style
//! "ladder grab" semantic — see `current_work.md` notes on M5 design).
//!
//! World-space camera composition: when boarded, the consumer takes the
//! interpolated ship pose (M5.1's `(pose_prev, pose_curr)` slerp) and calls
//! `worldEye(ship_pose)` / `worldForward(ship_pose)`. Because the ship pose
//! is already smooth across render frames, and the player's local fields
//! are updated only on input (or constant when standing still), the
//! composed camera is jitter-free at any uncapped framerate. This is the
//! M5.3 headline gate.
//!
//! Lib-level (no render deps) so unit tests run under the existing
//! `zig build test` target. Callers in the sandbox build their own
//! `render.Camera` from `worldEye`, `worldForward`, and `fov_y`.
//!
//! Conventions match `math.zig`: y-up, -z forward at yaw=0, right-handed.
//! Quaternions are (x, y, z, w), matching Jolt / `math.Vec3.rotateByQuat`.

const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;

/// 6-DoF pose. Used for both ship pose (passed in by the caller from the
/// interpolated Jolt body) and player pose (`shipLocalPose` return).
pub const Pose = struct {
    pos: Vec3,
    rot: [4]f32, // x, y, z, w

    pub const identity: Pose = .{ .pos = Vec3.zero, .rot = .{ 0, 0, 0, 1 } };
};

pub const Move = struct {
    forward: f32 = 0,
    strafe: f32 = 0,
    up: f32 = 0,
};

pub const Player = struct {
    /// Head yaw (radians, around the frame's +Y). yaw=0 → forward is -Z
    /// in whichever frame the player is in (local when boarded, world
    /// otherwise).
    yaw: f32 = 0,
    /// Head pitch (radians, around the frame's local +X after yaw).
    /// Clamped to ±pitch_limit.
    pitch: f32 = 0,
    /// Feet position. Frame depends on `attached_ship`:
    ///   - attached_ship == null → world frame (free-agent / swim)
    ///   - attached_ship != null → ship-local frame (passenger)
    pos: Vec3 = Vec3.zero,
    /// Eye height above feet (m). 1.7 m = standard adult eye height.
    /// Always interpreted in the same frame as `pos`.
    eye_height: f32 = 1.7,

    move_speed_mps: f32 = 10.0,
    /// CS:GO-equivalent at 1280×720. The de-facto FPS default; expose
    /// later if it turns out we need per-display tuning.
    mouse_sensitivity_rad_per_px: f32 = 0.0022,
    fov_y: f32 = std.math.degreesToRadians(60.0),

    /// Opaque ship id (caller-defined — typically a Jolt BodyId or an
    /// engine-side ship handle). `null` = unboarded. M5.3 sandbox spawns
    /// pre-boarded; disembark/swim is reserved API for later milestones.
    attached_ship: ?u32 = null,

    /// ~89.5°. Slightly inside ±π/2 so `forward()` keeps a non-zero
    /// horizontal component and `lookAt` doesn't degenerate.
    pub const pitch_limit: f32 = 0.499 * std.math.pi;

    /// World→local handoff. Caller supplies the ship-local feet position
    /// (typically `(0, deck_y, 0)` for a centered spawn). Yaw/pitch are
    /// preserved — frame interpretation flips at the world-pose
    /// composition site, not on the field values.
    pub fn boardShip(self: *Player, ship_id: u32, local_pos: Vec3) void {
        self.attached_ship = ship_id;
        self.pos = local_pos;
    }

    /// Local→world handoff. Snapshots the world-space feet pose at the
    /// moment of disembark so the player keeps continuity through the
    /// transition — the SoT semantic where dropping off the ladder leaves
    /// you exactly where you were a frame ago, not glued to the deck.
    pub fn disembark(self: *Player, ship_pose: Pose) void {
        if (self.attached_ship == null) return;
        const world_pos = Vec3.add(
            ship_pose.pos,
            Vec3.rotateByQuat(self.pos, ship_pose.rot),
        );
        self.pos = world_pos;
        self.attached_ship = null;
    }

    /// `null` if not attached. Pose returned is feet position + head
    /// rotation in ship-local frame — the value the architecture spec
    /// (`docs/03-engine-subsystems.md` §5) refers to as
    /// `player_local_pose` in `world = ship ⊗ player_local`.
    pub fn shipLocalPose(self: Player) ?Pose {
        if (self.attached_ship == null) return null;
        return .{ .pos = self.pos, .rot = headQuat(self.yaw, self.pitch) };
    }

    /// Forward unit vector in the player's frame (local when boarded,
    /// world otherwise). Combine with `worldForward` for the world-frame
    /// look direction at the camera.
    pub fn forward(self: Player) Vec3 {
        const cy = @cos(self.yaw);
        const sy = @sin(self.yaw);
        const cp = @cos(self.pitch);
        const sp = @sin(self.pitch);
        return Vec3.init(-cp * sy, sp, -cp * cy);
    }

    /// Frame-horizontal right vector (independent of pitch). Used for
    /// strafe so look-up while strafing doesn't drift the player upward
    /// in their own frame.
    pub fn right(self: Player) Vec3 {
        return Vec3.init(@cos(self.yaw), 0, -@sin(self.yaw));
    }

    pub fn applyMouseDelta(self: *Player, dx_px: f32, dy_px: f32) void {
        self.yaw -= dx_px * self.mouse_sensitivity_rad_per_px;
        self.pitch -= dy_px * self.mouse_sensitivity_rad_per_px;
        self.pitch = std.math.clamp(self.pitch, -pitch_limit, pitch_limit);
        // Wrap yaw to keep the f32 mantissa happy on long runs.
        self.yaw = @mod(self.yaw + std.math.pi, std.math.tau) - std.math.pi;
    }

    pub fn applyMove(self: *Player, m: Move, dt: f32) void {
        const fwd = self.forward();
        // Project forward onto the frame's horizontal plane so WASD speed
        // doesn't change with look pitch. When boarded this is the deck
        // plane (modulo ship roll, applied by the world composition).
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

    /// Constrain the player to a rectangular deck plane in ship-local
    /// space. Snaps `pos.y` to the deck and bounds `pos.x` / `pos.z` to
    /// `±(half - inset)`, so walking off the box edge doesn't float you
    /// in local-space air. `inset` accounts for player width — at the
    /// camera that's the gap between the eye and the deck-edge corner
    /// before view-frustum clipping starts to feel cramped.
    ///
    /// No-op when not attached. M5.4 minimal scope: hard clamp, no edge
    /// step-off / fall-off (sandbox doesn't have a swim state to drop
    /// into yet); the "magnetic boots" gameplay-comfort lever — projecting
    /// WASD onto world-horizontal so a rolling deck doesn't make W feel
    /// vertical — would also live here when we add it.
    pub fn clampToDeck(
        self: *Player,
        deck_y: f32,
        half_x: f32,
        half_z: f32,
        inset: f32,
    ) void {
        if (self.attached_ship == null) return;
        self.pos.y = deck_y;
        const max_x = @max(0.0, half_x - inset);
        const max_z = @max(0.0, half_z - inset);
        self.pos.x = std.math.clamp(self.pos.x, -max_x, max_x);
        self.pos.z = std.math.clamp(self.pos.z, -max_z, max_z);
    }

    /// World-space eye position. When attached, composes the local eye
    /// (feet + eye_height) through the ship's pose; when not attached,
    /// interprets `pos` as world-frame.
    ///
    /// Pass the *interpolated* ship pose (M5.1) so the camera stays
    /// smooth at high render rates.
    pub fn worldEye(self: Player, ship_pose: Pose) Vec3 {
        const local_eye = Vec3.init(self.pos.x, self.pos.y + self.eye_height, self.pos.z);
        if (self.attached_ship == null) return local_eye;
        return Vec3.add(ship_pose.pos, Vec3.rotateByQuat(local_eye, ship_pose.rot));
    }

    /// World-space forward unit vector. When attached, the head's local
    /// forward is rotated into world frame by the ship's rotation; when
    /// not attached, `forward()` is already world-frame.
    pub fn worldForward(self: Player, ship_pose: Pose) Vec3 {
        const fwd = self.forward();
        if (self.attached_ship == null) return fwd;
        return Vec3.rotateByQuat(fwd, ship_pose.rot);
    }
};

/// Yaw around +Y composed with pitch around the *local* +X (after yaw),
/// returning the combined unit quaternion in (x, y, z, w) order. This is
/// the standard FPS-camera head orientation.
///
/// Derivation: q_yaw = (0, sin(yaw/2), 0, cos(yaw/2)),
/// q_pitch = (sin(pitch/2), 0, 0, cos(pitch/2)). Hamilton product
/// q_yaw · q_pitch encodes "yaw first, then pitch in the rotated frame."
fn headQuat(yaw: f32, pitch: f32) [4]f32 {
    const cy = @cos(yaw * 0.5);
    const sy = @sin(yaw * 0.5);
    const cp = @cos(pitch * 0.5);
    const sp = @sin(pitch * 0.5);
    return .{
        cy * sp,
        sy * cp,
        -sy * sp,
        cy * cp,
    };
}

// ---- preserved from M5.2 (renamed FlyCamera → Player) ----

test "Player forward at zero yaw/pitch points -z" {
    const p: Player = .{};
    const f = p.forward();
    try std.testing.expectApproxEqAbs(@as(f32, 0), f.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), f.y, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1), f.z, 1e-6);
}

test "Player yaw 90deg points -x" {
    var p: Player = .{};
    p.yaw = std.math.pi * 0.5;
    const f = p.forward();
    try std.testing.expectApproxEqAbs(@as(f32, -1), f.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), f.y, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), f.z, 1e-6);
}

test "Player pitch 45deg lifts forward" {
    var p: Player = .{};
    p.pitch = std.math.pi * 0.25;
    const f = p.forward();
    const s2 = @sqrt(@as(f32, 0.5));
    try std.testing.expectApproxEqAbs(@as(f32, 0), f.x, 1e-6);
    try std.testing.expectApproxEqAbs(s2, f.y, 1e-6);
    try std.testing.expectApproxEqAbs(-s2, f.z, 1e-6);
}

test "Player applyMouseDelta clamps pitch" {
    var p: Player = .{};
    p.applyMouseDelta(0, 100_000.0);
    try std.testing.expect(p.pitch >= -Player.pitch_limit);
    try std.testing.expect(p.pitch <= Player.pitch_limit);
}

test "Player applyMove forward stays planar at any pitch" {
    var p: Player = .{};
    p.pitch = std.math.pi * 0.4;
    p.applyMove(.{ .forward = 1 }, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), p.pos.y, 1e-6);
    try std.testing.expect(p.pos.z < 0);
}

test "Player applyMove strafe is perpendicular to forward" {
    var p: Player = .{};
    p.applyMove(.{ .strafe = 1 }, 1.0);
    try std.testing.expect(p.pos.x > 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), p.pos.z, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), p.pos.y, 1e-6);
}

// ---- M5.3 boarding + composition ----

test "boardShip flips attached state and sets local_pos" {
    var p: Player = .{};
    try std.testing.expect(p.attached_ship == null);
    p.boardShip(42, Vec3.init(1, 2, 3));
    try std.testing.expectEqual(@as(u32, 42), p.attached_ship.?);
    try std.testing.expectEqual(@as(f32, 1), p.pos.x);
    try std.testing.expectEqual(@as(f32, 2), p.pos.y);
    try std.testing.expectEqual(@as(f32, 3), p.pos.z);
}

test "shipLocalPose null when unattached, populated when attached" {
    var p: Player = .{};
    try std.testing.expect(p.shipLocalPose() == null);
    p.boardShip(1, Vec3.init(0, 2, 0));
    const lp = p.shipLocalPose().?;
    try std.testing.expectEqual(@as(f32, 0), lp.pos.x);
    try std.testing.expectEqual(@as(f32, 2), lp.pos.y);
    try std.testing.expectEqual(@as(f32, 0), lp.pos.z);
    // headQuat(0, 0) is identity.
    try std.testing.expectApproxEqAbs(@as(f32, 1), lp.rot[3], 1e-6);
}

test "worldEye unattached returns local + eye_height" {
    var p: Player = .{};
    p.pos = Vec3.init(10, 0, 5);
    p.eye_height = 1.7;
    // ship_pose is irrelevant when unattached, but the API requires one.
    const we = p.worldEye(Pose.identity);
    try std.testing.expectApproxEqAbs(@as(f32, 10), we.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.7), we.y, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 5), we.z, 1e-6);
}

test "worldEye attached + identity ship pose = local eye" {
    var p: Player = .{};
    p.boardShip(1, Vec3.init(0, 2, 0));
    p.eye_height = 1.7;
    const we = p.worldEye(Pose.identity);
    try std.testing.expectApproxEqAbs(@as(f32, 0), we.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.7), we.y, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), we.z, 1e-6);
}

test "worldEye attached + ship translated = local + ship pos" {
    var p: Player = .{};
    p.boardShip(1, Vec3.init(0, 2, 0));
    p.eye_height = 1.7;
    const ship: Pose = .{ .pos = Vec3.init(100, 4, -50), .rot = .{ 0, 0, 0, 1 } };
    const we = p.worldEye(ship);
    try std.testing.expectApproxEqAbs(@as(f32, 100), we.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4 + 3.7), we.y, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -50), we.z, 1e-6);
}

test "worldEye attached + ship yawed 90deg rotates the offset" {
    var p: Player = .{};
    // Stand off-center on the deck so a yaw is detectable.
    p.boardShip(1, Vec3.init(2, 2, 0));
    p.eye_height = 1.7;
    // Ship yawed 90° around +Y (CCW from above): rotates (+x, *, *) to
    // (*, *, -x). So local (2, 3.7, 0) → world (0, 3.7, -2).
    const s2 = @sqrt(@as(f32, 0.5));
    const ship: Pose = .{ .pos = Vec3.zero, .rot = .{ 0, s2, 0, s2 } };
    const we = p.worldEye(ship);
    try std.testing.expectApproxEqAbs(@as(f32, 0), we.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 3.7), we.y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -2), we.z, 1e-5);
}

test "worldForward attached + ship rolled tips player view" {
    // Player looking forward (yaw=0, pitch=0) → local forward = -Z.
    // Ship rolls 90° around +Z: local -Z stays -Z (the roll axis), so
    // forward shouldn't change. Use ship roll around +X instead, which
    // pitches the deck — local -Z should pick up a +Y component.
    var p: Player = .{};
    p.boardShip(1, Vec3.zero);
    const s2 = @sqrt(@as(f32, 0.5));
    // 90° around +X: rotates -Z to +Y.
    const ship: Pose = .{ .pos = Vec3.zero, .rot = .{ s2, 0, 0, s2 } };
    const wf = p.worldForward(ship);
    try std.testing.expectApproxEqAbs(@as(f32, 0), wf.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), wf.y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), wf.z, 1e-5);
}

test "disembark snapshots world pos and clears attachment" {
    var p: Player = .{};
    p.boardShip(1, Vec3.init(2, 2, 0));
    const ship: Pose = .{ .pos = Vec3.init(10, 0, 0), .rot = .{ 0, 0, 0, 1 } };
    p.disembark(ship);
    try std.testing.expect(p.attached_ship == null);
    // world feet = ship_pos + rotated(local_pos, identity) = (10,0,0) + (2,2,0)
    try std.testing.expectApproxEqAbs(@as(f32, 12), p.pos.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2), p.pos.y, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), p.pos.z, 1e-6);
}

test "clampToDeck snaps y and bounds x/z when attached" {
    var p: Player = .{};
    p.boardShip(1, Vec3.init(5, -10, 5));
    // 4m cube → half_extents=2; inset 0.3 → walkable ±1.7.
    p.clampToDeck(2.0, 2.0, 2.0, 0.3);
    try std.testing.expectApproxEqAbs(@as(f32, 2), p.pos.y, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.7), p.pos.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.7), p.pos.z, 1e-6);
}

test "clampToDeck preserves in-bounds pos" {
    var p: Player = .{};
    p.boardShip(1, Vec3.init(0.5, 99, -0.5));
    p.clampToDeck(2.0, 2.0, 2.0, 0.3);
    try std.testing.expectApproxEqAbs(@as(f32, 2), p.pos.y, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), p.pos.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), p.pos.z, 1e-6);
}

test "clampToDeck noop when unattached" {
    var p: Player = .{};
    p.pos = Vec3.init(100, 100, 100);
    p.clampToDeck(2.0, 2.0, 2.0, 0.3);
    try std.testing.expectEqual(@as(f32, 100), p.pos.x);
    try std.testing.expectEqual(@as(f32, 100), p.pos.y);
    try std.testing.expectEqual(@as(f32, 100), p.pos.z);
}

test "clampToDeck handles inset >= half (degenerate small deck)" {
    var p: Player = .{};
    p.boardShip(1, Vec3.init(5, 0, -3));
    // inset > half → walkable area collapses to the deck centerline.
    p.clampToDeck(0.0, 0.5, 0.5, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), p.pos.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), p.pos.z, 1e-6);
}

test "headQuat at zero is identity" {
    const q = headQuat(0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), q[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), q[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), q[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), q[3], 1e-6);
}

test "headQuat unit length at random angles" {
    const angles: [3][2]f32 = .{
        .{ 1.234, -0.567 },
        .{ -2.7, 1.4 },
        .{ 0.1, std.math.pi * 0.4 },
    };
    for (angles) |ay| {
        const q = headQuat(ay[0], ay[1]);
        const len2 = q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3];
        try std.testing.expectApproxEqAbs(@as(f32, 1), len2, 1e-5);
    }
}
