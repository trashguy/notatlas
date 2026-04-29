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

const wire = @import("wire");

const Args = struct {
    cell_x: i32 = 0,
    cell_y: i32 = 0,
    nats_url: []const u8 = "nats://127.0.0.1:4222",
    /// "static" = enter 5 entities + 3 subscribers and stay; "churn" =
    /// repeated enter/exit with random ids; "oneshot" = enter, sleep,
    /// exit, exit. Default is "oneshot".
    scenario: Scenario = .oneshot,
    duration_s: u32 = 5,
};

const Scenario = enum { oneshot, static, churn };

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
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);
    defer allocator.free(args.nats_url);

    const delta_subj = try std.fmt.allocPrint(allocator, "idx.spatial.cell.{d}_{d}.delta", .{ args.cell_x, args.cell_y });
    defer allocator.free(delta_subj);
    const sub_subj = try std.fmt.allocPrint(allocator, "cm.cell.{d}_{d}.subscribe", .{ args.cell_x, args.cell_y });
    defer allocator.free(sub_subj);
    const unsub_subj = try std.fmt.allocPrint(allocator, "cm.cell.{d}_{d}.unsubscribe", .{ args.cell_x, args.cell_y });
    defer allocator.free(unsub_subj);

    std.debug.print("harness: connecting to {s}\n", .{args.nats_url});
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
