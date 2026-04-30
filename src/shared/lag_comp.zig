//! Lag compensation rewind buffer — M9.
//!
//! Per replicated hitbox entity (player capsule, ship hull) the
//! owner appends a `(sim_time_s, pose)` snapshot every tick. On
//! hit-query the buffer rewinds to the shooter's reported view
//! time and returns the snapshot; the **caller** runs their own
//! hit-detection routine (ray-vs-capsule, ray-vs-AABB, etc.)
//! against that pose. Decoupling rewind from hit-test keeps this
//! module pure — no I/O, no geometry math, no entity types — and
//! lets each hitbox kind use the geometry it cares about.
//!
//! Rewind window is capped at ~250 ms (configurable) to prevent
//! "shot around corners" — old shots whose view-time is too far
//! back get rejected so the server never validates against state
//! the shooter couldn't physically have seen given network
//! plausibility.
//!
//! Ring buffer size is comptime-parameterized. At 60 Hz × 250 ms
//! the active window is 15 entries; capacity 32 leaves slack for
//! catch-up ticks (M5.1 spiral) and for callers who want a longer
//! window (e.g. cannons with traveling projectiles need lookups
//! older than 250 ms once M8 fire events land in flight).
//!
//! Per docs/03 §9: the M9 synthetic gate is "two clients with
//! simulated 50 ms / 200 ms ping; both shoot moving targets; hit
//! reg accurate to client view." With the buffer + caller-side
//! hit-test, the gate decomposes to "rewindTo at the shooter's
//! view time returns the pose within one-tick precision of where
//! the target actually was at view_time." That's what's verified
//! below.

const std = @import("std");

pub const Snapshot = struct {
    sim_time_s: f64,
    pos: [3]f32,
    /// Unit quaternion (x, y, z, w). Rotational hitboxes
    /// (capsules, swept volumes) need this; spherical ones can
    /// ignore it.
    rot: [4]f32 = .{ 0, 0, 0, 1 },
};

/// Default rewind cap. 250 ms matches docs/03 §9 / docs/02 §9 — the
/// "shot around corners" mitigation upper bound. Anything beyond
/// this is implausible network latency; reject rather than reach
/// further back into history.
pub const default_max_window_s: f64 = 0.25;

/// Why a `rewindTo` call returned null. Useful for telemetry +
/// debugging hit-reg quirks; production callers can ignore the
/// distinction and treat all four as "no hit."
pub const RewindReason = enum {
    /// Buffer hasn't accumulated any snapshots yet.
    empty_buffer,
    /// view_time_s is more than `max_window_s` before now_s.
    /// "Shot around corners" mitigation cap.
    beyond_window_cap,
    /// view_time_s is older than the oldest snapshot the buffer
    /// retains. Different from `beyond_window_cap`: the cap may
    /// allow it, but the buffer simply hasn't been around long
    /// enough.
    older_than_oldest,
    /// view_time_s is in the future (after now_s). Caller bug or
    /// adversarial input.
    in_future,
};

pub const RewindResult = union(enum) {
    snapshot: Snapshot,
    miss: RewindReason,
};

/// Ring buffer of past poses. `capacity` is comptime so the
/// underlying storage is a fixed-size array — no allocator needed.
pub fn Buffer(comptime capacity: u32) type {
    if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
        @compileError("Buffer capacity must be a power of two > 0");
    }
    return struct {
        const Self = @This();
        const mask: u32 = capacity - 1;

        snapshots: [capacity]Snapshot,
        /// Index of the next-write slot. Newest snapshot is at
        /// `(head - 1) & mask`.
        head: u32,
        /// Valid snapshots in the buffer, ≤ capacity.
        count: u32,
        /// Rewind cap in seconds — view_times older than `now_s -
        /// max_window_s` get rejected as "shot around corners."
        max_window_s: f64,

        pub fn init(max_window_s: f64) Self {
            return .{
                .snapshots = undefined,
                .head = 0,
                .count = 0,
                .max_window_s = max_window_s,
            };
        }

        /// Append a new snapshot. Caller is responsible for
        /// monotonic `sim_time_s` — the rewind walk relies on
        /// the order being newest-to-oldest.
        pub fn append(self: *Self, snap: Snapshot) void {
            self.snapshots[self.head] = snap;
            self.head = (self.head + 1) & mask;
            if (self.count < capacity) self.count += 1;
        }

        /// Rewind to the snapshot nearest `view_time_s`. Returns
        /// the snapshot wrapped in RewindResult, or a miss with
        /// the reason. Reasons are observable for telemetry; map
        /// them to "no hit" wholesale at the production caller.
        pub fn rewindTo(self: *const Self, view_time_s: f64, now_s: f64) RewindResult {
            if (self.count == 0) return .{ .miss = .empty_buffer };
            if (view_time_s > now_s) return .{ .miss = .in_future };
            if (now_s - view_time_s > self.max_window_s) return .{ .miss = .beyond_window_cap };

            // Walk newest-to-oldest until we find a sim_time_s ≤
            // view_time_s. Linear scan; capacity is small (≤32) so
            // the constant factor beats binary search's branching.
            var i: u32 = 0;
            while (i < self.count) : (i += 1) {
                const idx = (self.head + capacity - 1 - i) & mask;
                const s = self.snapshots[idx];
                if (s.sim_time_s <= view_time_s) {
                    if (i == 0) return .{ .snapshot = s };
                    // The next-newer snapshot was the previous
                    // iteration. Choose whichever is nearer.
                    const newer_idx = (self.head + capacity - 1 - (i - 1)) & mask;
                    const newer = self.snapshots[newer_idx];
                    const d_old = view_time_s - s.sim_time_s;
                    const d_new = newer.sim_time_s - view_time_s;
                    return .{ .snapshot = if (d_old < d_new) s else newer };
                }
            }
            return .{ .miss = .older_than_oldest };
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }

        pub fn snapshotCount(self: *const Self) u32 {
            return self.count;
        }
    };
}

// ---- tests ----

const testing = std.testing;
const TestBuf = Buffer(32);

test "lag_comp: empty buffer returns empty_buffer miss" {
    var b = TestBuf.init(default_max_window_s);
    const r = b.rewindTo(0.5, 1.0);
    try testing.expectEqual(RewindResult{ .miss = .empty_buffer }, r);
}

test "lag_comp: append + rewindTo exact match" {
    var b = TestBuf.init(default_max_window_s);
    b.append(.{ .sim_time_s = 1.0, .pos = .{ 1, 0, 0 } });
    b.append(.{ .sim_time_s = 1.1, .pos = .{ 2, 0, 0 } });
    const r = b.rewindTo(1.1, 1.2);
    switch (r) {
        .snapshot => |s| {
            try testing.expectEqual(@as(f64, 1.1), s.sim_time_s);
            try testing.expectEqual(@as(f32, 2), s.pos[0]);
        },
        .miss => return error.UnexpectedMiss,
    }
}

test "lag_comp: rewindTo between snapshots picks nearer one" {
    var b = TestBuf.init(default_max_window_s);
    b.append(.{ .sim_time_s = 1.00, .pos = .{ 0, 0, 0 } });
    b.append(.{ .sim_time_s = 1.10, .pos = .{ 10, 0, 0 } });
    b.append(.{ .sim_time_s = 1.20, .pos = .{ 20, 0, 0 } });

    // 1.13 is closer to 1.10 than 1.20 — distance 0.03 vs 0.07.
    const r = b.rewindTo(1.13, 1.21);
    switch (r) {
        .snapshot => |s| try testing.expectEqual(@as(f32, 10), s.pos[0]),
        .miss => return error.UnexpectedMiss,
    }
    // 1.18 is closer to 1.20 — distance 0.02 vs 0.08.
    const r2 = b.rewindTo(1.18, 1.21);
    switch (r2) {
        .snapshot => |s| try testing.expectEqual(@as(f32, 20), s.pos[0]),
        .miss => return error.UnexpectedMiss,
    }
}

test "lag_comp: rewindTo beyond max_window returns beyond_window_cap" {
    var b = TestBuf.init(0.25);
    b.append(.{ .sim_time_s = 1.0, .pos = .{ 0, 0, 0 } });
    b.append(.{ .sim_time_s = 1.5, .pos = .{ 0, 0, 0 } });
    // view_time 0.5 s, now 2.0 s → gap 1.5 s > 0.25 s cap.
    const r = b.rewindTo(0.5, 2.0);
    try testing.expectEqual(RewindResult{ .miss = .beyond_window_cap }, r);
}

test "lag_comp: rewindTo older than oldest snapshot" {
    var b = TestBuf.init(10.0); // wide cap so cap doesn't fire
    b.append(.{ .sim_time_s = 1.0, .pos = .{ 0, 0, 0 } });
    b.append(.{ .sim_time_s = 2.0, .pos = .{ 0, 0, 0 } });
    const r = b.rewindTo(0.5, 2.5);
    try testing.expectEqual(RewindResult{ .miss = .older_than_oldest }, r);
}

test "lag_comp: rewindTo in future returns in_future" {
    var b = TestBuf.init(default_max_window_s);
    b.append(.{ .sim_time_s = 1.0, .pos = .{ 0, 0, 0 } });
    const r = b.rewindTo(2.0, 1.5);
    try testing.expectEqual(RewindResult{ .miss = .in_future }, r);
}

test "lag_comp: ring buffer wraps after capacity exceeded" {
    var b = TestBuf.init(10.0);
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        b.append(.{
            .sim_time_s = @as(f64, @floatFromInt(i)) * 0.01,
            .pos = .{ @as(f32, @floatFromInt(i)), 0, 0 },
        });
    }
    try testing.expectEqual(@as(u32, 32), b.snapshotCount());
    // Newest is i=49 at t=0.49.
    const r_newest = b.rewindTo(0.49, 0.50);
    switch (r_newest) {
        .snapshot => |s| try testing.expectEqual(@as(f32, 49), s.pos[0]),
        .miss => return error.UnexpectedMiss,
    }
    // i=17 at t=0.17 should now be older than the buffer's oldest
    // (capacity 32 retains i=18..49 → t=0.18..0.49).
    const r_old = b.rewindTo(0.17, 0.50);
    try testing.expectEqual(RewindResult{ .miss = .older_than_oldest }, r_old);
}

// ---- M9 GATE ----

test "M9 gate: 60 Hz target, two shooters at 50 ms / 200 ms ping, rewind matches view" {
    // Simulate a single target moving along +x at 5 m/s, 60 Hz
    // tick. Two shooters with simulated latencies 50 ms and 200 ms.
    // Each shooter "fires" at its rendered view of the target —
    // i.e. at the target's position 50 ms or 200 ms ago. The
    // server validates by rewinding to the shooter's view_time;
    // the rewound snapshot must match the target's actual past
    // position to within one-tick precision (1/60 s × 5 m/s ≈
    // 8.3 cm). That is the docs/03 §9 "hit reg accurate to client
    // view" property.

    var buf = TestBuf.init(default_max_window_s);

    const tick_hz: f64 = 60.0;
    const dt: f64 = 1.0 / tick_hz;
    const target_v_x_mps: f32 = 5.0;
    const total_ticks: u32 = 60; // 1 s of simulation

    var t_idx: u32 = 0;
    while (t_idx < total_ticks) : (t_idx += 1) {
        const sim_t: f64 = @as(f64, @floatFromInt(t_idx)) * dt;
        const x: f32 = target_v_x_mps * @as(f32, @floatCast(sim_t));
        buf.append(.{ .sim_time_s = sim_t, .pos = .{ x, 0, 0 } });
    }

    const now_s: f64 = @as(f64, @floatFromInt(total_ticks - 1)) * dt;

    // 50 ms ping: fire at where shooter sees target now (which is
    // target's true position 50 ms ago).
    const shooter_a_lat: f64 = 0.050;
    const view_a: f64 = now_s - shooter_a_lat;
    const expected_x_a: f32 = target_v_x_mps * @as(f32, @floatCast(view_a));
    const r_a = buf.rewindTo(view_a, now_s);
    switch (r_a) {
        .snapshot => |s| {
            const err = @abs(s.pos[0] - expected_x_a);
            // One-tick precision = (1/60) × 5 m/s ≈ 8.33 cm.
            try testing.expect(err <= 0.09);
        },
        .miss => return error.UnexpectedMissA,
    }

    // 200 ms ping: same deal, deeper into the buffer.
    const shooter_b_lat: f64 = 0.200;
    const view_b: f64 = now_s - shooter_b_lat;
    const expected_x_b: f32 = target_v_x_mps * @as(f32, @floatCast(view_b));
    const r_b = buf.rewindTo(view_b, now_s);
    switch (r_b) {
        .snapshot => |s| {
            const err = @abs(s.pos[0] - expected_x_b);
            try testing.expect(err <= 0.09);
        },
        .miss => return error.UnexpectedMissB,
    }

    // 300 ms ping exceeds the 250 ms cap — gets rejected ("shot
    // around corners" mitigation).
    const view_c: f64 = now_s - 0.300;
    const r_c = buf.rewindTo(view_c, now_s);
    try testing.expectEqual(RewindResult{ .miss = .beyond_window_cap }, r_c);

    std.debug.print("\n[M9] gate: 60 Hz buffer, 50/200 ms ping rewind precision <= 1-tick (8.3 cm @ 5 m/s); 300 ms ping correctly capped\n", .{});
}
