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
//! Sub-step 3 scope: bidirectional byte pipe. Inbound was sub-step
//! 2; this adds the symmetric outbound direction. Conn socket is
//! flipped to non-blocking after accept; per-loop iteration reads
//! whatever bytes are pending into a 64 KB conn buffer, then drains
//! complete length-prefixed frames out of the buffer one at a time
//! and publishes each frame's payload bytes to
//! `sim.entity.<--player-id>.input`. Pure passthrough — gateway
//! never inspects payload bytes; framing is the only contract.
//!
//! Wire framing for both directions: `[u32_le len][raw bytes]`.
//! Why: TCP is a byte stream; NATS payloads are discrete; without
//! explicit boundaries the receiver can't tell where one block ends
//! and the next begins. Symmetric framing keeps client-side
//! demux/mux trivial.
//!
//! Subsequent sub-steps:
//!   4. JWT validation + session lifecycle (auth handshake before
//!      any forwarding). Once JWT carries player_id, the manual
//!      --player-id arg goes away.
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
/// Per-connection inbound buffer. Sized comfortably above any
/// expected single-frame input (player input messages are tiny —
/// this is more than enough for any plausible burst). Frames over
/// `max_frame_bytes` close the conn defensively.
const conn_buf_size: usize = 64 * 1024;
const max_frame_bytes: u32 = 16 * 1024;
const frame_header_bytes: usize = 4;

const Args = struct {
    /// Hardcoded client_id for the skeleton — the gateway
    /// subscribes to `gw.client.<this>.cmd`. Multi-client lands
    /// in sub-step 5.
    client_id: u64 = 1,
    /// Player entity id this client is driving. Outbound TCP
    /// frames are published to `sim.entity.<this>.input`. Once
    /// JWT lands (sub-step 4) the JWT carries player_id and this
    /// arg goes away. For sub-step 3 default to client_id.
    player_id: ?u32 = null,
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
        } else if (std.mem.eql(u8, a, "--player-id")) {
            out.player_id = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArg, 10);
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

/// Set O_NONBLOCK on a connected socket fd. Conn fds returned by
/// `accept()` don't inherit O_NONBLOCK from the listener on Linux —
/// we want non-blocking reads in the main loop, so flip the flag
/// after accept.
fn setNonblocking(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    const nonblock_bit: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | nonblock_bit);
}

/// Per-connection inbound buffer. Append at `len`, drain frames out
/// of the front, compact the tail down to position 0 once a frame
/// is consumed.
const ConnBuf = struct {
    bytes: [conn_buf_size]u8 = undefined,
    len: usize = 0,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);
    defer allocator.free(args.nats_url);
    try installSignalHandlers();

    const player_id = args.player_id orelse @as(u32, @intCast(args.client_id));

    const cmd_subj = try std.fmt.allocPrint(allocator, "gw.client.{d}.cmd", .{args.client_id});
    defer allocator.free(cmd_subj);
    const input_subj = try std.fmt.allocPrint(allocator, "sim.entity.{d}.input", .{player_id});
    defer allocator.free(input_subj);

    // Bind the TCP listener BEFORE the NATS connect so a port-in-use
    // error fails fast without leaving a dangling NATS subscription.
    const listen_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, args.listen_port);
    var server = try listen_addr.listen(.{
        .reuse_address = true,
        .force_nonblocking = true,
    });
    defer server.deinit();
    std.debug.print("gateway: listening on 127.0.0.1:{d}\n", .{args.listen_port});

    std.debug.print("gateway: connecting to {s}; client_id={d} player_id={d}\n", .{ args.nats_url, args.client_id, player_id });

    var client = try nats.Client.connect(allocator, .{
        .servers = &.{args.nats_url},
        .name = "gateway",
    });
    defer client.close();

    const sub_cmd = try client.subscribe(cmd_subj, .{});
    std.debug.print("gateway: subscribed to {s}; outbound publishes to {s}\n", .{ cmd_subj, input_subj });

    var conn: ?std.net.Server.Connection = null;
    var conn_buf: ConnBuf = .{};
    defer if (conn) |c| c.stream.close();

    var msgs_total: u64 = 0;
    var ents_total: u64 = 0;
    var clusters_total: u64 = 0;
    var bytes_total: u64 = 0;
    var bytes_tcp_out_total: u64 = 0;
    var bytes_tcp_in_total: u64 = 0;
    var frames_in_total: u64 = 0;
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
            setNonblocking(new_conn.stream.handle) catch |err| {
                std.debug.print("gateway: setNonblocking failed ({s}); rejecting conn\n", .{@errorName(err)});
                new_conn.stream.close();
                conn = null;
                conn_buf.len = 0;
            };
            conn = new_conn;
            conn_buf.len = 0;
        } else |err| switch (err) {
            error.WouldBlock => {},
            else => return err,
        }

        // TCP → NATS: drain whatever's pending on the conn, parse
        // length-prefixed frames out of conn_buf, publish each.
        if (conn) |c| {
            const drained = drainSocket(&conn_buf, c.stream) catch |err| blk: {
                std.debug.print("gateway: TCP read failed ({s}); closing conn\n", .{@errorName(err)});
                c.stream.close();
                conn = null;
                conn_buf.len = 0;
                break :blk DrainResult{};
            };
            bytes_tcp_in_total += drained.bytes_read;
            // Drain frames out of the buffer one at a time. peekFrame
            // returns a slice into conn_buf; publish copies into NATS
            // client buffer; consumeFrame compacts the buffer for the
            // next iteration. Loop until no complete frame remains.
            if (conn != null) {
                close_loop: while (true) {
                    const peek = peekFrame(&conn_buf) catch |err| switch (err) {
                        error.OversizedFrame => {
                            std.debug.print("gateway: oversized frame (>{d} B); closing conn\n", .{max_frame_bytes});
                            c.stream.close();
                            conn = null;
                            conn_buf.len = 0;
                            break :close_loop;
                        },
                    };
                    const frame = peek orelse break :close_loop;
                    try client.publish(input_subj, frame);
                    consumeFrame(&conn_buf);
                    frames_in_total += 1;
                }
            }
            if (conn != null and drained.eof) {
                std.debug.print("gateway: TCP client closed (EOF); reverting to idle\n", .{});
                c.stream.close();
                conn = null;
                conn_buf.len = 0;
            }
        }

        // NATS → TCP: forward each batched fanout payload to the
        // connected socket as a length-prefixed frame.
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
                    conn_buf.len = 0;
                    break :blk 0;
                };
                bytes_tcp_out_total += n;
            }
        }

        const now_ns: u64 = @intCast(std.time.nanoTimestamp());
        if (now_ns -% last_log_ns >= std.time.ns_per_s) {
            const tcp_status: []const u8 = if (conn != null) "TCP up" else "TCP idle";
            std.debug.print(
                "[gateway client={d}] {d} msgs / {d} ents / {d} clusters / {d} B in / {d} B out / {d} frames-in ({d} B) ({s}) last 1 s\n",
                .{
                    args.client_id,      msgs_total,        ents_total, clusters_total,
                    bytes_total,         bytes_tcp_out_total, frames_in_total,
                    bytes_tcp_in_total,  tcp_status,
                },
            );
            msgs_total = 0;
            ents_total = 0;
            clusters_total = 0;
            bytes_total = 0;
            bytes_tcp_out_total = 0;
            bytes_tcp_in_total = 0;
            frames_in_total = 0;
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

const DrainResult = struct {
    bytes_read: usize = 0,
    eof: bool = false,
};

/// Drain whatever's pending on `stream` into `buf`. Reads until
/// `WouldBlock` (no more data available), `eof` (peer closed), or
/// the buffer fills (oversized frame defensive limit triggers in
/// the caller). Non-blocking — never stalls the main loop.
fn drainSocket(buf: *ConnBuf, stream: std.net.Stream) !DrainResult {
    var result: DrainResult = .{};
    while (buf.len < buf.bytes.len) {
        const n = posix.read(stream.handle, buf.bytes[buf.len..]) catch |err| switch (err) {
            error.WouldBlock => return result,
            else => return err,
        };
        if (n == 0) {
            result.eof = true;
            return result;
        }
        buf.len += n;
        result.bytes_read += n;
    }
    return result;
}

/// Peek one complete length-prefixed frame at the front of `buf`,
/// returning the payload bytes as a slice INTO `buf.bytes`. The
/// slice is valid until the next mutating call; caller must invoke
/// `consumeFrame` after publish completes. Returns null if no
/// complete frame is buffered. Returns `error.OversizedFrame` if
/// the header advertises a frame larger than `max_frame_bytes` —
/// caller should close the conn (defensive against junk-on-the-
/// wire / unauthenticated peer).
fn peekFrame(buf: *const ConnBuf) error{OversizedFrame}!?[]const u8 {
    if (buf.len < frame_header_bytes) return null;
    const frame_len = std.mem.readInt(u32, buf.bytes[0..frame_header_bytes], .little);
    if (frame_len > max_frame_bytes) return error.OversizedFrame;
    const total = frame_header_bytes + @as(usize, frame_len);
    if (buf.len < total) return null;
    return buf.bytes[frame_header_bytes..total];
}

/// Drop the frame previously returned by `peekFrame` from the
/// front of `buf`. Compacts the tail down to offset 0 so the next
/// `drainSocket` call has the full buffer to read into.
fn consumeFrame(buf: *ConnBuf) void {
    const frame_len = std.mem.readInt(u32, buf.bytes[0..frame_header_bytes], .little);
    const total = frame_header_bytes + @as(usize, frame_len);
    const remaining = buf.len - total;
    if (remaining > 0) {
        std.mem.copyForwards(u8, buf.bytes[0..remaining], buf.bytes[total..buf.len]);
    }
    buf.len = remaining;
}

test "peek/consumeFrame: single frame" {
    var buf: ConnBuf = .{};
    const len_bytes: [4]u8 = .{ 5, 0, 0, 0 };
    @memcpy(buf.bytes[0..4], &len_bytes);
    @memcpy(buf.bytes[4..9], "hello");
    buf.len = 9;
    const got = try peekFrame(&buf);
    try std.testing.expect(got != null);
    try std.testing.expectEqualSlices(u8, "hello", got.?);
    consumeFrame(&buf);
    try std.testing.expectEqual(@as(usize, 0), buf.len);
}

test "peek/consumeFrame: two back-to-back frames" {
    var buf: ConnBuf = .{};
    const len_a: [4]u8 = .{ 3, 0, 0, 0 };
    const len_b: [4]u8 = .{ 4, 0, 0, 0 };
    @memcpy(buf.bytes[0..4], &len_a);
    @memcpy(buf.bytes[4..7], "abc");
    @memcpy(buf.bytes[7..11], &len_b);
    @memcpy(buf.bytes[11..15], "wxyz");
    buf.len = 15;

    const a = try peekFrame(&buf);
    try std.testing.expectEqualSlices(u8, "abc", a.?);
    consumeFrame(&buf);
    try std.testing.expectEqual(@as(usize, 8), buf.len);

    const b = try peekFrame(&buf);
    try std.testing.expectEqualSlices(u8, "wxyz", b.?);
    consumeFrame(&buf);
    try std.testing.expectEqual(@as(usize, 0), buf.len);
}

test "peek/consumeFrame: incomplete frame returns null" {
    var buf: ConnBuf = .{};
    const len_bytes: [4]u8 = .{ 5, 0, 0, 0 };
    @memcpy(buf.bytes[0..4], &len_bytes);
    @memcpy(buf.bytes[4..7], "hel"); // only 3 of 5 payload bytes
    buf.len = 7;
    try std.testing.expectEqual(@as(?[]const u8, null), try peekFrame(&buf));
}

test "peekFrame: oversized frame errors" {
    var buf: ConnBuf = .{};
    const huge: u32 = max_frame_bytes + 1;
    std.mem.writeInt(u32, buf.bytes[0..4], huge, .little);
    buf.len = 4;
    try std.testing.expectError(error.OversizedFrame, peekFrame(&buf));
}
