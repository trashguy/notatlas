//! M12 — animation-LOD.
//!
//! Three-tier dispatch based on camera distance. Tier thresholds
//! match `docs/03-engine-subsystems.md §12`:
//!
//!   .near (d ≤ near_threshold, default 30 m)   tick every frame
//!   .mid  (d ≤ mid_threshold,  default 100 m)  tick at mid_hz (default 5 Hz)
//!   .far  (d > mid_threshold)                  zero CPU work
//!
//! **v0 placeholder.** No skeletal-animation system exists in the
//! engine yet. "Full rig + IK", "reduced rig", and "vertex-shader anim
//! atlas" from §12 are bucket *intents*, not implemented. What this
//! module IS actually proving:
//!
//!   1. Tier-distance arithmetic + dispatch is correct (every char
//!      lands in exactly one bucket per frame; the far bucket never
//!      hits the tick path).
//!   2. CPU tick cost stays under the M12 budget (≤2 ms / frame) at
//!      the design cap (200 chars at varied distances).
//!
//! Per-tier work is synthetic: a configurable `bone_count` knob does
//! N small rotation accumulations and writes a fresh model matrix to
//! the Instanced renderer. Real skinning at M27 swaps glTF skeletons
//! + a skin-palette upload into the same dispatch — the bucket
//! arithmetic + budget gate carries forward. The synthetic→real diff
//! is the M27 re-gate's job; capture the placeholder numbers in
//! `docs/research/m12_animation_lod_synthetic.md` so that diff is
//! meaningful.

const std = @import("std");
const notatlas = @import("notatlas");
const instanced_mod = @import("instanced.zig");

const Vec3 = notatlas.math.Vec3;
const Instanced = instanced_mod.Instanced;
const InstanceId = instanced_mod.InstanceId;

pub const AnimLodTier = enum(u32) {
    near = 0,
    mid = 1,
    far = 2,
};

/// Pure tier-distance arithmetic. No hysteresis — the M12 gate scene
/// places characters in static distance bands; thrash isn't a concern
/// at this milestone. M27 with real entities + moving camera adds it
/// the same way `cluster_merge.Anchorage` already does for M11.
pub fn animLodSelect(
    distance: f32,
    near_threshold: f32,
    mid_threshold: f32,
) AnimLodTier {
    if (distance <= near_threshold) return .near;
    if (distance <= mid_threshold) return .mid;
    return .far;
}

pub const Character = struct {
    id: InstanceId,
    /// World-space anchor — the character's static position. Tick
    /// produces `base_model + bobble(t, phase, amp)` and writes that
    /// to the instance buffer.
    base_model: [16]f32,
    /// World-space center used for the distance test. Cached at spawn
    /// so we don't re-extract it from base_model every frame.
    anchor: [3]f32,
    /// Phase offset in radians. De-syncs visually-identical chars so
    /// the bobble pattern doesn't look like a parade. Stored as f32
    /// instead of derived-from-id so the diff metadata is explicit.
    phase: f32,
    /// Bobble amplitude in metres (vertical translation only).
    amp: f32,
    /// Last selected tier — diagnostic; the tick re-selects every
    /// frame, this is just for the gate report.
    last_tier: AnimLodTier = .far,
};

pub const TickStats = struct {
    /// Per-tier counts of characters touched THIS frame. Mid is the
    /// per-frame subset (only when the 5 Hz accumulator fired);
    /// `mid_in_band` is the full set in the mid distance band.
    near_ticked: u32 = 0,
    mid_ticked: u32 = 0,
    mid_in_band: u32 = 0,
    far_skipped: u32 = 0,
    /// Nanoseconds spent inside `System.tick` body. Excludes the
    /// caller-side timer setup.
    elapsed_ns: u64 = 0,
};

pub const Config = struct {
    near_threshold: f32 = 30.0,
    mid_threshold: f32 = 100.0,
    /// Mid-tier tick rate in Hz. §12 calls for 5 Hz.
    mid_hz: f32 = 5.0,
    /// Synthetic bone counts. Each "bone" runs a single
    /// rotation-accumulation pass (cos + sin + 4 mul + 1 sub) — same
    /// shape as a tiny mat3·vec3 inner loop. At M27 a real glTF
    /// skinning kernel replaces this; near/mid bone counts then
    /// reflect actual rig complexity.
    near_bones: u32 = 32,
    mid_bones: u32 = 8,
};

pub const System = struct {
    chars: []Character,
    cfg: Config,
    /// Accumulator for the mid-tier 5 Hz gate. Crosses
    /// 1/mid_hz seconds → mid tick fires this frame.
    mid_accum: f32 = 0,
    /// Monotonic seconds since spawn — passed to the per-char tick
    /// so the bobble pattern is reproducible across runs.
    elapsed: f32 = 0,
    /// Last completed tick's stats (gate report reads these).
    last: TickStats = .{},

    pub fn init(chars: []Character, cfg: Config) System {
        return .{ .chars = chars, .cfg = cfg };
    }

    pub fn tick(
        self: *System,
        camera_pos: Vec3,
        dt: f32,
        inst: *Instanced,
    ) void {
        var timer = std.time.Timer.start() catch {
            // Timer unavailable — still run the tick so the scene
            // animates; just don't report nanos.
            self.tickInner(camera_pos, dt, inst);
            return;
        };
        self.tickInner(camera_pos, dt, inst);
        self.last.elapsed_ns = timer.read();
    }

    fn tickInner(
        self: *System,
        camera_pos: Vec3,
        dt: f32,
        inst: *Instanced,
    ) void {
        _ = inst; // M12.2: vertex shader synthesizes the bobble for all
        // anim-eligible instances via `meta.yz`. The CPU side does
        // synthetic skinning work (simBones) but does NOT write back
        // to the instance buffer — that matches the "far tier = zero
        // CPU work" intent, and keeps near/mid honest about the work
        // shape (real skinning at M27 will write to a separate skin-
        // palette SSBO, not back into the model matrix).
        self.elapsed += dt;
        self.mid_accum += dt;
        const mid_period: f32 = 1.0 / @max(self.cfg.mid_hz, 0.001);
        const mid_fires_this_frame = self.mid_accum >= mid_period;
        if (mid_fires_this_frame) {
            self.mid_accum -= mid_period;
            if (self.mid_accum >= mid_period) self.mid_accum = 0;
        }

        var stats: TickStats = .{};

        for (self.chars) |*c| {
            const dx = c.anchor[0] - camera_pos.x;
            const dy = c.anchor[1] - camera_pos.y;
            const dz = c.anchor[2] - camera_pos.z;
            const dist: f32 = @sqrt(dx * dx + dy * dy + dz * dz);
            const tier = animLodSelect(dist, self.cfg.near_threshold, self.cfg.mid_threshold);
            c.last_tier = tier;

            switch (tier) {
                .near => {
                    stats.near_ticked += 1;
                    self.simBones(self.cfg.near_bones, c.phase);
                },
                .mid => {
                    stats.mid_in_band += 1;
                    if (mid_fires_this_frame) {
                        stats.mid_ticked += 1;
                        self.simBones(self.cfg.mid_bones, c.phase);
                    }
                },
                .far => {
                    stats.far_skipped += 1;
                    // Zero CPU work by contract — shader handles the
                    // bobble via cam.eye.w + meta.yz.
                },
            }
        }

        const prev_ns = self.last.elapsed_ns;
        self.last = stats;
        self.last.elapsed_ns = prev_ns;
    }

    /// Synthetic per-bone work. `accum` is intentionally written to a
    /// volatile field so LLVM doesn't fold the loop away when the
    /// caller doesn't observe the result. At M27 this is replaced by
    /// a real `mat4 joint = ...` kernel reading glTF skeleton data.
    fn simBones(self: *System, bone_count: u32, phase: f32) void {
        var ax: f32 = 1.0;
        var az: f32 = 0.0;
        var i: u32 = 0;
        while (i < bone_count) : (i += 1) {
            const angle = phase + @as(f32, @floatFromInt(i)) * 0.3 + self.elapsed;
            const c = @cos(angle);
            const s = @sin(angle);
            const nx = ax * c - az * s;
            const nz = ax * s + az * c;
            ax = nx;
            az = nz;
        }
        // Keep the accumulator observable so the optimizer can't
        // discard the work.
        sink.value = ax + az;
    }
};

/// Volatile sink so simBones' accumulator can't be dead-stripped.
/// File-scope so all callers share the same observable target.
var sink: struct { value: f32 = 0 } = .{};

test "animLodSelect bucketing" {
    try std.testing.expect(animLodSelect(0, 30, 100) == .near);
    try std.testing.expect(animLodSelect(29.9, 30, 100) == .near);
    try std.testing.expect(animLodSelect(30, 30, 100) == .near);
    try std.testing.expect(animLodSelect(30.1, 30, 100) == .mid);
    try std.testing.expect(animLodSelect(99.9, 30, 100) == .mid);
    try std.testing.expect(animLodSelect(100, 30, 100) == .mid);
    try std.testing.expect(animLodSelect(100.1, 30, 100) == .far);
    try std.testing.expect(animLodSelect(1000, 30, 100) == .far);
}
