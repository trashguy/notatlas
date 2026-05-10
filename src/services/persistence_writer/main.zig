//! persistence-writer — sole Postgres writer per docs/02 §5.
//!
//! Consumes JetStream change streams (workqueue retention) and
//! materializes them into Postgres tables. Never on the hot path;
//! batches writes; ack-on-commit so JetStream redelivers any work
//! that wasn't durably committed.
//!
//! v0 streams attached, by SLA tier:
//!   tier=fast (sub-second p99 — game-mechanic correctness)
//!     events_session          events.session              → sessions
//!   tier=slow (10s p99 — analytics)
//!     events_market_trade     events.market.trade         → market_trades
//!     events_handoff_cell     events.handoff.cell         → cell_handoffs
//!     events_inventory_change events.inventory.change.*   → inventories
//!
//! The fast lane is checked first every iteration with timeout=0 and
//! drained to completion before any slow-tier work runs. Hibernation
//! grace timer can't start until pwriter has durably stored the
//! disconnect row, so session events MUST NOT be latency-blocked behind
//! a flooded analytics stream.
//!
//! Damage is NOT in pwriter — too volume-heavy for row-per-event PG
//! and the only useful queries are aggregates. Live damage stays on
//! `sim.entity.*.damage` core NATS; a future stats-sim consumes it.
//! Optional forensic JetStream capture is config in
//! `data/jetstream.yaml` (disabled by default).
//!
//! Per-stream wiring lives in `stream_specs[]` — adding another stream
//! is one entry plus a handler. Within a tier the order is round-robin;
//! tier itself is the priority dimension.
//!
//! Per-event errors (FK violation, malformed JSON, etc.) are isolated
//! via Postgres SAVEPOINTs so one bad event doesn't roll back the
//! batch. JetStream redelivers only un-acked messages.
//!
//! Design context:
//!   - docs/02-architecture.md §5 — mixed persistence shape, sole-writer
//!     decision. Damage/handoff lists are JetStream KV (live) plus PG
//!     analytics aggregates; market is purely relational; inventory is
//!     the JSONB blob path.
//!   - feedback_graceful_degradation.md — PG offline must NOT cascade
//!     into producers. Producers keep writing to JetStream (durable);
//!     this service catches up on reconnect.
//!   - feedback_nats_zig_2_14_consumer_envelope.md — js.createConsumer
//!     in nats-zig 0.2.2 sends pre-2.14 JSON; we hand-roll via
//!     client.request() until nats-zig 0.3 ships.

const std = @import("std");
const nats = @import("nats");
const pg = @import("pg");
const wire = @import("wire");

const fetch_batch: u32 = 256;
// Slow tier: round-robin pull with a small timeout so cold streams don't
// block hot ones. Three slow streams × 25 ms = ~75 ms wrap.
const fetch_timeout_slow_ms: u32 = 25;
// Fast tier: small non-zero timeout. timeout=0 looks tempting (non-
// blocking poll, drain to completion via outer loop) but nats-zig 0.2.2's
// PullSubscription.fetch publishes the NEXT request and then loops on
// `now < deadline` — with deadline=now, the loop body never executes and
// the broker's response is dropped on the floor. 5 ms is enough for a
// local-broker round-trip and small enough that an idle fast lane only
// burns 5 ms per outer iteration; an active lane returns as soon as the
// batch arrives and the drain-loop continues immediately.
const fetch_timeout_fast_ms: u32 = 5;
const idle_sleep_ns: u64 = 50 * std.time.ns_per_ms;
const log_interval_ns: u64 = std.time.ns_per_s;

// Status snapshot cadence. 5 s is a common ops compromise: long enough
// that breach detection has signal (>30 s sustained = real breach, not
// a single slow batch), short enough that the dashboard doesn't feel
// stale. Aligns with admin.cycle.changed cadence — both are
// human-observable, not hot-path.
const status_interval_ns: u64 = 5 * std.time.ns_per_s;
// Sustained-lag breach: lag_p99 over SLA continuously for this long
// trips a breach. Single slow batches don't count — only sustained
// pressure does.
const breach_lag_window_ns: i128 = 30 * std.time.ns_per_s;
// Stalled-progress breach: no successful inserts for this long while
// pending > 0 = pwriter is stuck. Different signal from lag — covers
// the case where pwriter is running but every batch errors.
const breach_stall_window_ns: i128 = 5 * 60 * std.time.ns_per_s;
const breach_stall_pending_threshold: u64 = 1000;

const consumer_name = "pwriter";

// 300s. Long enough that a slow batch (PG hiccup, lock wait) doesn't cause
// premature redelivery, short enough that a real pwriter crash doesn't park
// events behind a dead consumer for hours. Idempotency is on stream_seq UNIQUE
// + ON CONFLICT DO NOTHING, so redelivery is a no-op insert anyway — ack_wait
// is just controlling redelivery cadence, not correctness.
//
// Runtime-overridable via --ack-wait-s for smoke harnesses (the dedup
// smoke needs ack_wait short enough that broker-side redelivery happens
// within smoke wallclock). Treated as `var` rather than `const` so the
// CLI flag can write through; ensureConsumer reads at consumer-create
// time. Re-creating an existing consumer with a different ack_wait
// requires deleting the consumer first (broker rejects mismatched
// configs); smokes do that explicitly.
var ack_wait_ns: u64 = 300 * std.time.ns_per_s;

/// Debug flag: skip the JS ack call after a successful insert. Lets a
/// smoke harness leave messages un-acked so ack_wait expiry triggers
/// real broker-side redelivery — the only way to exercise dedup
/// without racing pwriter's own ack path. NEVER set in production.
var no_ack_mode: bool = false;

const Outcome = enum { inserted, dedup_skipped };

const AckMeta = struct {
    stream_seq: u64,
    publish_time_ns: i128,
};

/// Ring buffer of recent per-message lag samples (ms from broker
/// publish-timestamp to commit-time). 256 samples at 1 fast-stream
/// in-flight is ~one minute of recent activity at session cadence;
/// for slow-tier analytics it's much less but lag-quality concerns
/// are different anyway. p99 sorts a copy on demand — fine since
/// status publishes at 0.2 Hz (5 s cadence).
const LagBuffer = struct {
    samples_ms: [256]u32 = undefined,
    count: u16 = 0, // saturates at 256
    head: u8 = 0, // wraps at 256

    fn record(self: *LagBuffer, lag_ms: u32) void {
        self.samples_ms[self.head] = lag_ms;
        self.head +%= 1;
        if (self.count < 256) self.count += 1;
    }

    fn p99(self: *const LagBuffer) u32 {
        if (self.count == 0) return 0;
        var copy: [256]u32 = undefined;
        const n = self.count;
        @memcpy(copy[0..n], self.samples_ms[0..n]);
        std.mem.sort(u32, copy[0..n], {}, std.sort.asc(u32));
        // Floor of 99th percentile: idx = ceil(n * 0.99) - 1, but for
        // small n (n < 100) p99 collapses to max — that's fine for
        // observability; what we care about is "is the tail bad?"
        const idx = if (n == 1) 0 else (@as(usize, n) * 99 + 99) / 100 - 1;
        return copy[idx];
    }
};

const StreamMetrics = struct {
    committed: u64 = 0,
    dedup_skipped: u64 = 0,
    failed: u64 = 0,
    /// Time-of-last-successful-commit, ns since UNIX epoch (i128 to
    /// match std.time.nanoTimestamp). 0 = no inserts yet this run.
    last_insert_ns: i128 = 0,
    /// Filled by publishStatus from JS consumer-info; observability only.
    pending: u64 = 0,
    lag: LagBuffer = .{},
    /// Resolved at startup from spec.sla_p99_ms with optional CLI
    /// override applied. Held per-stream so per-tier overrides land
    /// here without touching the comptime spec table.
    sla_p99_ms: u32 = 0,
    /// Breach-onset timestamp (ns since UNIX epoch). 0 = not breaching.
    breach_since_ns: i128 = 0,
};

/// Drain priority. fast streams are drained to completion (timeout=0
/// pull) before any slow stream runs. The classification is not a
/// throughput decision — it's a correctness decision: fast-tier streams
/// gate a downstream game mechanic (hibernation grace timer for
/// sessions; future: trade-confirmation latency for market). Slow-tier
/// is post-cycle analytics where 10s of lag is invisible.
const Tier = enum { fast, slow };

const StreamSpec = struct {
    stream_name: []const u8,
    subject_filter: []const u8,
    /// Short label used in periodic log lines and status emissions.
    /// Avoids leaking the `events_` prefix into observability.
    label: []const u8,
    tier: Tier,
    /// SLA budget — published with status in commit C, used here only
    /// as a self-documenting field on the spec. Breach detection lives
    /// alongside the metrics emitter.
    sla_p99_ms: u32,
    handler: *const fn (
        allocator: std.mem.Allocator,
        conn: *pg.Conn,
        cycle_id: i64,
        subject: []const u8,
        payload: []const u8,
        stream_seq: u64,
    ) anyerror!Outcome,
};

// Damage events are deliberately NOT in this list. The PG row would
// be ~5k/sec/cell × 100 cells × 70d = ~30B rows per wipe — and the
// only useful queries are aggregates (kill counts, leaderboards).
// Live damage flows on `sim.entity.*.damage` core NATS; future
// stats-sim and anomaly-sim consume there. Optional forensic
// capture is a broker-level config in `data/jetstream.yaml`,
// disabled by default. See memory `architecture_damage_not_in_pg.md`.
const stream_specs = [_]StreamSpec{
    .{
        .stream_name = "events_session",
        .subject_filter = "events.session",
        .label = "session",
        .tier = .fast,
        .sla_p99_ms = 200,
        .handler = handleSession,
    },
    .{
        .stream_name = "events_market_trade",
        .subject_filter = "events.market.trade",
        .label = "market",
        .tier = .slow,
        .sla_p99_ms = 10_000,
        .handler = handleMarketTrade,
    },
    .{
        .stream_name = "events_handoff_cell",
        .subject_filter = "events.handoff.cell",
        .label = "handoff",
        .tier = .slow,
        .sla_p99_ms = 10_000,
        .handler = handleHandoffCell,
    },
    .{
        .stream_name = "events_inventory_change",
        .subject_filter = "events.inventory.change.*",
        .label = "inv",
        .tier = .slow,
        .sla_p99_ms = 10_000,
        .handler = handleInventoryChange,
    },
};

const Args = struct {
    nats_url: []const u8 = "nats://127.0.0.1:4222",
    pg_host: []const u8 = "127.0.0.1",
    pg_port: u16 = 5432,
    pg_user: []const u8 = "notatlas",
    pg_pass: []const u8 = "notatlas",
    pg_db: []const u8 = "notatlas",
    /// SLA overrides — null preserves the comptime default in
    /// stream_specs[].sla_p99_ms. Tournaments can tighten or loosen
    /// per-tier without recompiling.
    fast_sla_ms: ?u32 = null,
    slow_sla_ms: ?u32 = null,
    /// Smoke-only knobs. ack_wait_s overrides the consumer's ack_wait;
    /// no_ack disables ack publishing so messages stay outstanding.
    ack_wait_s: ?u64 = null,
    no_ack: bool = false,
};

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var out: Args = .{};
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--nats")) {
            out.nats_url = try allocator.dupe(u8, args.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, a, "--pg-host")) {
            out.pg_host = try allocator.dupe(u8, args.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, a, "--pg-port")) {
            out.pg_port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--pg-user")) {
            out.pg_user = try allocator.dupe(u8, args.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, a, "--pg-pass")) {
            out.pg_pass = try allocator.dupe(u8, args.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, a, "--pg-db")) {
            out.pg_db = try allocator.dupe(u8, args.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, a, "--fast-sla-ms")) {
            out.fast_sla_ms = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--slow-sla-ms")) {
            out.slow_sla_ms = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--ack-wait-s")) {
            out.ack_wait_s = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--no-ack")) {
            out.no_ack = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                \\persistence-writer — sole Postgres writer.
                \\
                \\Options:
                \\  --nats <url>          (default nats://127.0.0.1:4222)
                \\  --pg-host <host>      (default 127.0.0.1)
                \\  --pg-port <port>      (default 5432)
                \\  --pg-user <user>      (default notatlas)
                \\  --pg-pass <pass>      (default notatlas)
                \\  --pg-db <db>          (default notatlas)
                \\  --fast-sla-ms <ms>    override tier=fast SLA (default 200)
                \\  --slow-sla-ms <ms>    override tier=slow SLA (default 10000)
                \\  --ack-wait-s <s>      override consumer ack_wait (smoke-only; default 300)
                \\  --no-ack              skip ack after insert (smoke-only; never use in prod)
                \\
            , .{});
            std.process.exit(0);
        } else {
            std.debug.print("persistence-writer: unknown arg '{s}'\n", .{a});
            return error.BadArg;
        }
    }
    return out;
}

var stop_flag = std.atomic.Value(bool).init(false);

fn handleSignal(_: c_int) callconv(.c) void {
    stop_flag.store(true, .release);
}

fn installSignalHandlers() !void {
    var sa: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);

    if (args.ack_wait_s) |s| ack_wait_ns = s * std.time.ns_per_s;
    no_ack_mode = args.no_ack;
    if (no_ack_mode) {
        std.debug.print(
            "persistence-writer: --no-ack ENABLED (smoke-only — messages will not be acked)\n",
            .{},
        );
    }

    try installSignalHandlers();

    std.debug.print("persistence-writer: connecting to nats {s}\n", .{args.nats_url});
    var nats_client = nats.Client.connect(allocator, .{
        .servers = &.{args.nats_url},
        .name = "persistence-writer",
    }) catch |err| {
        std.debug.print("persistence-writer: nats connect failed: {}\n", .{err});
        return err;
    };
    defer nats_client.close();
    std.debug.print("persistence-writer: nats connected\n", .{});

    std.debug.print("persistence-writer: connecting to pg {s}@{s}:{d}/{s}\n", .{
        args.pg_user, args.pg_host, args.pg_port, args.pg_db,
    });
    var pool = pg.Pool.init(allocator, .{
        .size = 1,
        .connect = .{ .host = args.pg_host, .port = args.pg_port },
        .auth = .{
            .username = args.pg_user,
            .password = args.pg_pass,
            .database = args.pg_db,
            .timeout = 10_000,
        },
    }) catch |err| {
        std.debug.print("persistence-writer: pg connect failed: {}\n", .{err});
        return err;
    };
    defer pool.deinit();
    std.debug.print("persistence-writer: pg connected\n", .{});

    var cycle_id: i64 = probeCurrentCycle(pool) catch |err| {
        std.debug.print("persistence-writer: cycle probe failed: {}\n", .{err});
        return err;
    };
    std.debug.print("persistence-writer: current cycle id={d}\n", .{cycle_id});

    // `admin.cycle.changed` is the wipe-rollover signal. We don't
    // trust the message payload — instead we re-probe wipe_cycles to
    // get the new authoritative cycle id. This way a malformed or
    // late-delivered notification can't pin pwriter to the wrong
    // cycle. Core NATS (best-effort): if we miss the message, the
    // boot-time probe corrects on next restart.
    const cycle_sub = try nats_client.subscribe("admin.cycle.changed", .{});
    defer nats_client.unsubscribe(cycle_sub) catch {};

    var js = nats.JetStream.Context.init(nats_client);
    var pulls: [stream_specs.len]nats.JetStream.PullSubscription = undefined;
    var pulls_initialized: usize = 0;
    defer {
        var i: usize = pulls_initialized;
        while (i > 0) {
            i -= 1;
            pulls[i].close();
        }
    }

    for (stream_specs, 0..) |spec, i| {
        try ensureStream(&js, spec.stream_name, spec.subject_filter);
        try ensureConsumer(nats_client, spec.stream_name);
        pulls[i] = try js.pullSubscribe(spec.stream_name, consumer_name);
        pulls_initialized = i + 1;
        std.debug.print(
            "persistence-writer: stream={s} subject={s} consumer={s} ready\n",
            .{ spec.stream_name, spec.subject_filter, consumer_name },
        );
    }

    // Per-stream runtime metrics. SLA defaults from comptime spec, with
    // optional CLI override per tier (tournaments tighten fast-lane;
    // ops loosen slow-lane during analytics replays).
    var metrics: [stream_specs.len]StreamMetrics = undefined;
    inline for (stream_specs, 0..) |spec, i| {
        const sla = switch (spec.tier) {
            .fast => args.fast_sla_ms orelse spec.sla_p99_ms,
            .slow => args.slow_sla_ms orelse spec.sla_p99_ms,
        };
        metrics[i] = .{ .sla_p99_ms = sla };
    }

    var last_log_ns: i128 = std.time.nanoTimestamp();
    var last_status_ns: i128 = std.time.nanoTimestamp();
    while (!stop_flag.load(.acquire)) {
        // pull.fetch internally calls processIncoming which dispatches
        // ALL routed messages — so cycle_sub is being filled by the
        // fetches below. Drain any pending cycle-changed notifications
        // before processing events so a rolled cycle takes effect on
        // the next handler call.
        while (cycle_sub.nextMsg()) |msg_orig| {
            var cmsg = msg_orig;
            defer cmsg.deinit();
            const new_cycle = probeCurrentCycle(pool) catch |err| {
                std.debug.print(
                    "persistence-writer: cycle re-probe failed: {}\n",
                    .{err},
                );
                continue;
            };
            if (new_cycle != cycle_id) {
                std.debug.print(
                    "persistence-writer: cycle rolled {d} -> {d}\n",
                    .{ cycle_id, new_cycle },
                );
                cycle_id = new_cycle;
            }
        }

        var any_processed = false;

        // Pass 1: drain fast streams to completion. Loop until every
        // fast stream returns empty in a single sweep. timeout=0 keeps
        // each fetch non-blocking so this is a tight inner loop only
        // while there's actual fast-tier work; an idle fast lane costs
        // ~one round-trip per outer iteration.
        var fast_quiet = false;
        while (!fast_quiet) {
            fast_quiet = true;
            for (stream_specs, 0..) |spec, i| {
                if (spec.tier != .fast) continue;
                if (drainBatch(allocator, pool, &pulls[i], spec, cycle_id, fetch_timeout_fast_ms, &metrics[i].lag)) |stats| {
                    if (stats.nonzero()) {
                        if (stats.committed + stats.dedup_skipped > 0) fast_quiet = false;
                        any_processed = true;
                        metrics[i].committed += stats.committed;
                        metrics[i].dedup_skipped += stats.dedup_skipped;
                        metrics[i].failed += stats.failed;
                        if (stats.last_insert_ns != 0) metrics[i].last_insert_ns = stats.last_insert_ns;
                    }
                } else |_| {}
            }
        }

        // Pass 2: round-robin slow streams once. Hot slow streams get
        // amortized over fast-lane drain cycles; this is fine because
        // slow-tier SLAs are seconds, not milliseconds.
        for (stream_specs, 0..) |spec, i| {
            if (spec.tier != .slow) continue;
            if (drainBatch(allocator, pool, &pulls[i], spec, cycle_id, fetch_timeout_slow_ms, &metrics[i].lag)) |stats| {
                if (stats.nonzero()) {
                    any_processed = true;
                    metrics[i].committed += stats.committed;
                    metrics[i].dedup_skipped += stats.dedup_skipped;
                    metrics[i].failed += stats.failed;
                    if (stats.last_insert_ns != 0) metrics[i].last_insert_ns = stats.last_insert_ns;
                }
            } else |_| {}
        }
        if (!any_processed) std.Thread.sleep(idle_sleep_ns);

        const now = std.time.nanoTimestamp();
        if (now - last_log_ns >= log_interval_ns) {
            logTotals(cycle_id, "tick", &metrics);
            last_log_ns = now;
        }
        if (now - last_status_ns >= status_interval_ns) {
            publishStatus(nats_client, cycle_id, &metrics, now);
            last_status_ns = now;
        }
    }

    logTotals(cycle_id, "shutdown", &metrics);
}

/// Fetch + process one batch from a stream. Returns null on fetch error
/// (already logged); empty batches return zero-stat. Caller summates.
fn drainBatch(
    allocator: std.mem.Allocator,
    pool: *pg.Pool,
    pull: *nats.JetStream.PullSubscription,
    spec: StreamSpec,
    cycle_id: i64,
    timeout_ms: u32,
    lag: *LagBuffer,
) !BatchStats {
    const msgs = pull.fetch(fetch_batch, timeout_ms) catch |err| {
        std.debug.print(
            "persistence-writer: fetch err on {s}: {}\n",
            .{ spec.stream_name, err },
        );
        return err;
    };
    defer {
        for (msgs) |*m| @constCast(m).deinit();
        allocator.free(msgs);
    }
    if (msgs.len == 0) return BatchStats{};

    return processBatch(allocator, pool, pull, msgs, cycle_id, spec.handler, lag) catch |err| {
        std.debug.print(
            "persistence-writer: batch err on {s}: {}\n",
            .{ spec.stream_name, err },
        );
        return BatchStats{};
    };
}

/// Format committed/dedup totals dynamically over stream_specs so adding
/// a stream doesn't require touching the log line.
fn logTotals(
    cycle_id: i64,
    phase: []const u8,
    metrics: *const [stream_specs.len]StreamMetrics,
) void {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.print("persistence-writer: {s} cycle={d}", .{ phase, cycle_id }) catch return;
    inline for (stream_specs, 0..) |spec, i| {
        w.print(" {s}={d}/{d}", .{ spec.label, metrics[i].committed, metrics[i].dedup_skipped }) catch return;
    }
    w.print(" (committed/dedup)\n", .{}) catch return;
    std.debug.print("{s}", .{fbs.getWritten()});
}

/// Best-effort consumer-info request to refresh `pending`. nats-zig 0.2.2
/// doesn't expose a `consumerInfo()` helper, but the request shape is
/// the same one js.streamInfo uses — just the CONSUMER.INFO subject.
/// Failure mode: log once and return; the cached `pending` value stays
/// from the previous tick. Status emission proceeds regardless because
/// the hibernation grace mechanic depends on the FAST-LANE inserts, not
/// on this number.
fn refreshPending(client: *nats.Client, stream_name: []const u8) ?u64 {
    var subject_buf: [256]u8 = undefined;
    const subject = std.fmt.bufPrint(
        &subject_buf,
        "$JS.API.CONSUMER.INFO.{s}.{s}",
        .{ stream_name, consumer_name },
    ) catch return null;

    var msg = client.request(subject, null, 1000) catch return null;
    defer msg.deinit();

    const payload = msg.payload orelse return null;
    // Hand-roll: search for `"num_pending":<n>`. Cheaper than a
    // full JSON parse, and resilient to schema drift (response gains
    // new fields all the time).
    const key = "\"num_pending\":";
    const k = std.mem.indexOf(u8, payload, key) orelse return null;
    var i: usize = k + key.len;
    while (i < payload.len and (payload[i] == ' ' or payload[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < payload.len and payload[i] >= '0' and payload[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseInt(u64, payload[start..i], 10) catch null;
}

const BreachKind = enum { lag, stalled };

/// Per-stream breach detector. Two trigger conditions:
///   - lag_p99 > sla_p99_ms sustained for ≥ breach_lag_window_ns
///   - last_insert_ms_ago > breach_stall_window_ns AND pending > breach_stall_pending_threshold
/// State is held in StreamMetrics.breach_since_ns: 0 = healthy,
/// nonzero = breach-onset timestamp. Transitions emit
/// admin.pwriter.breach for downstream alerting.
fn detectBreach(
    client: *nats.Client,
    spec: StreamSpec,
    m: *StreamMetrics,
    now_ns: i128,
) void {
    const lag_p99 = m.lag.p99();
    const stalled = m.last_insert_ns != 0 and
        (now_ns - m.last_insert_ns) > breach_stall_window_ns and
        m.pending >= breach_stall_pending_threshold;
    const lagging = lag_p99 > m.sla_p99_ms;
    const condition_now = stalled or lagging;

    if (condition_now and m.breach_since_ns == 0) {
        // Pre-breach: condition just became true. Mark the start time
        // but don't emit yet — sustained-window check happens below.
        m.breach_since_ns = now_ns;
    } else if (!condition_now and m.breach_since_ns != 0) {
        // Recovery transition. If we'd previously emitted onset, emit
        // recovery; otherwise just clear the pre-breach mark silently.
        const sustained = (now_ns - m.breach_since_ns) >= breach_lag_window_ns;
        m.breach_since_ns = 0;
        if (sustained) {
            publishBreach(client, spec.label, .lag, "recovered");
        }
    } else if (condition_now and m.breach_since_ns != 0) {
        // Sustained breach: only emit onset on the FIRST tick after
        // crossing the lag-window threshold. Subsequent ticks while
        // breaching are silent (avoid flooding admin.pwriter.breach).
        const elapsed = now_ns - m.breach_since_ns;
        const was_emitted = elapsed >= breach_lag_window_ns + status_interval_ns;
        const just_crossed = elapsed >= breach_lag_window_ns and !was_emitted;
        if (just_crossed) {
            const kind: BreachKind = if (stalled) .stalled else .lag;
            const reason = if (stalled) "stalled" else "lag_p99_over_sla";
            publishBreach(client, spec.label, kind, reason);
        }
    }
}

fn publishBreach(client: *nats.Client, label: []const u8, kind: BreachKind, reason: []const u8) void {
    var buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(
        &buf,
        "{{\"stream\":\"{s}\",\"kind\":\"{s}\",\"reason\":\"{s}\"}}",
        .{ label, @tagName(kind), reason },
    ) catch return;
    client.publish("admin.pwriter.breach", body) catch |err| {
        std.debug.print("persistence-writer: breach publish err: {}\n", .{err});
    };
    std.debug.print(
        "persistence-writer: breach stream={s} kind={s} reason={s}\n",
        .{ label, @tagName(kind), reason },
    );
}

/// Build + publish the periodic status snapshot on admin.pwriter.status.
/// Single-subject flat snapshot per the SLA design call (one consumer
/// pulls the whole pwriter state in one message). Refreshes pending
/// from JS consumer-info, evaluates breach state, emits JSON.
fn publishStatus(
    client: *nats.Client,
    cycle_id: i64,
    metrics: *[stream_specs.len]StreamMetrics,
    now_ns: i128,
) void {
    // Refresh pending on each stream.
    inline for (stream_specs, 0..) |spec, i| {
        if (refreshPending(client, spec.stream_name)) |p| metrics[i].pending = p;
    }

    // Evaluate breach state per stream (may publish admin.pwriter.breach).
    inline for (stream_specs, 0..) |spec, i| {
        detectBreach(client, spec, &metrics[i], now_ns);
    }

    // Build + publish the status snapshot. 4 streams × ~150 bytes per
    // entry = ~600 B; 2 KB stack buffer is plenty.
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.print("{{\"cycle\":{d},\"streams\":[", .{cycle_id}) catch return;
    inline for (stream_specs, 0..) |spec, i| {
        const m = metrics[i];
        const last_ms_ago: i128 = if (m.last_insert_ns == 0) -1 else @divTrunc(now_ns - m.last_insert_ns, std.time.ns_per_ms);
        if (i != 0) w.writeAll(",") catch return;
        w.print(
            "{{\"name\":\"{s}\",\"tier\":\"{s}\",\"sla_p99_ms\":{d}," ++
                "\"committed\":{d},\"dedup_skipped\":{d},\"failed\":{d}," ++
                "\"pending\":{d},\"lag_ms_p99\":{d}," ++
                "\"last_insert_ms_ago\":{d},\"sla_breach\":{s}}}",
            .{
                spec.label,
                @tagName(spec.tier),
                m.sla_p99_ms,
                m.committed,
                m.dedup_skipped,
                m.failed,
                m.pending,
                m.lag.p99(),
                last_ms_ago,
                if (m.breach_since_ns != 0 and (now_ns - m.breach_since_ns) >= breach_lag_window_ns) "true" else "false",
            },
        ) catch return;
    }
    w.writeAll("]}") catch return;
    client.publish("admin.pwriter.status", fbs.getWritten()) catch |err| {
        std.debug.print("persistence-writer: status publish err: {}\n", .{err});
    };
}

fn probeCurrentCycle(pool: *pg.Pool) !i64 {
    var row_opt = try pool.row(
        "SELECT id FROM wipe_cycles WHERE ends_at IS NULL ORDER BY id DESC LIMIT 1",
        .{},
    );
    if (row_opt) |*row| {
        defer row.deinit() catch {};
        return try row.get(i64, 0);
    }
    return error.NoCurrentCycle;
}

fn ensureStream(
    js: *nats.JetStream.Context,
    stream_name: []const u8,
    subject_filter: []const u8,
) !void {
    if (js.streamInfo(stream_name)) |_| {
        return;
    } else |err| switch (err) {
        nats.JetStream.Error.StreamNotFound => {},
        else => return err,
    }
    _ = try js.createStream(.{
        .name = stream_name,
        .subjects = &.{subject_filter},
        .retention = .workqueue,
        .storage = .file,
    });
}

/// See `feedback_nats_zig_2_14_consumer_envelope.md`. nats-zig 0.2.2's
/// `js.createConsumer` sends the pre-2.14 envelope; we POST the 2.14
/// shape directly. Accept a re-create against an existing matching
/// config (broker returns success) and surface mismatches loudly.
fn ensureConsumer(client: *nats.Client, stream_name: []const u8) !void {
    var subject_buf: [256]u8 = undefined;
    const subject = try std.fmt.bufPrint(
        &subject_buf,
        "$JS.API.CONSUMER.CREATE.{s}.{s}",
        .{ stream_name, consumer_name },
    );

    var body_buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &body_buf,
        \\{{"stream_name":"{s}","config":{{"durable_name":"{s}","ack_policy":"explicit","deliver_policy":"all","max_deliver":-1,"ack_wait":{d}}}}}
    ,
        .{ stream_name, consumer_name, ack_wait_ns },
    );

    var msg = try client.request(subject, body, 5000);
    defer msg.deinit();

    const payload = msg.payload orelse return error.NoBrokerResponse;
    if (std.mem.indexOf(u8, payload, "\"error\":{") != null) {
        std.debug.print(
            "persistence-writer: consumer create rejected on {s}: {s}\n",
            .{ stream_name, payload },
        );
        return error.ConsumerCreateRejected;
    }
}

const BatchStats = struct {
    committed: u64 = 0,
    dedup_skipped: u64 = 0,
    failed: u64 = 0,
    /// Time of last successful insert in this batch (0 if no inserts).
    /// Caller updates StreamMetrics.last_insert_ns from this.
    last_insert_ns: i128 = 0,

    fn nonzero(self: BatchStats) bool {
        return self.committed + self.dedup_skipped + self.failed > 0;
    }
};

/// Parse stream_seq + publish_time_ns from the JS ACK reply_to subject.
/// Two layouts are in the wild:
///   v1 (no domain):   $JS.ACK.<stream>.<consumer>.<delivery>.<stream_seq>.<consumer_seq>.<ts>.<pending>
///   v2 (with domain): $JS.ACK.<domain>.<accthash>.<stream>.<consumer>.<delivery>.<stream_seq>.<consumer_seq>.<ts>.<pending>.<random>
/// stream_seq sits at index 5 (v1, 9 tokens) or 7 (v2, 12 tokens);
/// timestamp at idx 7 / 9 respectively (ns since UNIX epoch). NATS
/// 2.14 dev broker emits v1; production with a JS domain emits v2 —
/// both are handled rather than betting on the deployment shape.
fn parseAckMeta(reply_to: ?[]const u8) ?AckMeta {
    const r = reply_to orelse return null;
    if (!std.mem.startsWith(u8, r, "$JS.ACK.")) return null;

    var tokens: [16][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, r, '.');
    while (it.next()) |t| : (n += 1) {
        if (n >= tokens.len) return null;
        tokens[n] = t;
    }
    const seq_idx: usize, const ts_idx: usize = switch (n) {
        9 => .{ 5, 7 },
        12 => .{ 7, 9 },
        else => return null,
    };
    const stream_seq = std.fmt.parseInt(u64, tokens[seq_idx], 10) catch return null;
    const publish_time_ns = std.fmt.parseInt(i128, tokens[ts_idx], 10) catch return null;
    return .{ .stream_seq = stream_seq, .publish_time_ns = publish_time_ns };
}

/// Drain a fetched batch into PG. Each event runs as a single auto-
/// committed statement (no explicit BEGIN/COMMIT) — pg.zig considers
/// the connection unrecoverable after any tx-error, which kills
/// SAVEPOINT-based per-event isolation. Auto-commit gives the same
/// isolation property cheaply: a FK violation on event N doesn't
/// affect events N±1.
///
/// Idempotency: each handler INSERTs with `ON CONFLICT (stream_seq) DO
/// NOTHING` keyed on the JetStream-assigned seq parsed from reply_to.
/// Redelivery (ack_wait expiry, mid-batch crash, broker restart) thus
/// collapses to a no-op insert; the message is still acked so the
/// broker stops redelivering it. Inventory is content-idempotent via
/// UPSERT-on-character_id and ignores stream_seq (version counter may
/// drift on redelivery, blob is correct).
///
/// Ack policy:
///   handler returned .inserted or .dedup_skipped → ack (durable progress)
///   handler errored                              → no-ack (JetStream redelivers)
///
/// Application-level errors (FK violation on a known-bad event) will
/// thus redeliver forever and pollute the log. The intent is that
/// such events are producer bugs that should be fixed at the source —
/// not silently dropped here. If a deadletter destination becomes
/// useful, route NAKs there explicitly.
fn processBatch(
    allocator: std.mem.Allocator,
    pool: *pg.Pool,
    pull: *nats.JetStream.PullSubscription,
    msgs: []nats.Protocol.Msg,
    cycle_id: i64,
    handler: *const fn (
        std.mem.Allocator,
        *pg.Conn,
        i64,
        []const u8,
        []const u8,
        u64,
    ) anyerror!Outcome,
    lag: *LagBuffer,
) !BatchStats {
    var conn = try pool.acquire();
    defer conn.release();

    var stats: BatchStats = .{};
    for (msgs) |*m| {
        const payload = m.payload orelse {
            // Empty payload — ack and skip; nothing to write.
            pull.ack(m) catch {};
            continue;
        };
        const subject = m.subject;

        const ack_meta = parseAckMeta(m.reply_to) orelse {
            std.debug.print(
                "persistence-writer: missing/unparseable JS reply_to on '{s}': {?s}\n",
                .{ subject, m.reply_to },
            );
            // No metadata → can't dedup → don't insert. Don't ack
            // either; broker redelivers and the next attempt either
            // succeeds (transient) or stays stuck (producer bug worth
            // surfacing in logs).
            stats.failed += 1;
            continue;
        };

        const outcome = handler(allocator, conn, cycle_id, subject, payload, ack_meta.stream_seq) catch |err| {
            if (conn.err) |pg_err| {
                std.debug.print(
                    "persistence-writer: handler err on '{s}' seq={d}: {} — pg: {s}\n",
                    .{ subject, ack_meta.stream_seq, err, pg_err.message },
                );
            } else {
                std.debug.print(
                    "persistence-writer: handler err on '{s}' seq={d}: {}\n",
                    .{ subject, ack_meta.stream_seq, err },
                );
            }
            // No ack — JetStream will redeliver after ack_wait.
            // pg.zig keeps the connection in .fail state after a
            // statement error; release+reacquire forces the pool to
            // hand back a usable connection (or reconnect if needed).
            conn.release();
            conn = try pool.acquire();
            stats.failed += 1;
            continue;
        };

        if (!no_ack_mode) {
            pull.ack(m) catch |err| {
                std.debug.print("persistence-writer: ack err {}\n", .{err});
                continue;
            };
        }
        const now_ns = std.time.nanoTimestamp();
        // Lag = time from broker publish to commit. Negative deltas can
        // happen if the dev broker's wall clock drifts behind ours;
        // clamp to 0 rather than wrapping a u32.
        const lag_ns = now_ns - ack_meta.publish_time_ns;
        const lag_ms: u32 = if (lag_ns <= 0) 0 else std.math.cast(u32, @divTrunc(lag_ns, std.time.ns_per_ms)) orelse std.math.maxInt(u32);
        lag.record(lag_ms);
        switch (outcome) {
            .inserted => {
                stats.committed += 1;
                stats.last_insert_ns = now_ns;
            },
            .dedup_skipped => stats.dedup_skipped += 1,
        }
    }
    return stats;
}

// ---------------------------------------------------------------------------
// Per-stream handlers. Each handler runs inside a SAVEPOINT so any error
// rolls back THIS event only and the batch tx continues.
// ---------------------------------------------------------------------------

/// Tier-0 fast-lane handler. Hibernation grace timer reads
/// (character_id, occurred_at DESC) so the disconnect row needs to be
/// durable before the gateway finishes its disconnect path. INSERT is
/// idempotent on stream_seq.
fn handleSession(
    allocator: std.mem.Allocator,
    conn: *pg.Conn,
    cycle_id: i64,
    subject: []const u8,
    payload: []const u8,
    stream_seq: u64,
) !Outcome {
    _ = subject;
    var parsed = try wire.decodeSession(allocator, payload);
    defer parsed.deinit();
    const s = parsed.value;

    const character: ?i64 = if (s.character_id == 0) null else s.character_id;
    const reason: ?[]const u8 = s.reason;

    const rows = try conn.exec(
        \\INSERT INTO sessions
        \\  (stream_seq, cycle_id, account_id, character_id, kind, reason, occurred_at)
        \\VALUES ($1, $2, $3, $4, $5, $6, NOW())
        \\ON CONFLICT (stream_seq) DO NOTHING
    ,
        .{
            @as(i64, @intCast(stream_seq)),
            cycle_id,
            s.account_id,
            character,
            s.kind,
            reason,
        },
    );
    return if ((rows orelse 0) == 0) .dedup_skipped else .inserted;
}

fn handleMarketTrade(
    allocator: std.mem.Allocator,
    conn: *pg.Conn,
    cycle_id: i64,
    subject: []const u8,
    payload: []const u8,
    stream_seq: u64,
) !Outcome {
    _ = subject;
    var parsed = try wire.decodeMarketTrade(allocator, payload);
    defer parsed.deinit();
    const t = parsed.value;

    // Producer convention: 0 means "no FK" — stored as NULL so the
    // ON DELETE SET NULL FK semantics work without a referential row.
    const buy_order = if (t.buy_order_id == 0) null else @as(?i64, t.buy_order_id);
    const sell_order = if (t.sell_order_id == 0) null else @as(?i64, t.sell_order_id);
    const buyer = if (t.buyer_id == 0) null else @as(?i64, t.buyer_id);
    const seller = if (t.seller_id == 0) null else @as(?i64, t.seller_id);

    const rows = try conn.exec(
        \\INSERT INTO market_trades
        \\  (stream_seq, cycle_id, buy_order_id, sell_order_id, buyer_id, seller_id,
        \\   item_def_id, quantity, price, executed_at)
        \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, NOW())
        \\ON CONFLICT (stream_seq) DO NOTHING
    ,
        .{
            @as(i64, @intCast(stream_seq)),
            cycle_id,
            buy_order,
            sell_order,
            buyer,
            seller,
            t.item_def_id,
            t.quantity,
            t.price,
        },
    );
    return if ((rows orelse 0) == 0) .dedup_skipped else .inserted;
}

fn handleHandoffCell(
    allocator: std.mem.Allocator,
    conn: *pg.Conn,
    cycle_id: i64,
    subject: []const u8,
    payload: []const u8,
    stream_seq: u64,
) !Outcome {
    _ = subject;
    var parsed = try wire.decodeHandoffCell(allocator, payload);
    defer parsed.deinit();
    const h = parsed.value;

    const rows = try conn.exec(
        \\INSERT INTO cell_handoffs
        \\  (stream_seq, cycle_id, entity_id,
        \\   from_cell_x, from_cell_y, to_cell_x, to_cell_y,
        \\   pos_x, pos_y, pos_z, occurred_at)
        \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NOW())
        \\ON CONFLICT (stream_seq) DO NOTHING
    ,
        .{
            @as(i64, @intCast(stream_seq)),
            cycle_id,
            @as(i64, h.entity_id),
            h.from_cell_x,
            h.from_cell_y,
            h.to_cell_x,
            h.to_cell_y,
            h.pos_x,
            h.pos_y,
            h.pos_z,
        },
    );
    return if ((rows orelse 0) == 0) .dedup_skipped else .inserted;
}

fn handleInventoryChange(
    allocator: std.mem.Allocator,
    conn: *pg.Conn,
    cycle_id: i64,
    subject: []const u8,
    payload: []const u8,
    stream_seq: u64,
) !Outcome {
    _ = allocator;
    _ = cycle_id; // inventories.character_id PK is the wipe-scope; cycle is via characters FK
    _ = stream_seq; // upsert-on-PK is content-idempotent; redelivery bumps version, blob stays correct
    const character_id = try wire.parseCharacterIdFromInventorySubject(subject);

    // Upsert the entire blob. version bumps on each update so a future
    // reader can detect stale snapshots.
    _ = try conn.exec(
        \\INSERT INTO inventories (character_id, version, blob, updated_at)
        \\VALUES ($1, 1, $2::jsonb, NOW())
        \\ON CONFLICT (character_id) DO UPDATE
        \\SET version = inventories.version + 1,
        \\    blob = EXCLUDED.blob,
        \\    updated_at = NOW()
    ,
        .{ character_id, payload },
    );
    return .inserted;
}
