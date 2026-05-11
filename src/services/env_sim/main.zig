//! env-sim — environmental sampling service per docs/02 §5.
//!
//! v0 scope: wind only. 5 Hz tick (matches the locked
//! architecture-decision tick rate for environment). On boot loads
//! `data/wind.yaml` via `notatlas.yaml_loader.loadWindFromFile`,
//! then once per tick samples `notatlas.wind_query.windAt` at the
//! center of every cell in the publish set and emits
//! `env.cell.<x>_<z>.wind { vx, vz }` per cell.
//!
//! Why per-cell publish (rather than one global wind subject):
//!   - matches docs/02 §1.2 NATS scheme `env.cell.<x>_<y>.*` for
//!     static-state subjects;
//!   - sets up plumbing for per-cell wind variation (storms drift,
//!     coastal effects) without a wire change;
//!   - subscribers (ship-sim, ai-sim) wildcard-subscribe and route
//!     by parsed cell, no per-cell sub setup needed.
//!
//! v0 publishes a 3×3 cell block centered on (0, 0) by default —
//! covers the dev sandbox where ships spawn near the origin.
//! Override via `--cell` (repeatable). Phase 2 expands to per-shard
//! sharding (each env-sim instance owns a contiguous block of
//! cells).
//!
//! Wave seed / tide / time-of-day are deferred. They live on the
//! same service surface but each gets its own wire shape and tick
//! cadence (waves at 5 Hz alongside wind, tide hourly, ToD every
//! few seconds).

const std = @import("std");
const nats = @import("nats");
const notatlas = @import("notatlas");
const wire = @import("wire");

const tick_period_ns: u64 = std.time.ns_per_s / 5; // 5 Hz (wind + waves)
const tod_tick_period_ns: u64 = std.time.ns_per_s; // 1 Hz (time-of-day)
const log_interval_ns: u64 = std.time.ns_per_s;

/// Default day length (s). 20 minutes is short enough that one
/// dev-session covers a full dawn→dusk cycle for visual / sky-shader
/// iteration; production wipes-per-cycle settle on a much longer
/// real-time-locked schedule (TODO: data/time.yaml when raid windows
/// land).
const default_day_length_s: f64 = 1200.0;

/// Default cell side (m). Must match the value spatial-index runs
/// with — the cell-center coordinate the wind is sampled at uses
/// this. Phase 2 scales the world to the production 4 km cell side
/// per docs/06; for now 200 m matches spatial-index's dev default.
const default_cell_side_m: f32 = 200.0;

const wind_config_path = "data/wind.yaml";
const waves_dir = "data/waves/";

/// Default wave preset. `data/waves/<preset>.yaml` must exist; ymlz
/// will error at boot if not.
const default_wave_preset: []const u8 = "storm";

const CellCoord = struct { x: i32, z: i32 };

const Args = struct {
    nats_url: []const u8 = "nats://127.0.0.1:4222",
    cell_side_m: f32 = default_cell_side_m,
    /// Set of (cell_x, cell_z) coordinates to publish wind for.
    /// Empty → defaults to a 3×3 block centered on (0, 0).
    cells: []const CellCoord = &.{},
    /// Wave preset name. Resolves to `data/waves/<name>.yaml`. v0
    /// publishes the same preset to every cell; per-cell variation
    /// (coastal calm, deep-water storm) lands when content needs it.
    wave_preset: []const u8 = default_wave_preset,
    /// Day length in seconds. Drives day_fraction in the ToD broadcast.
    day_length_s: f64 = default_day_length_s,
};

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var out: Args = .{};
    var have_nats = false;
    var owned_wave_preset = false;
    var cells: std.ArrayListUnmanaged(CellCoord) = .{};
    errdefer cells.deinit(allocator);
    errdefer if (owned_wave_preset) allocator.free(out.wave_preset);

    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--nats")) {
            const v = args.next() orelse return error.MissingArg;
            out.nats_url = try allocator.dupe(u8, v);
            have_nats = true;
        } else if (std.mem.eql(u8, a, "--cell-side")) {
            out.cell_side_m = try std.fmt.parseFloat(f32, args.next() orelse return error.MissingArg);
            if (out.cell_side_m <= 0) return error.BadArg;
        } else if (std.mem.eql(u8, a, "--cell")) {
            const v = args.next() orelse return error.MissingArg;
            const sep = std.mem.indexOfScalar(u8, v, '_') orelse {
                std.debug.print("env-sim: bad --cell '{s}' (want X_Z, e.g. 0_0)\n", .{v});
                return error.BadArg;
            };
            const x = try std.fmt.parseInt(i32, v[0..sep], 10);
            const z = try std.fmt.parseInt(i32, v[sep + 1 ..], 10);
            try cells.append(allocator, .{ .x = x, .z = z });
        } else if (std.mem.eql(u8, a, "--wave-preset")) {
            const v = args.next() orelse return error.MissingArg;
            out.wave_preset = try allocator.dupe(u8, v);
            owned_wave_preset = true;
        } else if (std.mem.eql(u8, a, "--day-length-s")) {
            out.day_length_s = try std.fmt.parseFloat(f64, args.next() orelse return error.MissingArg);
            if (out.day_length_s <= 0) return error.BadArg;
        } else {
            std.debug.print("env-sim: unknown arg '{s}'\n", .{a});
            return error.BadArg;
        }
    }
    if (!have_nats) out.nats_url = try allocator.dupe(u8, out.nats_url);
    if (!owned_wave_preset) out.wave_preset = try allocator.dupe(u8, out.wave_preset);

    if (cells.items.len == 0) {
        // Default: 3×3 around origin.
        var z: i32 = -1;
        while (z <= 1) : (z += 1) {
            var x: i32 = -1;
            while (x <= 1) : (x += 1) {
                try cells.append(allocator, .{ .x = x, .z = z });
            }
        }
    }
    out.cells = try cells.toOwnedSlice(allocator);
    return out;
}

fn freeArgs(allocator: std.mem.Allocator, a: *Args) void {
    allocator.free(a.nats_url);
    allocator.free(a.cells);
    allocator.free(a.wave_preset);
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

fn loadWind(gpa: std.mem.Allocator, rel_path: []const u8) !notatlas.wind_query.WindParams {
    const abs = try std.fs.cwd().realpathAlloc(gpa, rel_path);
    defer gpa.free(abs);
    return notatlas.yaml_loader.loadWindFromFile(gpa, abs);
}

fn loadWavePreset(gpa: std.mem.Allocator, preset: []const u8) !notatlas.wave_query.WaveParams {
    const rel = try std.fmt.allocPrint(gpa, "{s}{s}.yaml", .{ waves_dir, preset });
    defer gpa.free(rel);
    const abs = try std.fs.cwd().realpathAlloc(gpa, rel);
    defer gpa.free(abs);
    return notatlas.yaml_loader.loadFromFile(gpa, abs);
}

fn waveMsgFromParams(p: notatlas.wave_query.WaveParams) wire.WaveMsg {
    return .{
        .seed = p.seed,
        .iterations = p.iterations,
        .drag_multiplier = p.drag_multiplier,
        .amplitude_m = p.amplitude_m,
        .wave_scale_m = p.wave_scale_m,
        .frequency_mult = p.frequency_mult,
        .base_time_mult = p.base_time_mult,
        .time_mult = p.time_mult,
        .weight_decay = p.weight_decay,
    };
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try parseArgs(allocator);
    defer freeArgs(allocator, &args);
    try installSignalHandlers();

    const wind_params = try loadWind(allocator, wind_config_path);
    defer wind_params.deinit(allocator);

    const wave_params = loadWavePreset(allocator, args.wave_preset) catch |err| {
        std.debug.print("env-sim: failed to load wave preset '{s}' ({s})\n", .{ args.wave_preset, @errorName(err) });
        return err;
    };
    const wave_msg = waveMsgFromParams(wave_params);

    // Pre-encode the WaveMsg once at boot — preset doesn't change at
    // runtime in v0, so re-stringifying every tick would burn the
    // allocator for nothing. When admin-driven preset changes ship,
    // re-encode in response to the admin signal.
    const wave_payload = try wire.encodeWave(allocator, wave_msg);
    defer allocator.free(wave_payload);

    // Scratch slice for the storm broadcast — sized once at boot,
    // reused every ToD tick. Storm count is fixed by the YAML so the
    // slice never grows.
    const storm_scratch = try allocator.alloc(wire.StormMsg, wind_params.storms.len);
    defer allocator.free(storm_scratch);

    std.debug.print(
        "env-sim: connecting to {s}; cell_side={d:.0} m; publishing wind+waves for {d} cell(s); wind base_speed={d:.1} m/s base_dir={d:.2} rad; wave preset='{s}' seed={d} amp={d:.2}m; {d} storms; day_length={d:.0}s\n",
        .{
            args.nats_url,
            args.cell_side_m,
            args.cells.len,
            wind_params.base_speed_mps,
            wind_params.base_direction_rad,
            args.wave_preset,
            wave_msg.seed,
            wave_msg.amplitude_m,
            wind_params.storms.len,
            args.day_length_s,
        },
    );

    var client = try nats.Client.connect(allocator, .{
        .servers = &.{args.nats_url},
        .name = "env-sim",
    });
    defer client.close();

    const start_ns: u64 = @intCast(std.time.nanoTimestamp());
    var last_tick_ns: u64 = start_ns;
    var last_tod_ns: u64 = start_ns -% tod_tick_period_ns; // fire ToD immediately on first loop
    var last_log_ns: u64 = start_ns;
    var pubs_in_window: u64 = 0;
    var tod_pubs_in_window: u64 = 0;
    var tick_n: u64 = 0;

    // World clock in seconds since boot — drives the slow shift in
    // base direction (windAt is a function of (x, z, t) not a
    // monotonic counter) AND the day_fraction in the ToD broadcast.
    // f64 because the wipe cycle is ~10 weeks.
    var world_time_s: f64 = 0;

    while (g_running.load(.acquire)) {
        try client.processIncomingTimeout(5);
        try client.maybeSendPing();

        const now_ns: u64 = @intCast(std.time.nanoTimestamp());
        if (now_ns -% last_tick_ns >= tick_period_ns) {
            // Catch-up loop in case a long log flush or GC pause put
            // us behind. Bound the catch-up at 5 to avoid spiral
            // catch-up making things worse.
            var ticks_due: u32 = 0;
            while (now_ns -% last_tick_ns >= tick_period_ns and ticks_due < 5) : (ticks_due += 1) {
                pubs_in_window += try publishTick(allocator, client, wind_params, wave_payload, args.cells, args.cell_side_m, world_time_s);
                tick_n += 1;
                world_time_s += 1.0 / 5.0;
                last_tick_ns +%= tick_period_ns;
            }
        }

        if (now_ns -% last_tod_ns >= tod_tick_period_ns) {
            try publishTimeOfDay(allocator, client, world_time_s, args.day_length_s);
            try publishStorms(allocator, client, wind_params, world_time_s, storm_scratch);
            tod_pubs_in_window += 1;
            last_tod_ns +%= tod_tick_period_ns;
        }

        if (now_ns -% last_log_ns >= log_interval_ns) {
            // Each wind+wave tick publishes 2 subjects per cell, so
            // the expected env-cell pubs/s rate is 2 × cells × 5 Hz.
            // ToD adds one global publish per second.
            const expected = args.cells.len * 5 * 2;
            std.debug.print(
                "[env-sim] {d} ticks last 1 s (target 5); {d} cells × 5 Hz × 2 = {d} pubs/s expected, {d} actual; {d} ToD pubs\n",
                .{ tick_n -% (tick_n -| 5), args.cells.len, expected, pubs_in_window, tod_pubs_in_window },
            );
            pubs_in_window = 0;
            tod_pubs_in_window = 0;
            last_log_ns = now_ns;
        }
    }

    std.debug.print("env-sim: shutting down at tick {d}\n", .{tick_n});
}

fn publishTimeOfDay(
    allocator: std.mem.Allocator,
    client: *nats.Client,
    world_time_s: f64,
    day_length_s: f64,
) !void {
    const phase = @mod(world_time_s, day_length_s);
    const fraction: f32 = @floatCast(phase / day_length_s);
    const msg: wire.TimeOfDayMsg = .{ .world_time_s = world_time_s, .day_fraction = fraction };
    const buf = try wire.encodeTimeOfDay(allocator, msg);
    defer allocator.free(buf);
    try client.publish("env.time", buf);
}

/// Publish `env.storms` — all storms with their current world
/// positions computed via `wind_query.stormCenter`. Storm ids carry
/// the `Kind.storm` (0x04) top-byte tag; per-storm seq = index in
/// `wind_params.storms`. v0 storms are static-count (defined by the
/// YAML), so the storm_id sequence is stable across publishes —
/// consumers can build a `HashMap<storm_id, last_pos>` and update in
/// place each receipt.
fn publishStorms(
    allocator: std.mem.Allocator,
    client: *nats.Client,
    params: notatlas.wind_query.WindParams,
    world_time_s: f64,
    out_buf: []wire.StormMsg,
) !void {
    const t: f32 = @floatCast(world_time_s);
    std.debug.assert(out_buf.len >= params.storms.len);
    for (params.storms, 0..) |s, i| {
        const center = notatlas.wind_query.stormCenter(params, i, t);
        out_buf[i] = .{
            .storm_id = notatlas.entity_kind.pack(.storm, @intCast(i)),
            .pos_x = center[0],
            .pos_z = center[1],
            .radius_m = s.radius_m,
            .strength_mps = s.strength_mps,
            .vortex_mix = s.vortex_mix,
        };
    }
    const msg: wire.StormListMsg = .{ .storms = out_buf[0..params.storms.len] };
    const payload = try wire.encodeStormList(allocator, msg);
    defer allocator.free(payload);
    try client.publish("env.storms", payload);
}

fn publishTick(
    allocator: std.mem.Allocator,
    client: *nats.Client,
    params: notatlas.wind_query.WindParams,
    /// Pre-encoded wave payload — same for every cell at v0, so we
    /// stringify once at boot and re-publish the same bytes per
    /// cell. Saves an allocator round-trip per cell per tick.
    wave_payload: []const u8,
    cells: []const CellCoord,
    cell_side_m: f32,
    world_time_s: f64,
) !u64 {
    var count: u64 = 0;
    const t: f32 = @floatCast(world_time_s);
    for (cells) |c| {
        // Sample at the cell's center in world coords.
        const cx_world: f32 = (@as(f32, @floatFromInt(c.x)) + 0.5) * cell_side_m;
        const cz_world: f32 = (@as(f32, @floatFromInt(c.z)) + 0.5) * cell_side_m;
        const w = notatlas.wind_query.windAt(params, cx_world, cz_world, t);

        const msg: wire.WindMsg = .{ .vx = w[0], .vz = w[1] };
        var subj_buf: [64]u8 = undefined;
        const subj = try std.fmt.bufPrint(&subj_buf, "env.cell.{d}_{d}.wind", .{ c.x, c.z });
        const buf = try wire.encodeWind(allocator, msg);
        defer allocator.free(buf);
        try client.publish(subj, buf);
        count += 1;

        const wave_subj = try std.fmt.bufPrint(&subj_buf, "env.cell.{d}_{d}.waves", .{ c.x, c.z });
        try client.publish(wave_subj, wave_payload);
        count += 1;
    }
    return count;
}
