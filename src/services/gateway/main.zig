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
//! Sub-step 2 scope: TCP listener + single-client byte pipe.
//! Accept one TCP connection at a time on `--listen-port` (default
//! 9000); on each inbound NATS payload, write a 4 B little-endian
//! length prefix followed by the raw payload bytes to the socket.
//! On second accept, close the existing conn and adopt the new one.
//! Closes the producer → client visible chain end-to-end — the
//! cell-mgr's authoritative fanout now lands as readable bytes on
//! a TCP socket a real client (or `nc`) can demux.
//!
//! Why length-prefix and not raw concat: TCP is a byte stream, NATS
//! payloads are discrete; without explicit boundaries the receiver
//! can't tell where one PayloadHeader+records block ends and the
//! next begins. 4 B le length is the de facto framing for binary
//! game-server pipes and stays self-evident on the wire.
//!
//! Subsequent sub-steps:
//!   3. Outbound TCP-frame → `sim.entity.<player_id>.input` publish.
//!   4. JWT validation + session lifecycle.
//!   5. Multi-client (N concurrent connections, per-conn NATS
//!      subscription + per-conn input publisher).
//!   6. Per-tier dynamic subscription set per docs/08 §1.2.
//!
//! Per docs/08 §8.3 gateway is the lift-with-reshape from
//! fallen-runes' gateway. Until the reshape is mechanical (TCP
//! framing + JWT pieces lift mostly intact), keep this binary
//! thin. The interest filter and per-tier composition live at
//! cell-mgr (docs/08 §8 decision 3), not here — this service is
//! just the byte pipe.

const std = @import("std");
const nats = @import("nats");
const notatlas = @import("notatlas");
const posix = std.posix;

/// Per-payload header for slow-lane and fast-lane batches.
/// Mirrors `cell_mgr/fanout.zig:PayloadHeader`. When a real
/// `src/shared/fanout_wire.zig` lands, replace this local copy
/// with an import.
const PayloadHeader = extern struct {
    entity_count: u32,
    cluster_count: u32,
};

const default_listen_port: u16 = 9000;

const Args = struct {
    /// Hardcoded client_id for the skeleton — the gateway
    /// subscribes to `gw.client.<this>.cmd`. Multi-client lands
    /// in sub-step 5.
    client_id: u64 = 1,
    /// TCP listen port. Bound to 127.0.0.1 only — gateway is
    /// loopback-only until JWT lands (sub-step 4) and the service
    /// is safe to expose externally.
    listen_port: u16 = default_listen_port,
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
        } else if (std.mem.eql(u8, a, "--listen-port")) {
            out.listen_port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingArg, 10);
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
    const act: posix.Sigaction = .{
        .handler = .{ .handler = &handleSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
    // SIGPIPE on a closed socket would otherwise terminate the
    // process; we already check write errors and close the conn.
    const ignore_pipe: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &ignore_pipe, null);
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

    // Bind the TCP listener BEFORE the NATS connect so a port-in-use
    // error fails fast without leaving a dangling NATS subscription.
    const listen_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, args.listen_port);
    var server = try listen_addr.listen(.{
        .reuse_address = true,
        .force_nonblocking = true,
    });
    defer server.deinit();
    std.debug.print("gateway: listening on 127.0.0.1:{d}\n", .{args.listen_port});

    std.debug.print("gateway: connecting to {s}; client_id={d}\n", .{ args.nats_url, args.client_id });

    var client = try nats.Client.connect(allocator, .{
        .servers = &.{args.nats_url},
        .name = "gateway",
    });
    defer client.close();

    const sub_cmd = try client.subscribe(cmd_subj, .{});
    std.debug.print("gateway: subscribed to {s}\n", .{cmd_subj});

    var conn: ?std.net.Server.Connection = null;
    defer if (conn) |c| c.stream.close();

    var msgs_total: u64 = 0;
    var ents_total: u64 = 0;
    var clusters_total: u64 = 0;
    var bytes_total: u64 = 0;
    var bytes_tcp_total: u64 = 0;
    var last_log_ns: u64 = @intCast(std.time.nanoTimestamp());

    while (g_running.load(.acquire)) {
        try client.processIncomingTimeout(5);
        try client.maybeSendPing();

        // Non-blocking accept. If something's pending, replace the
        // existing connection — single-client policy for sub-step 2.
        if (server.accept()) |new_conn| {
            if (conn) |old| {
                std.debug.print("gateway: replacing existing TCP conn {f} with {f}\n", .{ old.address, new_conn.address });
                old.stream.close();
            } else {
                std.debug.print("gateway: TCP client connected from {f}\n", .{new_conn.address});
            }
            conn = new_conn;
        } else |err| switch (err) {
            error.WouldBlock => {},
            else => return err,
        }

        while (sub_cmd.nextMsg()) |msg| {
            var owned = msg;
            defer owned.deinit();
            const payload = owned.payload orelse continue;
            msgs_total += 1;
            bytes_total += payload.len;
            const header = decodeHeader(payload);
            ents_total += header.entity_count;
            clusters_total += header.cluster_count;

            if (conn) |c| {
                const n = forwardFrame(c.stream, payload) catch |err| blk: {
                    std.debug.print("gateway: TCP write failed ({s}); closing conn\n", .{@errorName(err)});
                    c.stream.close();
                    conn = null;
                    break :blk 0;
                };
                bytes_tcp_total += n;
            }
        }

        const now_ns: u64 = @intCast(std.time.nanoTimestamp());
        if (now_ns -% last_log_ns >= std.time.ns_per_s) {
            const tcp_status: []const u8 = if (conn != null) "TCP up" else "TCP idle";
            std.debug.print(
                "[gateway client={d}] {d} msgs / {d} ents / {d} clusters / {d} B in / {d} B out ({s}) last 1 s\n",
                .{
                    args.client_id, msgs_total,     ents_total, clusters_total,
                    bytes_total,    bytes_tcp_total, tcp_status,
                },
            );
            msgs_total = 0;
            ents_total = 0;
            clusters_total = 0;
            bytes_total = 0;
            bytes_tcp_total = 0;
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

/// Write `[u32_le len][payload]` to the connected client. Returns
/// total bytes written (frame header included). Writes are blocking
/// for sub-step 2; if the client's recv buffer fills the loop pauses
/// until it drains. `nc` and other localhost clients drain instantly,
/// so this is fine for the skeleton; real backpressure handling is
/// future work (sub-step 4+ alongside JWT / multi-client).
fn forwardFrame(stream: std.net.Stream, payload: []const u8) !usize {
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload.len), .little);
    try stream.writeAll(&header);
    try stream.writeAll(payload);
    return header.len + payload.len;
}
