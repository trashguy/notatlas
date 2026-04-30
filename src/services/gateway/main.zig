//! gateway — TCP ↔ NATS relay per docs/08 §1.2.
//!
//! Stateless client-facing service that bridges TCP-connected
//! clients into the NATS service mesh. Per-client this means:
//!   - **inbound** (NATS → TCP): subscribe to `gw.client.<id>.cmd`
//!     (cell-mgr's per-client fanout subject) and forward every
//!     batched payload to the client's socket
//!   - **outbound** (TCP → NATS): read framed input messages from
//!     the client's socket and publish to
//!     `sim.entity.<player_id>.input`
//!
//! Skeleton scope (this commit): NATS connect, subscribe to one
//! hardcoded client_id's cmd subject, **decode + log** every
//! inbound batched payload (PayloadHeader + records). Demonstrates
//! the consumer end of the cell-mgr → gateway link without yet
//! introducing TCP. With cell-mgr + ship-sim + this gateway
//! running, you can watch a real authoritative ship's pose stream
//! flow all the way from physics tick → cell-mgr fast-lane →
//! gateway in JSON-readable form.
//!
//! Subsequent sub-steps add (in order):
//!   2. TCP listener, single-client accept loop, raw byte forward
//!      of inbound NATS payloads to the socket.
//!   3. Outbound TCP-frame → `sim.entity.<player_id>.input`
//!      publish path.
//!   4. JWT validation + session lifecycle (auth handshake before
//!      any forwarding).
//!   5. Multi-client (N concurrent connections, per-conn NATS
//!      subscription + per-conn input publisher).
//!   6. Per-tier dynamic subscription set per docs/08 §1.2 (for
//!      the four tier subjects beyond just `cmd` — once those
//!      land in the wire shape).
//!
//! Per docs/08 §8.3 gateway is the lift-with-reshape from
//! fallen-runes' `src/services/gateway/service.zig`. Until the
//! reshape is mechanical (TCP framing + JWT pieces lift mostly
//! intact), keep this binary thin. The interest filter and
//! per-tier composition live at cell-mgr (docs/08 §8 decision 3),
//! not here — this service is just the byte pipe.

const std = @import("std");
const nats = @import("nats");
const notatlas = @import("notatlas");

/// Per-payload header for slow-lane and fast-lane batches.
/// Mirrors `cell_mgr/fanout.zig:PayloadHeader`. When a real
/// `src/shared/fanout_wire.zig` lands, replace this local copy
/// with an import.
const PayloadHeader = extern struct {
    entity_count: u32,
    cluster_count: u32,
};

const Args = struct {
    /// Hardcoded client_id for the skeleton — the gateway
    /// subscribes to `gw.client.<this>.cmd`. Multi-client lands
    /// in sub-step 5.
    client_id: u64 = 1,
    nats_url: []const u8 = "nats://127.0.0.1:4222",
};

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var out: Args = .{};
    var have_nats_url = false;
    errdefer if (have_nats_url) allocator.free(out.nats_url);
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--nats")) {
            const v = args.next() orelse return error.MissingArg;
            out.nats_url = try allocator.dupe(u8, v);
            have_nats_url = true;
        } else if (std.mem.eql(u8, a, "--client-id")) {
            out.client_id = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArg, 10);
        } else {
            std.debug.print("gateway: unknown arg '{s}'\n", .{a});
            return error.BadArg;
        }
    }
    if (!have_nats_url) out.nats_url = try allocator.dupe(u8, out.nats_url);
    return out;
}

var g_running: std.atomic.Value(bool) = .init(true);

fn handleSignal(_: c_int) callconv(.c) void {
    g_running.store(false, .release);
}

fn installSignalHandlers() !void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = &handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);
    defer allocator.free(args.nats_url);
    try installSignalHandlers();

    const cmd_subj = try std.fmt.allocPrint(allocator, "gw.client.{d}.cmd", .{args.client_id});
    defer allocator.free(cmd_subj);

    std.debug.print("gateway: connecting to {s}; client_id={d}\n", .{ args.nats_url, args.client_id });

    var client = try nats.Client.connect(allocator, .{
        .servers = &.{args.nats_url},
        .name = "gateway",
    });
    defer client.close();

    const sub_cmd = try client.subscribe(cmd_subj, .{});
    std.debug.print("gateway: subscribed to {s}\n", .{cmd_subj});

    var msgs_total: u64 = 0;
    var ents_total: u64 = 0;
    var clusters_total: u64 = 0;
    var bytes_total: u64 = 0;
    var last_log_ns: u64 = @intCast(std.time.nanoTimestamp());

    while (g_running.load(.acquire)) {
        try client.processIncomingTimeout(5);
        try client.maybeSendPing();

        while (sub_cmd.nextMsg()) |msg| {
            var owned = msg;
            defer owned.deinit();
            const payload = owned.payload orelse continue;
            handlePayload(payload);
            msgs_total += 1;
            bytes_total += payload.len;
            const header = decodeHeader(payload);
            ents_total += header.entity_count;
            clusters_total += header.cluster_count;
        }

        const now_ns: u64 = @intCast(std.time.nanoTimestamp());
        if (now_ns -% last_log_ns >= std.time.ns_per_s) {
            std.debug.print("[gateway client={d}] {d} msgs / {d} ents / {d} clusters / {d} B in last 1 s\n", .{
                args.client_id, msgs_total, ents_total, clusters_total, bytes_total,
            });
            msgs_total = 0;
            ents_total = 0;
            clusters_total = 0;
            bytes_total = 0;
            last_log_ns = now_ns;
        }
    }

    std.debug.print("gateway: shutting down\n", .{});
}

/// Decode the `PayloadHeader` from the leading 8 B of a fanout
/// payload (slow-lane or fast-lane — both share the same shape).
fn decodeHeader(payload: []const u8) PayloadHeader {
    if (payload.len < @sizeOf(PayloadHeader)) return .{ .entity_count = 0, .cluster_count = 0 };
    return std.mem.bytesToValue(PayloadHeader, payload[0..@sizeOf(PayloadHeader)]);
}

/// Per-payload handler. Skeleton: counts only — bytes get tallied
/// in the caller for the per-second summary line. Real client
/// forwarding (TCP write to the connected socket) replaces this
/// no-op in sub-step 2.
fn handlePayload(_: []const u8) void {}
