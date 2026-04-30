//! cell-mgr-harness — synthetic delta + subscriber publisher.
//!
//! M6.3 has no spatial-index yet, so cell-mgr's gate is verified by
//! pumping a deterministic mix of enter/exit/subscribe/unsubscribe
//! messages and watching cell-mgr's per-tick log line track our
//! script. Also doubles as a manual debug tool — `--scenario static`
//! leaves cell-mgr with a stable population so you can inspect its
//! state with `nats sub` etc.
//!
//! The subjects are formatted to match cell-mgr's:
//!   idx.spatial.cell.<x>_<y>.delta
//!   cm.cell.<x>_<y>.subscribe
//!   cm.cell.<x>_<y>.unsubscribe

const std = @import("std");
const nats = @import("nats");
const notatlas = @import("notatlas");

const wire = @import("wire");

const Args = struct {
    cell_x: i32 = 0,
    cell_y: i32 = 0,
    nats_url: []const u8 = "nats://127.0.0.1:4222",
    /// `oneshot` = enter, sleep, exit. `static` = enter and hold.
    /// `churn` = random enter/exit. `pose-stream` = enter N entities,
    /// then publish per-entity state msgs at the tier-1 `visual_rate_hz`
    /// from data/tier_distances.yaml (override with `--rate`) with
    /// simple orbital trajectories (exercises cell-mgr's fast-lane
    /// callback relay).
    scenario: Scenario = .oneshot,
    duration_s: u32 = 5,
    /// `pose-stream` only: state-msg publish rate per entity (Hz).
    /// `null` means "use the tier-1 rate from data/tier_distances.yaml"
    /// — the architecturally honest default per docs/02 §9. Override
    /// only for stress scenarios (e.g. demonstrating sub-cell
    /// partitioning need at >spec rates).
    state_rate_hz_override: ?u32 = null,
    /// `pose-stream` only: number of entities to spin around.
    pose_n_entities: u32 = 5,
    /// Path to the tier_distances.yaml file. Lets the harness be run
    /// from anywhere; defaults to the project-root file.
    tier_yaml_path: []const u8 = "data/tier_distances.yaml",
};

const Scenario = enum { oneshot, static, churn, @"pose-stream" };

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var out: Args = .{};
    var have_nats_url = false;
    errdefer if (have_nats_url) allocator.free(out.nats_url);
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--cell")) {
            const v = args.next() orelse return error.MissingArg;
            const us = std.mem.indexOfScalar(u8, v, '_') orelse return error.BadCellArg;
            out.cell_x = try std.fmt.parseInt(i32, v[0..us], 10);
            out.cell_y = try std.fmt.parseInt(i32, v[us + 1 ..], 10);
        } else if (std.mem.eql(u8, a, "--nats")) {
            out.nats_url = try allocator.dupe(u8, args.next() orelse return error.MissingArg);
            have_nats_url = true;
        } else if (std.mem.eql(u8, a, "--scenario")) {
            const v = args.next() orelse return error.MissingArg;
            out.scenario = std.meta.stringToEnum(Scenario, v) orelse return error.BadScenario;
        } else if (std.mem.eql(u8, a, "--duration")) {
            out.duration_s = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--rate")) {
            out.state_rate_hz_override = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--n")) {
            out.pose_n_entities = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--tier-yaml")) {
            out.tier_yaml_path = args.next() orelse return error.MissingArg;
        } else {
            std.debug.print("harness: unknown arg '{s}'\n", .{a});
            return error.BadArg;
        }
    }
    if (!have_nats_url) {
        out.nats_url = try allocator.dupe(u8, out.nats_url);
    }
    return out;
}

const Publisher = struct {
    client: *nats.Client,
    allocator: std.mem.Allocator,
    delta_subj: []const u8,
    sub_subj: []const u8,
    unsub_subj: []const u8,

    fn pubDelta(self: *Publisher, msg: wire.DeltaMsg) !void {
        const buf = try wire.encodeDelta(self.allocator, msg);
        defer self.allocator.free(buf);
        try self.client.publish(self.delta_subj, buf);
    }

    fn pubSubscribe(self: *Publisher, msg: wire.SubscribeMsg) !void {
        const buf = try wire.encodeSubscribe(self.allocator, msg);
        defer self.allocator.free(buf);
        const subj = if (msg.op == .enter) self.sub_subj else self.unsub_subj;
        try self.client.publish(subj, buf);
    }

    fn pubState(self: *Publisher, ent_id: u32, msg: wire.StateMsg) !void {
        var subject_buf: [64]u8 = undefined;
        const subject = try std.fmt.bufPrint(&subject_buf, "sim.entity.{d}.state", .{ent_id});
        const buf = try wire.encodeState(self.allocator, msg);
        defer self.allocator.free(buf);
        try self.client.publish(subject, buf);
    }
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);
    defer allocator.free(args.nats_url);

    // Load tier rates from data — replaces the previously-hardcoded
    // 60 Hz default. Falls back to TierThresholds.default if the
    // YAML can't be opened (e.g. running from outside the project
    // tree); log a warning so the user knows.
    const tier_thresholds = blk: {
        const abs = std.fs.cwd().realpathAlloc(allocator, args.tier_yaml_path) catch {
            std.debug.print("harness: warning — couldn't resolve {s}; using TierThresholds.default rates\n", .{args.tier_yaml_path});
            break :blk notatlas.replication.TierThresholds.default;
        };
        defer allocator.free(abs);
        break :blk notatlas.yaml_loader.loadTierThresholdsFromFile(allocator, abs) catch |err| {
            std.debug.print("harness: warning — failed to load tier YAML ({s}); using defaults\n", .{@errorName(err)});
            break :blk notatlas.replication.TierThresholds.default;
        };
    };

    // Resolve effective state rate. Per docs/02 §9 the tier-1 visual
    // rate is the producer-side default; --rate is an explicit
    // override (stress-test or sub-spec) that warns when it deviates.
    const tier1_rate = tier_thresholds.visual_rate_hz;
    const effective_rate = args.state_rate_hz_override orelse tier1_rate;
    if (args.state_rate_hz_override) |r| {
        if (r > tier1_rate) {
            std.debug.print("harness: warning — --rate {d} exceeds tier-1 visual_rate_hz {d} (above-spec stress mode)\n", .{ r, tier1_rate });
        } else if (r < tier1_rate) {
            std.debug.print("harness: --rate {d} is below tier-1 visual_rate_hz {d}\n", .{ r, tier1_rate });
        }
    }

    const delta_subj = try std.fmt.allocPrint(allocator, "idx.spatial.cell.{d}_{d}.delta", .{ args.cell_x, args.cell_y });
    defer allocator.free(delta_subj);
    const sub_subj = try std.fmt.allocPrint(allocator, "cm.cell.{d}_{d}.subscribe", .{ args.cell_x, args.cell_y });
    defer allocator.free(sub_subj);
    const unsub_subj = try std.fmt.allocPrint(allocator, "cm.cell.{d}_{d}.unsubscribe", .{ args.cell_x, args.cell_y });
    defer allocator.free(unsub_subj);

    std.debug.print("harness: connecting to {s}; tier-1 rate {d} Hz\n", .{ args.nats_url, effective_rate });
    var client = try nats.Client.connect(allocator, .{
        .servers = &.{args.nats_url},
        .name = "cell-mgr-harness",
    });
    defer client.close();

    var pubr: Publisher = .{
        .client = client,
        .allocator = allocator,
        .delta_subj = delta_subj,
        .sub_subj = sub_subj,
        .unsub_subj = unsub_subj,
    };

    switch (args.scenario) {
        .oneshot => try runOneshot(&pubr),
        .static => try runStatic(&pubr, args.duration_s),
        .churn => try runChurn(&pubr, args.duration_s),
        .@"pose-stream" => try runPoseStream(&pubr, args.duration_s, args.pose_n_entities, effective_rate),
    }

    // Give the connection a moment to flush before close().
    std.Thread.sleep(100 * std.time.ns_per_ms);
    std.debug.print("harness: done\n", .{});
}

// --- scenarios ---

fn runOneshot(p: *Publisher) !void {
    std.debug.print("harness: oneshot — enter 3 entities, 2 subscribers, sleep 2s, exit all\n", .{});
    try p.pubDelta(.{ .op = .enter, .id = 1, .generation = 0, .x = 100, .y = 0, .z = 100 });
    try p.pubDelta(.{ .op = .enter, .id = 2, .generation = 0, .x = 200, .y = 0, .z = 200 });
    try p.pubDelta(.{ .op = .enter, .id = 3, .generation = 0, .x = -100, .y = 0, .z = 50 });
    try p.pubSubscribe(.{ .op = .enter, .client_id = 0xAA, .x = 0, .y = 0, .z = 0 });
    try p.pubSubscribe(.{ .op = .enter, .client_id = 0xBB, .x = 50, .y = 0, .z = 50 });

    std.Thread.sleep(2 * std.time.ns_per_s);

    try p.pubDelta(.{ .op = .exit, .id = 1, .generation = 0, .x = 0, .y = 0, .z = 0 });
    try p.pubDelta(.{ .op = .exit, .id = 2, .generation = 0, .x = 0, .y = 0, .z = 0 });
    try p.pubSubscribe(.{ .op = .exit, .client_id = 0xAA, .x = 0, .y = 0, .z = 0 });
}

fn runStatic(p: *Publisher, duration_s: u32) !void {
    std.debug.print("harness: static — enter 5 entities + 3 subscribers, hold for {d}s\n", .{duration_s});
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        try p.pubDelta(.{
            .op = .enter,
            .id = i + 1,
            .generation = 0,
            .x = @as(f32, @floatFromInt(i)) * 100,
            .y = 0,
            .z = 0,
        });
    }
    var s: u32 = 0;
    while (s < 3) : (s += 1) {
        try p.pubSubscribe(.{
            .op = .enter,
            .client_id = 0x100 + s,
            .x = @as(f32, @floatFromInt(s)) * 50,
            .y = 0,
            .z = 0,
        });
    }
    std.Thread.sleep(@as(u64, duration_s) * std.time.ns_per_s);
}

fn runPoseStream(p: *Publisher, duration_s: u32, n_ents: u32, rate_hz: u32) !void {
    std.debug.print("harness: pose-stream — {d} entities orbiting, {d} Hz state msgs each, for {d}s\n", .{ n_ents, rate_hz, duration_s });

    // Enter each entity at a unique starting position, plus one
    // subscriber at the origin so we can watch the relay fire.
    var i: u32 = 0;
    while (i < n_ents) : (i += 1) {
        const phase: f32 = @as(f32, @floatFromInt(i)) * (2.0 * std.math.pi / @as(f32, @floatFromInt(n_ents)));
        const r = 100.0 + @as(f32, @floatFromInt(i)) * 30.0;
        try p.pubDelta(.{
            .op = .enter,
            .id = i + 1,
            .generation = 0,
            .x = r * @cos(phase),
            .y = 0,
            .z = r * @sin(phase),
        });
    }
    try p.pubSubscribe(.{ .op = .enter, .client_id = 0xCAFE, .x = 0, .y = 0, .z = 0 });

    // Tight loop: every entity gets `rate_hz` state updates / second.
    const tick_ns: u64 = std.time.ns_per_s / @as(u64, rate_hz);
    const start_ns: u64 = @intCast(std.time.nanoTimestamp());
    const end_ns = start_ns + @as(u64, duration_s) * std.time.ns_per_s;
    var next_tick_ns = start_ns + tick_ns;

    var msgs_sent: u64 = 0;
    var t_phase: f32 = 0;
    while (@as(u64, @intCast(std.time.nanoTimestamp())) < end_ns) {
        // Each entity moves on its own circular orbit, separated by
        // phase + radius. Speed is enough to put visible motion in
        // the per-tick samples without exceeding the codec's ±50 m/s
        // velocity range.
        var j: u32 = 0;
        while (j < n_ents) : (j += 1) {
            const base_phase: f32 = @as(f32, @floatFromInt(j)) * (2.0 * std.math.pi / @as(f32, @floatFromInt(n_ents)));
            const r = 100.0 + @as(f32, @floatFromInt(j)) * 30.0;
            const angle = base_phase + t_phase;
            const x = r * @cos(angle);
            const z = r * @sin(angle);
            try p.pubState(j + 1, .{
                .generation = 0,
                .x = x,
                .y = 0,
                .z = z,
                .heading_rad = angle + std.math.pi / 2.0, // tangent
                .vx = -r * @sin(angle),
                .vy = 0,
                .vz = r * @cos(angle),
            });
            msgs_sent += 1;
        }
        t_phase += 0.1; // ~16°/tick at 60 Hz = ~6 sec per orbit

        // Sleep until the next tick boundary. Skip if we're already
        // late (loop body grew past one period — happens when N or
        // rate is high enough that publishing alone exceeds the
        // budget; behavior matches the production "best-effort 60 Hz"
        // model).
        const now_ns: u64 = @intCast(std.time.nanoTimestamp());
        if (next_tick_ns > now_ns) std.Thread.sleep(next_tick_ns - now_ns);
        next_tick_ns += tick_ns;
    }

    std.debug.print("harness: pose-stream sent {d} state msgs over {d}s\n", .{ msgs_sent, duration_s });

    // Tear down — exit all entities and the subscriber.
    var k: u32 = 0;
    while (k < n_ents) : (k += 1) {
        try p.pubDelta(.{ .op = .exit, .id = k + 1, .generation = 0, .x = 0, .y = 0, .z = 0 });
    }
    try p.pubSubscribe(.{ .op = .exit, .client_id = 0xCAFE, .x = 0, .y = 0, .z = 0 });
}

fn runChurn(p: *Publisher, duration_s: u32) !void {
    std.debug.print("harness: churn — random enters/exits for {d}s\n", .{duration_s});
    var rng = std.Random.DefaultPrng.init(0xC0FFEE);
    const r = rng.random();

    var present: std.AutoHashMap(u32, void) = .init(p.allocator);
    defer present.deinit();

    const start_ns: u64 = @intCast(std.time.nanoTimestamp());
    const end_ns = start_ns + @as(u64, duration_s) * std.time.ns_per_s;

    while (@as(u64, @intCast(std.time.nanoTimestamp())) < end_ns) {
        const id = r.intRangeAtMost(u32, 1, 20);
        if (present.contains(id)) {
            try p.pubDelta(.{ .op = .exit, .id = id, .generation = 0, .x = 0, .y = 0, .z = 0 });
            _ = present.remove(id);
        } else {
            try p.pubDelta(.{
                .op = .enter,
                .id = id,
                .generation = 0,
                .x = (r.float(f32) - 0.5) * 1000,
                .y = 0,
                .z = (r.float(f32) - 0.5) * 1000,
            });
            try present.put(id, {});
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}
