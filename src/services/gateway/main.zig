//! gateway — TCP ↔ NATS relay per docs/08 §1.2.
//!
//! Also acts as the producer for `events.session` (login/disconnect)
//! consumed by persistence-writer's tier-0 fast lane. See
//! `publishSession` and the `login_emitted` flag on Conn for the
//! lifecycle invariant: every login event pairs with exactly one
//! disconnect event on the same account_id.
//!
//! Stateless client-facing service that bridges TCP-connected
//! clients into the NATS service mesh. Per-client this means:
//!   - **inbound** (NATS → TCP): subscribe to `gw.client.<id>.cmd`
//!     and forward every cell-mgr fanout payload to the client's
//!     socket
//!   - **outbound** (TCP → NATS): read framed input messages from
//!     the client's socket and publish to
//!     `sim.entity.<player_id>.input`
//!
//! Sub-step 4+5 scope: JWT-validated multi-client gateway.
//! ONE gateway process handles up to `max_conns` concurrent TCP
//! connections; each one identifies itself with a JWT (HS256) as
//! its first length-prefixed frame. The token's `client_id` +
//! `player_id` claims drive that connection's NATS subscription
//! and outbound input subject. Replaces the per-process-per-client
//! workaround used during the M1.5 stress gate (commit a6775ab).
//!
//! Wire framing:
//!   - Inbound hello (TCP → gateway): `[u32_le len][JWT bytes]`. No
//!     kind tag — the hello-frame slot is unambiguously the first
//!     frame on a new conn.
//!   - Inbound input (TCP → gateway): `[u32_le len][JSON InputMsg]`.
//!     No kind tag — only one inbound stream type after auth.
//!   - Outbound (gateway → TCP): `[u32_le len][u8 kind][payload]`.
//!     `len` includes the kind byte. `kind=0` = state/cluster
//!     (cell-mgr fanout's `gw.client.<id>.cmd`, binary
//!     PayloadHeader+records); `kind=1` = fire event
//!     (`gw.client.<id>.fire`, JSON FireMsg). Receivers demux by
//!     kind — the two streams have incompatible payload shapes
//!     so a tag at the frame level is the cheapest disambiguator.
//!
//! The asymmetric framing (inbound = no tag, outbound = tag) is
//! deliberate: inbound from the client is single-stream by definition
//! (the client is one entity sending one type of input), but outbound
//! aggregates multiple NATS subjects per client so demux happens
//! at the gateway-to-client boundary.
//!
//! JWT validation:
//!   - HS256 only (no RS256, no `none` alg). Validated against the
//!     `NOTATLAS_JWT_SECRET` env var (or a dev-default with a
//!     loud warning).
//!   - Claims: `{ "client_id": u64, "player_id": u32, "exp": i64 }`
//!     (unix seconds). Expired tokens reject.
//!   - On failure: connection closes immediately, no error frame
//!     written back. Production might want a structured error
//!     response but for now the silence-then-close behavior is
//!     unambiguous and minimal-attack-surface.
//!
//! Per docs/08 §8.3 gateway is the lift-with-reshape from
//! fallen-runes' gateway. Keep this binary thin — interest filter
//! and per-tier composition live at cell-mgr (docs/08 §8 decision
//! 3), not here.

const std = @import("std");
const nats = @import("nats");
const notatlas = @import("notatlas");
const posix = std.posix;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// Subject the persistence-writer's tier-0 fast lane consumes from.
/// One event per session-lifecycle transition we emit (login on
/// successful JWT validation, disconnect on any close after that).
/// pwriter inserts into `sessions` with sub-200ms p99 — hibernation
/// grace timer reads (account_id, occurred_at DESC) and depends on
/// the disconnect row being durable before it can start ticking.
const session_subject = "events.session";

/// Session-event kinds that match the CHECK constraint on
/// sessions.kind in infra/db/init.sql.
const SessionKind = enum {
    login,
    disconnect,
    // logout is reserved for an explicit-logout protocol message that
    // doesn't exist in v0 — every clean close currently routes through
    // disconnect.
};

/// Per-payload header for slow-lane and fast-lane batches.
/// Mirrors `cell_mgr/fanout.zig:PayloadHeader`. When a real
/// `src/shared/fanout_wire.zig` lands, replace this local copy
/// with an import.
const PayloadHeader = extern struct {
    entity_count: u32,
    cluster_count: u32,
};

const default_listen_port: u16 = 9000;
const conn_buf_size: usize = 64 * 1024;
const max_frame_bytes: u32 = 16 * 1024;
const frame_header_bytes: usize = 4;
/// Per docs/08 §1.2 a single gateway process should comfortably
/// handle a few dozen concurrent client connections. 64 leaves
/// headroom over the M1.5 spec of 50.
const max_conns: usize = 64;
/// Hello frame must arrive within this many seconds of accept,
/// otherwise the conn is reaped. Stops idle non-talkers from
/// holding slots indefinitely; production might tune lower (~2 s).
const hello_timeout_s: i64 = 10;

const Args = struct {
    /// TCP listen port. Bound to 127.0.0.1 only — gateway is
    /// loopback-only until it's deployment-ready.
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
    const ignore_pipe: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &ignore_pipe, null);
}

/// Set O_NONBLOCK on a connected socket fd. Linux conn fds returned
/// by `accept()` don't inherit O_NONBLOCK from the listener.
fn setNonblocking(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    const nonblock_bit: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | nonblock_bit);
}

/// Per-connection inbound buffer.
const ConnBuf = struct {
    bytes: [conn_buf_size]u8 = undefined,
    len: usize = 0,
};

const ConnState = enum {
    /// Just accepted; haven't received a JWT hello yet.
    awaiting_hello,
    /// JWT validated, NATS sub created, both directions live.
    active,
};

/// Outbound frame kind byte. New kinds added here propagate to
/// client-side demux scripts (scripts/m1_5_drive.py, tcp_reader.py,
/// drive_ship.py).
const FrameKind = enum(u8) {
    /// `gw.client.<id>.cmd` — cell-mgr fanout (state + cluster).
    cmd = 0,
    /// `gw.client.<id>.fire` — fire event broadcast.
    fire = 1,
};

const Conn = struct {
    conn: std.net.Server.Connection,
    buf: ConnBuf = .{},
    state: ConnState = .awaiting_hello,
    accepted_at_unix_s: i64 = 0,
    client_id: u64 = 0,
    player_id: u32 = 0,
    cmd_subj: []const u8 = "",
    fire_subj: []const u8 = "",
    input_subj: []const u8 = "",
    sub_cmd: ?*nats.Subscription = null,
    sub_fire: ?*nats.Subscription = null,
    /// Set after a successful login event has been published. Drives
    /// disconnect emission from `Conns.close` — only conns that
    /// actually transitioned active should emit a disconnect on close,
    /// otherwise rejected/timed-out hellos would leak phantom sessions
    /// into PG.
    login_emitted: bool = false,

    fn deinit(self: *Conn, allocator: std.mem.Allocator, client: *nats.Client) void {
        if (self.sub_cmd) |s| client.unsubscribe(s) catch {};
        if (self.sub_fire) |s| client.unsubscribe(s) catch {};
        if (self.cmd_subj.len > 0) allocator.free(self.cmd_subj);
        if (self.fire_subj.len > 0) allocator.free(self.fire_subj);
        if (self.input_subj.len > 0) allocator.free(self.input_subj);
        self.conn.stream.close();
        self.* = undefined;
    }
};

const Conns = struct {
    slots: [max_conns]?Conn = .{null} ** max_conns,
    active_count: u32 = 0,

    fn findFree(self: *const Conns) ?usize {
        for (self.slots, 0..) |s, i| if (s == null) return i;
        return null;
    }

    fn close(
        self: *Conns,
        i: usize,
        allocator: std.mem.Allocator,
        client: *nats.Client,
        reason: []const u8,
    ) void {
        if (self.slots[i] == null) return;
        const c = &self.slots[i].?;
        // Disconnect is paired with login: only emit if a login event
        // was actually published. Awaiting-hello rejections (bad JWT,
        // hello timeout, alloc fail before subscribe) get no
        // sessions-row footprint at all — they never authenticated.
        if (c.login_emitted) {
            publishSession(client, c.client_id, 0, .disconnect, reason);
        }
        c.deinit(allocator, client);
        self.slots[i] = null;
        if (self.active_count > 0) self.active_count -= 1;
    }
};

/// Publish a single events.session message. Best-effort core publish —
/// JetStream captures it via the events_session stream subject filter
/// (workqueue retention), and pwriter handles dedup via stream_seq if
/// any redelivery happens. No PubAck wait here — gateway is on a
/// latency-sensitive path; a dropped publish surfaces as a missing
/// sessions row, which is monitored downstream.
///
/// Field mapping:
///   account_id  ← JWT.client_id (the gateway's auth-scoped identity).
///   character_id ← 0 for v0 (gateway pre-character-select; populated
///                  later when a character-select protocol exists).
///   kind        ← login | disconnect.
///   reason      ← short label for disconnects; null for login.
fn publishSession(
    client: *nats.Client,
    account_id: u64,
    character_id: u64,
    kind: SessionKind,
    reason: ?[]const u8,
) void {
    var buf: [256]u8 = undefined;
    const body = if (reason) |r| std.fmt.bufPrint(
        &buf,
        \\{{"account_id":{d},"character_id":{d},"kind":"{s}","reason":"{s}"}}
    ,
        .{ account_id, character_id, @tagName(kind), r },
    ) catch return else std.fmt.bufPrint(
        &buf,
        \\{{"account_id":{d},"character_id":{d},"kind":"{s}"}}
    ,
        .{ account_id, character_id, @tagName(kind) },
    ) catch return;

    client.publish(session_subject, body) catch |err| {
        std.debug.print(
            "gateway: events.session publish failed (kind={s} account={d}): {s}\n",
            .{ @tagName(kind), account_id, @errorName(err) },
        );
    };
}

/// JWT claims — what the gateway extracts and trusts after a
/// signature-valid token is presented. Matches the standard
/// `client_id` / `player_id` / `exp` triple a python-side helper
/// emits.
const Claims = struct {
    client_id: u64,
    player_id: u32,
    exp: i64,
};

const Identity = struct {
    client_id: u64,
    player_id: u32,
};

const JwtError = error{
    BadJwt,
    BadSignature,
    BadAlgorithm,
    Expired,
    PayloadTooLarge,
};

/// Validate a JWT bearer token (HS256). Returns the (client_id,
/// player_id) pair on success; rejects expired tokens, wrong
/// algorithms, and signature mismatches.
fn verifyJwt(
    allocator: std.mem.Allocator,
    token: []const u8,
    secret: []const u8,
    now_unix_s: i64,
) JwtError!Identity {
    // Find the two dots that separate header.payload.signature.
    const dot1 = std.mem.indexOfScalar(u8, token, '.') orelse return error.BadJwt;
    const rest = token[dot1 + 1 ..];
    const dot2_in_rest = std.mem.indexOfScalar(u8, rest, '.') orelse return error.BadJwt;
    const dot2 = dot1 + 1 + dot2_in_rest;
    if (std.mem.indexOfScalarPos(u8, token, dot2 + 1, '.') != null) return error.BadJwt;

    const header_b64 = token[0..dot1];
    const payload_b64 = token[dot1 + 1 .. dot2];
    const sig_b64 = token[dot2 + 1 ..];
    if (header_b64.len == 0 or payload_b64.len == 0 or sig_b64.len == 0) return error.BadJwt;

    // Verify signature against the signed input "header.payload".
    const signed = token[0..dot2];
    var expected_mac: [HmacSha256.mac_length]u8 = undefined;
    var hmac = HmacSha256.init(secret);
    hmac.update(signed);
    hmac.final(&expected_mac);

    var got_mac: [HmacSha256.mac_length]u8 = undefined;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const sig_size = decoder.calcSizeForSlice(sig_b64) catch return error.BadJwt;
    if (sig_size != HmacSha256.mac_length) return error.BadSignature;
    decoder.decode(got_mac[0..sig_size], sig_b64) catch return error.BadJwt;
    if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, expected_mac, got_mac)) {
        return error.BadSignature;
    }

    // Decode header — must have alg=HS256. Reject anything else,
    // especially `none` (the classic JWT footgun).
    var header_buf: [256]u8 = undefined;
    const header_size = decoder.calcSizeForSlice(header_b64) catch return error.BadJwt;
    if (header_size > header_buf.len) return error.PayloadTooLarge;
    decoder.decode(header_buf[0..header_size], header_b64) catch return error.BadJwt;

    const Header = struct { alg: []const u8 };
    const parsed_hdr = std.json.parseFromSlice(
        Header,
        allocator,
        header_buf[0..header_size],
        .{ .ignore_unknown_fields = true },
    ) catch return error.BadJwt;
    defer parsed_hdr.deinit();
    if (!std.mem.eql(u8, parsed_hdr.value.alg, "HS256")) return error.BadAlgorithm;

    // Decode + parse claims.
    var payload_buf: [512]u8 = undefined;
    const payload_size = decoder.calcSizeForSlice(payload_b64) catch return error.BadJwt;
    if (payload_size > payload_buf.len) return error.PayloadTooLarge;
    decoder.decode(payload_buf[0..payload_size], payload_b64) catch return error.BadJwt;

    const parsed = std.json.parseFromSlice(
        Claims,
        allocator,
        payload_buf[0..payload_size],
        .{ .ignore_unknown_fields = true },
    ) catch return error.BadJwt;
    defer parsed.deinit();

    if (parsed.value.exp <= now_unix_s) return error.Expired;
    return .{ .client_id = parsed.value.client_id, .player_id = parsed.value.player_id };
}

/// Resolve the JWT signing secret. Env `NOTATLAS_JWT_SECRET` if
/// set; otherwise a dev-default with a loud warning (the warning
/// is the load-bearing part — production deployments should fail
/// CI if this default is observed in logs).
fn resolveSecret(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "NOTATLAS_JWT_SECRET")) |s| {
        return s;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            std.debug.print("gateway: WARNING — NOTATLAS_JWT_SECRET unset; using dev-default. DO NOT DEPLOY.\n", .{});
            return try allocator.dupe(u8, "notatlas-dev-secret-do-not-deploy");
        },
        else => return err,
    }
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);
    defer allocator.free(args.nats_url);
    try installSignalHandlers();

    const secret = try resolveSecret(allocator);
    defer allocator.free(secret);

    const listen_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, args.listen_port);
    var server = try listen_addr.listen(.{
        .reuse_address = true,
        .force_nonblocking = true,
    });
    defer server.deinit();
    std.debug.print("gateway: listening on 127.0.0.1:{d}; max_conns={d}\n", .{ args.listen_port, max_conns });

    std.debug.print("gateway: connecting to {s}\n", .{args.nats_url});
    var client = try nats.Client.connect(allocator, .{
        .servers = &.{args.nats_url},
        .name = "gateway",
    });
    defer client.close();
    std.debug.print("gateway: connected\n", .{});

    var conns: Conns = .{};
    defer for (&conns.slots, 0..) |*slot, i| {
        if (slot.* != null) conns.close(i, allocator, client, "shutdown");
    };

    var msgs_total: u64 = 0;
    var ents_total: u64 = 0;
    var clusters_total: u64 = 0;
    var bytes_total: u64 = 0;
    var bytes_tcp_out_total: u64 = 0;
    var bytes_tcp_in_total: u64 = 0;
    var frames_in_total: u64 = 0;
    var fires_fwd_total: u64 = 0;
    var accepts_total: u64 = 0;
    var rejected_jwt: u64 = 0;
    var rejected_full: u64 = 0;
    var last_log_ns: u64 = @intCast(std.time.nanoTimestamp());

    while (g_running.load(.acquire)) {
        try client.processIncomingTimeout(5);
        try client.maybeSendPing();

        // Accept as many pending conns as we have free slots for.
        accept_loop: while (true) {
            const new_conn = server.accept() catch |err| switch (err) {
                error.WouldBlock => break :accept_loop,
                else => return err,
            };
            const slot_idx = conns.findFree() orelse {
                std.debug.print(
                    "gateway: rejecting conn from {f} — all {d} slots full\n",
                    .{ new_conn.address, max_conns },
                );
                rejected_full += 1;
                new_conn.stream.close();
                continue;
            };
            setNonblocking(new_conn.stream.handle) catch |err| {
                std.debug.print("gateway: setNonblocking failed ({s}); rejecting\n", .{@errorName(err)});
                new_conn.stream.close();
                continue;
            };
            conns.slots[slot_idx] = .{
                .conn = new_conn,
                .accepted_at_unix_s = std.time.timestamp(),
            };
            conns.active_count += 1;
            accepts_total += 1;
        }

        // Per-conn work.
        for (&conns.slots, 0..) |*slot, i| {
            if (slot.* == null) continue;
            const c = &slot.*.?;

            // Hello-timeout reaper for awaiting_hello conns that
            // never speak — protects the slot table from idle non-
            // talkers / port-scanners.
            if (c.state == .awaiting_hello) {
                if (std.time.timestamp() - c.accepted_at_unix_s > hello_timeout_s) {
                    std.debug.print(
                        "gateway: conn {f} hello timeout; closing\n",
                        .{c.conn.address},
                    );
                    rejected_jwt += 1;
                    conns.close(i, allocator, client, "hello_timeout");
                    continue;
                }
            }

            // TCP → buffer.
            const drained = drainSocket(&c.buf, c.conn.stream) catch |err| {
                std.debug.print("gateway: conn {d} read failed ({s}); closing\n", .{ i, @errorName(err) });
                conns.close(i, allocator, client, "read_fail");
                continue;
            };
            bytes_tcp_in_total += drained.bytes_read;

            // State-driven frame handling.
            switch (c.state) {
                .awaiting_hello => {
                    const peek = peekFrame(&c.buf) catch |err| {
                        std.debug.print("gateway: conn {d} bad hello frame ({s}); closing\n", .{ i, @errorName(err) });
                        rejected_jwt += 1;
                        conns.close(i, allocator, client, "bad_hello_frame");
                        continue;
                    };
                    if (peek) |jwt_bytes| {
                        const id = verifyJwt(allocator, jwt_bytes, secret, std.time.timestamp()) catch |err| {
                            std.debug.print("gateway: conn {d} JWT rejected ({s}); closing\n", .{ i, @errorName(err) });
                            rejected_jwt += 1;
                            conns.close(i, allocator, client, "jwt_rejected");
                            continue;
                        };
                        c.client_id = id.client_id;
                        c.player_id = id.player_id;
                        c.cmd_subj = std.fmt.allocPrint(allocator, "gw.client.{d}.cmd", .{id.client_id}) catch |err| {
                            std.debug.print("gateway: conn {d} alloc cmd_subj failed ({s})\n", .{ i, @errorName(err) });
                            conns.close(i, allocator, client, "alloc_fail");
                            continue;
                        };
                        c.fire_subj = std.fmt.allocPrint(allocator, "gw.client.{d}.fire", .{id.client_id}) catch |err| {
                            std.debug.print("gateway: conn {d} alloc fire_subj failed ({s})\n", .{ i, @errorName(err) });
                            conns.close(i, allocator, client, "alloc_fail");
                            continue;
                        };
                        c.input_subj = std.fmt.allocPrint(allocator, "sim.entity.{d}.input", .{id.player_id}) catch |err| {
                            std.debug.print("gateway: conn {d} alloc input_subj failed ({s})\n", .{ i, @errorName(err) });
                            conns.close(i, allocator, client, "alloc_fail");
                            continue;
                        };
                        c.sub_cmd = client.subscribe(c.cmd_subj, .{}) catch |err| {
                            std.debug.print("gateway: conn {d} subscribe cmd failed ({s})\n", .{ i, @errorName(err) });
                            conns.close(i, allocator, client, "subscribe_fail");
                            continue;
                        };
                        c.sub_fire = client.subscribe(c.fire_subj, .{}) catch |err| {
                            std.debug.print("gateway: conn {d} subscribe fire failed ({s})\n", .{ i, @errorName(err) });
                            conns.close(i, allocator, client, "subscribe_fail");
                            continue;
                        };
                        c.state = .active;
                        consumeFrame(&c.buf);
                        // Emit login AFTER the state transition + sub
                        // creation succeeds. Set login_emitted so any
                        // subsequent close on this slot pairs with a
                        // disconnect event. character_id=0 for v0 (no
                        // character-select protocol yet).
                        publishSession(client, c.client_id, 0, .login, null);
                        c.login_emitted = true;
                        std.debug.print(
                            "gateway: conn {d} from {f} → client_id={d} player_id={d}\n",
                            .{ i, c.conn.address, c.client_id, c.player_id },
                        );
                    }
                },
                .active => {
                    // TCP → NATS publish.
                    publish_loop: while (true) {
                        const peek = peekFrame(&c.buf) catch {
                            std.debug.print("gateway: conn {d} oversized frame; closing\n", .{i});
                            conns.close(i, allocator, client, "oversized_frame");
                            break :publish_loop;
                        };
                        const frame = peek orelse break :publish_loop;
                        client.publish(c.input_subj, frame) catch |err| {
                            std.debug.print("gateway: conn {d} input publish failed ({s})\n", .{ i, @errorName(err) });
                            conns.close(i, allocator, client, "publish_fail");
                            break :publish_loop;
                        };
                        consumeFrame(&c.buf);
                        frames_in_total += 1;
                    }
                },
            }

            // NATS → TCP forward (only meaningful for active conns).
            // Drain both `.cmd` and `.fire` subs; tag each frame with
            // its kind so the client can demux state-binary vs
            // fire-JSON.
            if (slot.* != null and slot.*.?.state == .active) {
                const sub_cmd = slot.*.?.sub_cmd.?;
                while (sub_cmd.nextMsg()) |msg| {
                    var owned = msg;
                    defer owned.deinit();
                    const payload = owned.payload orelse continue;
                    msgs_total += 1;
                    bytes_total += payload.len;
                    const hdr = decodeHeader(payload);
                    ents_total += hdr.entity_count;
                    clusters_total += hdr.cluster_count;
                    const n = forwardFrame(slot.*.?.conn.stream, .cmd, payload) catch |err| {
                        std.debug.print("gateway: conn {d} write cmd failed ({s}); closing\n", .{ i, @errorName(err) });
                        conns.close(i, allocator, client, "write_fail");
                        break;
                    };
                    bytes_tcp_out_total += n;
                }
                if (slot.* == null) continue;
                const sub_fire = slot.*.?.sub_fire.?;
                while (sub_fire.nextMsg()) |msg| {
                    var owned = msg;
                    defer owned.deinit();
                    const payload = owned.payload orelse continue;
                    fires_fwd_total += 1;
                    bytes_total += payload.len;
                    const n = forwardFrame(slot.*.?.conn.stream, .fire, payload) catch |err| {
                        std.debug.print("gateway: conn {d} write fire failed ({s}); closing\n", .{ i, @errorName(err) });
                        conns.close(i, allocator, client, "write_fail");
                        break;
                    };
                    bytes_tcp_out_total += n;
                }
            }

            if (slot.* != null and drained.eof) {
                std.debug.print("gateway: conn {d} EOF; closing\n", .{i});
                conns.close(i, allocator, client, "client_close");
            }
        }

        const now_ns: u64 = @intCast(std.time.nanoTimestamp());
        if (now_ns -% last_log_ns >= std.time.ns_per_s) {
            std.debug.print(
                "[gateway] {d} active conns / {d} accepts ({d} jwt-reject, {d} full-reject) | NATS in: {d} msgs / {d} ents / {d} clusters / {d} fires / {d} B | TCP in: {d} frames ({d} B) | TCP out: {d} B (last 1 s)\n",
                .{
                    conns.active_count, accepts_total,    rejected_jwt, rejected_full,
                    msgs_total,         ents_total,       clusters_total, fires_fwd_total,
                    bytes_total,        frames_in_total, bytes_tcp_in_total,
                    bytes_tcp_out_total,
                },
            );
            msgs_total = 0;
            ents_total = 0;
            clusters_total = 0;
            bytes_total = 0;
            bytes_tcp_out_total = 0;
            bytes_tcp_in_total = 0;
            frames_in_total = 0;
            fires_fwd_total = 0;
            accepts_total = 0;
            rejected_jwt = 0;
            rejected_full = 0;
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

/// Write `[u32_le len][u8 kind][payload]` to the connected client.
/// `len` includes the 1-byte kind tag. Blocking writes — the conn
/// socket is non-blocking so a slow reader returns
/// `error.WouldBlock` (treated as a write failure → conn close).
/// Real backpressure handling is future work.
fn forwardFrame(stream: std.net.Stream, kind: FrameKind, payload: []const u8) !usize {
    var header: [4]u8 = undefined;
    const total_payload_len = 1 + payload.len;
    std.mem.writeInt(u32, &header, @intCast(total_payload_len), .little);
    try stream.writeAll(&header);
    var kind_byte: [1]u8 = .{@intFromEnum(kind)};
    try stream.writeAll(&kind_byte);
    try stream.writeAll(payload);
    return header.len + total_payload_len;
}

const DrainResult = struct {
    bytes_read: usize = 0,
    eof: bool = false,
};

/// Drain whatever's pending on `stream` into `buf`. Reads until
/// `WouldBlock`, EOF, or the buffer fills. Non-blocking — never
/// stalls the main loop.
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
/// slice is valid until the next mutating call.
fn peekFrame(buf: *const ConnBuf) error{OversizedFrame}!?[]const u8 {
    if (buf.len < frame_header_bytes) return null;
    const frame_len = std.mem.readInt(u32, buf.bytes[0..frame_header_bytes], .little);
    if (frame_len > max_frame_bytes) return error.OversizedFrame;
    const total = frame_header_bytes + @as(usize, frame_len);
    if (buf.len < total) return null;
    return buf.bytes[frame_header_bytes..total];
}

fn consumeFrame(buf: *ConnBuf) void {
    const frame_len = std.mem.readInt(u32, buf.bytes[0..frame_header_bytes], .little);
    const total = frame_header_bytes + @as(usize, frame_len);
    const remaining = buf.len - total;
    if (remaining > 0) {
        std.mem.copyForwards(u8, buf.bytes[0..remaining], buf.bytes[total..buf.len]);
    }
    buf.len = remaining;
}

// ---- tests ----

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
    @memcpy(buf.bytes[4..7], "hel");
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

/// Helper: mint a valid HS256 JWT inside the test process so the
/// verify path doesn't depend on an external token-mint tool.
fn mintTestJwt(
    out_buf: []u8,
    secret: []const u8,
    claims_json: []const u8,
) ![]const u8 {
    const header_json = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const encoder = std.base64.url_safe_no_pad.Encoder;

    const header_b64_len = encoder.calcSize(header_json.len);
    const payload_b64_len = encoder.calcSize(claims_json.len);
    const sig_b64_len = encoder.calcSize(HmacSha256.mac_length);
    const total = header_b64_len + 1 + payload_b64_len + 1 + sig_b64_len;
    if (total > out_buf.len) return error.NoSpaceLeft;

    var off: usize = 0;
    _ = encoder.encode(out_buf[off .. off + header_b64_len], header_json);
    off += header_b64_len;
    out_buf[off] = '.';
    off += 1;
    _ = encoder.encode(out_buf[off .. off + payload_b64_len], claims_json);
    off += payload_b64_len;

    var mac: [HmacSha256.mac_length]u8 = undefined;
    var hmac = HmacSha256.init(secret);
    hmac.update(out_buf[0..off]);
    hmac.final(&mac);

    out_buf[off] = '.';
    off += 1;
    _ = encoder.encode(out_buf[off .. off + sig_b64_len], &mac);
    off += sig_b64_len;
    return out_buf[0..off];
}

test "verifyJwt: valid token" {
    var buf: [512]u8 = undefined;
    const claims = "{\"client_id\":256,\"player_id\":7,\"exp\":99999999999}";
    const tok = try mintTestJwt(&buf, "test-secret", claims);
    const id = try verifyJwt(std.testing.allocator, tok, "test-secret", 1_000_000);
    try std.testing.expectEqual(@as(u64, 256), id.client_id);
    try std.testing.expectEqual(@as(u32, 7), id.player_id);
}

test "verifyJwt: bad signature" {
    var buf: [512]u8 = undefined;
    const claims = "{\"client_id\":256,\"player_id\":7,\"exp\":99999999999}";
    const tok = try mintTestJwt(&buf, "test-secret", claims);
    try std.testing.expectError(
        error.BadSignature,
        verifyJwt(std.testing.allocator, tok, "wrong-secret", 1_000_000),
    );
}

test "verifyJwt: expired" {
    var buf: [512]u8 = undefined;
    const claims = "{\"client_id\":256,\"player_id\":7,\"exp\":500}";
    const tok = try mintTestJwt(&buf, "test-secret", claims);
    try std.testing.expectError(
        error.Expired,
        verifyJwt(std.testing.allocator, tok, "test-secret", 1_000_000),
    );
}

test "verifyJwt: malformed (no dots)" {
    try std.testing.expectError(
        error.BadJwt,
        verifyJwt(std.testing.allocator, "not-a-jwt", "secret", 0),
    );
}

test "verifyJwt: malformed (only one dot)" {
    try std.testing.expectError(
        error.BadJwt,
        verifyJwt(std.testing.allocator, "abc.def", "secret", 0),
    );
}

test "verifyJwt: rejects alg=none" {
    // Hand-crafted token with `alg":"none"` header. Even with no
    // signature this should reject — defensive against the classic
    // JWT-library footgun.
    const encoder = std.base64.url_safe_no_pad.Encoder;
    var hdr_buf: [128]u8 = undefined;
    var pl_buf: [128]u8 = undefined;
    var tok_buf: [512]u8 = undefined;
    const hdr_json = "{\"alg\":\"none\",\"typ\":\"JWT\"}";
    const pl_json = "{\"client_id\":1,\"player_id\":1,\"exp\":99999999999}";
    const hdr_b64_len = encoder.calcSize(hdr_json.len);
    const pl_b64_len = encoder.calcSize(pl_json.len);
    _ = encoder.encode(hdr_buf[0..hdr_b64_len], hdr_json);
    _ = encoder.encode(pl_buf[0..pl_b64_len], pl_json);
    const sig_b64 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"; // bogus
    const tok = try std.fmt.bufPrint(&tok_buf, "{s}.{s}.{s}", .{
        hdr_buf[0..hdr_b64_len],
        pl_buf[0..pl_b64_len],
        sig_b64,
    });
    // Signature won't match HS256 of (header+payload), so this fails
    // at signature step before alg check — that's fine, both are
    // rejection paths. The point of the test is: alg=none never
    // succeeds.
    const r = verifyJwt(std.testing.allocator, tok, "any-secret", 1_000_000);
    try std.testing.expectError(error.BadSignature, r);
}
