//! notatlas sandbox entry point. M2 raymarched water + atmospheric sky.
//! `data/waves/storm.yaml` drives the deterministic wave kernel;
//! `data/ocean.yaml` drives shading/foam/fog. Single-process; no networking.
//!
//! M2.6: data and shader files are watched live. Editing
//! `data/ocean.yaml`, `data/waves/storm.yaml`, or any shader under
//! `assets/shaders/` reloads the relevant resource without restarting.

const std = @import("std");
const notatlas = @import("notatlas");
const render = @import("render/render.zig");
const physics = @import("physics");

const wave_config_path = "data/waves/storm.yaml";
const ocean_config_path = "data/ocean.yaml";
const hull_config_path = "data/ships/box.yaml";
const wind_config_path = "data/wind.yaml";
const arrows_vert_path = "assets/shaders/wind_arrows.vert";
const arrows_frag_path = "assets/shaders/wind_arrows.frag";

/// 16×16 = 256 cells over 800 m centered at origin. Step (50 m) is large
/// enough that arrows of length ARROW_SCALE_M (35 m) don't overlap, small
/// enough that storm gradients (σ=300 m for the storm preset) span ~6 cells.
const arrow_grid_dim: u32 = 16;
const arrow_grid_step_m: f32 = 50.0;
const arrow_count: u32 = arrow_grid_dim * arrow_grid_dim;
const vert_shader_path = "assets/shaders/fullscreen.vert";
const frag_shader_path = "assets/shaders/water.frag";
const box_vert_shader_path = "assets/shaders/box.vert";
const box_frag_shader_path = "assets/shaders/box.frag";

const Scene = struct {
    ocean: *render.Ocean,
    box: *render.Box,
    arrows: *render.WindArrows,
};

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const cli = try parseCli(gpa);

    // RenderDoc must be loaded BEFORE the Vulkan instance is created so its
    // layer can hook the loader. Frame capture happens later, after a brief
    // warmup, so the captured frame is in steady state.
    var capture: ?render.capture.Capture = null;
    defer if (capture) |*c| c.deinit();
    if (cli.capture) {
        try std.fs.cwd().makePath("captures");
        capture = render.capture.Capture.init("captures/notatlas") catch |err| blk: {
            std.log.err("renderdoc init: {s} (continuing without capture)", .{@errorName(err)});
            break :blk null;
        };
    }

    var window = try render.Window.init(.{ .force_x11 = cli.capture });
    defer window.deinit();

    var gpu = try render.GpuContext.init(gpa, &window, .{});
    defer gpu.deinit();
    gpu.printCapabilities();

    // MAILBOX keeps the CPU/GPU loop unthrottled by display refresh
    // while still presenting tearing-free — the right "uncapped" mode
    // on Wayland, which never advertises IMMEDIATE.
    var swapchain = try render.Swapchain.init(gpa, &gpu, window.framebufferSize(), .{
        .present_mode = if (cli.uncap)
            render.types.vk.VK_PRESENT_MODE_MAILBOX_KHR
        else
            render.types.vk.VK_PRESENT_MODE_FIFO_KHR,
    });
    defer swapchain.deinit();

    var frame = try render.Frame.init(gpa, &gpu, &swapchain);
    defer frame.deinit();

    var ocean = try render.Ocean.init(gpa, &gpu, frame.render_pass, .{});
    defer ocean.deinit();

    var box = try render.Box.init(&gpu, frame.render_pass, ocean.camera_ubo.handle);
    defer box.deinit();
    var arrows = try render.WindArrows.init(&gpu, frame.render_pass, ocean.camera_ubo.handle, arrow_count);
    defer arrows.deinit();
    var scene: Scene = .{ .ocean = &ocean, .box = &box, .arrows = &arrows };

    const wave_params = try loadWaves(gpa, wave_config_path);
    ocean.setWaveParams(wave_params);

    const ocean_params = try loadOcean(gpa, ocean_config_path);
    ocean.setOceanParams(ocean_params);

    var watcher = try render.file_watch.Watcher.init(.{
        .wave_basename = std.fs.path.basename(wave_config_path),
        .hull_basename = std.fs.path.basename(hull_config_path),
    });
    defer watcher.deinit();
    std.log.info("hot-reload watching {s}, {s}, {s}, {s}, assets/shaders/*", .{
        ocean_config_path,
        wave_config_path,
        hull_config_path,
        wind_config_path,
    });
    std.log.info("present mode = {s}", .{if (cli.uncap) "MAILBOX (uncapped)" else "FIFO (vsync)"});

    // M3.1 smoke test: drop a 1×1×1 m box from y=20 onto a static floor
    // at y=0. Confirms Jolt FFI works end-to-end — gravity pulls it down,
    // collision halts it, body sleeps. Pose logged ~1 Hz.
    physics.init();
    defer physics.shutdown();
    var phys = try physics.System.init(.{});
    defer phys.deinit();

    // Hull params — half-extents, mass, sample points, drag — all live in
    // data/ships/box.yaml. Hot-reloadable below for buoyancy fields; mass
    // and shape changes still need a restart since Jolt has no recompute-
    // mass-properties path through our wrapper yet.
    var hull = try loadHull(gpa, hull_config_path);
    defer hull.deinit(gpa);

    // Wind field is loaded but not yet driving any forces — sails land
    // in M5. For M4.2 the value is logged ~1 Hz so hot-reload is visible
    // and the YAML→kernel path is exercised on every run.
    var wind_params = try loadWind(gpa, wind_config_path);
    defer wind_params.deinit(gpa);
    logWind(wind_params, 0.0);

    // M3.3: no static floor — the box floats on the wave heightfield,
    // which is the same scalar function the GPU raymarches. Body drops
    // from above SL onto the waves; buoyancy halts the fall. Modest drop
    // height keeps initial KE low so settle is visible.
    const box_id = try phys.createBox(.{
        .half_extents = hull.half_extents,
        .position = .{ 0, 4, 0 },
        .motion = .dynamic,
        .mass_override_kg = hull.mass_kg,
    });
    phys.optimizeBroadPhase();
    var phys_log_accum: f32 = 0;

    var buoy = physics.Buoyancy.init(buoyancyConfigFromHull(hull));

    var timer = try std.time.Timer.start();
    var t: f32 = 0.0;
    var soak_stats: SoakStats = .{};
    var wind_soak: WindSoakStats = .{};

    // 1Hz frame-time HUD for the M2.7 perf gate. Bar is ≤6.7 ms /
    // ≥150 fps on the dev box (RX 9070 XT @ 1280×720). Discard the
    // first frame because it bundles loop-preamble + Vulkan warm-up.
    var perf: PerfWindow = .{};

    // RenderDoc capture: warm up for `capture_warmup_frames` to let pipeline
    // caches settle, then capture exactly one frame and exit. Frame 30 puts
    // the orbit camera at an above-water angle (~9 m altitude), good for
    // inspecting the steady-state water pass.
    const capture_warmup_frames: u32 = 30;
    var frame_index: u32 = 0;
    var capture_done = false;

    // Clear color is irrelevant — the fullscreen water/sky shader paints
    // every pixel.  Keep it black so any unrendered area is obvious.
    const clear: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 };

    while (!window.shouldClose()) {
        render.Window.pollEvents();

        var size = window.framebufferSize();
        while ((size[0] == 0 or size[1] == 0) and !window.shouldClose()) {
            render.Window.waitEvents();
            size = window.framebufferSize();
        }
        if (window.shouldClose()) break;

        const events = watcher.poll();
        if (events.any()) handleReload(gpa, &ocean, &box, &arrows, &hull, &buoy, &wind_params, frame.render_pass, events);

        const frame_ns = timer.lap();
        const dt: f32 = @as(f32, @floatFromInt(frame_ns)) / @as(f32, std.time.ns_per_s);
        t += dt;
        perf.tick(frame_ns);

        // Physics step. Cap at 1/30 s so a hitch on the first frame (or a
        // long capture pause) doesn't tunnel the dynamic box through the
        // floor. Buoyancy applies forces against the same wave kernel the
        // GPU raymarches, then Jolt integrates them.
        const phys_dt = @min(dt, 1.0 / 30.0);
        buoy.step(&phys, box_id, wave_params, t);
        phys.step(phys_dt, 1);
        phys_log_accum += phys_dt;
        if (phys_log_accum >= 1.0) {
            const pos = phys.getPosition(box_id) orelse .{ 0, 0, 0 };
            const vel = phys.getLinearVelocity(box_id) orelse .{ 0, 0, 0 };
            std.log.info("phys: box pos=({d:.2},{d:.2},{d:.2}) vel=({d:.2},{d:.2},{d:.2})", .{
                pos[0], pos[1], pos[2], vel[0], vel[1], vel[2],
            });
            logWind(wind_params, t);
            phys_log_accum = 0;
        }

        // Drive box renderer from current Jolt pose. Mesh is a unit cube;
        // scale by 2× the half-extents from the hull config to recover the
        // 4m cube. Quaternion comes back identity-ish until waves tip it.
        const box_pos = phys.getPosition(box_id) orelse .{ 0, 0, 0 };
        const box_quat = phys.getRotation(box_id) orelse .{ 0, 0, 0, 1 };
        const box_model = notatlas.math.Mat4.trs(
            notatlas.math.Vec3.init(box_pos[0], box_pos[1], box_pos[2]),
            box_quat,
            notatlas.math.Vec3.init(2 * hull.half_extents[0], 2 * hull.half_extents[1], 2 * hull.half_extents[2]),
        );
        box.setModel(box_model.data);

        if (cli.soak_seconds > 0) {
            const lin_v = phys.getLinearVelocity(box_id) orelse .{ 0, 0, 0 };
            const ang_v = phys.getAngularVelocity(box_id) orelse .{ 0, 0, 0 };
            soak_stats.observe(box_pos, lin_v, ang_v);
            if (t >= cli.soak_seconds) break;
        }

        // Orbit at 80m radius, half a turn per 16 seconds. Altitude bobs
        // between 12m and 24m — stays clear of storm-preset peaks (~8m)
        // so the camera never submerges. Look-at the sea surface where
        // the buoyant box bobs.
        const radius: f32 = 80.0;
        const angle = t * (std.math.tau / 16.0);
        const altitude: f32 = 18.0 + 6.0 * @sin(angle);
        const camera: render.Camera = .{
            .eye = notatlas.math.Vec3.init(@cos(angle) * radius, altitude, @sin(angle) * radius),
            .target = notatlas.math.Vec3.zero,
            .fov_y = std.math.degreesToRadians(60.0),
            .aspect = @as(f32, @floatFromInt(size[0])) / @as(f32, @floatFromInt(size[1])),
        };
        ocean.updateCamera(camera);
        ocean.updateTime(t);

        // Sample the wind on the debug grid and push to the arrows
        // instance buffer. 256 windAt() calls / frame; cheap (~0.1 ms).
        var arrow_instances: [arrow_count]render.wind_arrows.ArrowInstance = undefined;
        sampleWindGrid(wind_params, t, &arrow_instances);
        arrows.updateInstances(&arrow_instances);

        if (cli.soak_seconds > 0) wind_soak.observe(wind_params, t, &arrow_instances);

        const capturing_this_frame = capture != null and !capture_done and frame_index == capture_warmup_frames;
        if (capturing_this_frame) capture.?.start();

        const result = try frame.draw(&swapchain, clear, recordScene, &scene);
        if (result == .resize_needed) {
            try swapchain.recreate(window.framebufferSize());
            try frame.recreateFramebuffers(&gpu, &swapchain);
        }

        if (capturing_this_frame) {
            const ok = capture.?.end();
            std.log.info("renderdoc capture {s}; .rdc dropped under captures/", .{
                if (ok) "ok" else "FAILED",
            });
            capture_done = true;
            break;
        }
        frame_index += 1;
    }

    // Drain the GPU before the defer chain destroys descriptor pools,
    // pipelines, and other resources still referenced by the in-flight
    // command buffer. Without this, validation fires
    // VUID-vkDestroyDescriptorPool-descriptorPool-00303 +
    // VUID-vkDestroyPipeline-pipeline-00765 on clean shutdown.
    _ = render.types.vk.vkDeviceWaitIdle(gpu.device);

    if (cli.soak_seconds > 0) {
        soak_stats.report(t);
        wind_soak.report(wind_params, t);
    }
}

fn loadWaves(gpa: std.mem.Allocator, rel_path: []const u8) !notatlas.wave_query.WaveParams {
    const abs = try std.fs.cwd().realpathAlloc(gpa, rel_path);
    defer gpa.free(abs);
    return notatlas.yaml_loader.loadFromFile(gpa, abs);
}

fn loadOcean(gpa: std.mem.Allocator, rel_path: []const u8) !notatlas.ocean_params.OceanParams {
    const abs = try std.fs.cwd().realpathAlloc(gpa, rel_path);
    defer gpa.free(abs);
    return notatlas.yaml_loader.loadOceanFromFile(gpa, abs);
}

fn loadHull(gpa: std.mem.Allocator, rel_path: []const u8) !notatlas.hull_params.HullParams {
    const abs = try std.fs.cwd().realpathAlloc(gpa, rel_path);
    defer gpa.free(abs);
    return notatlas.yaml_loader.loadHullFromFile(gpa, abs);
}

fn loadWind(gpa: std.mem.Allocator, rel_path: []const u8) !notatlas.wind_query.WindParams {
    const abs = try std.fs.cwd().realpathAlloc(gpa, rel_path);
    defer gpa.free(abs);
    return notatlas.yaml_loader.loadWindFromFile(gpa, abs);
}

/// Sample the wind at the origin and log direction + magnitude. Cheap
/// proof-of-life that the YAML→kernel path is wired and that hot-reload
/// updates are taking effect.
fn logWind(p: notatlas.wind_query.WindParams, t: f32) void {
    const w = notatlas.wind_query.windAt(p, 0, 0, t);
    const mag = @sqrt(w[0] * w[0] + w[1] * w[1]);
    std.log.info("wind: ({d:.2},{d:.2}) m/s |{d:.2}| storms={d}", .{
        w[0], w[1], mag, p.storms.len,
    });
}

fn buoyancyConfigFromHull(hull: notatlas.hull_params.HullParams) physics.BuoyancyConfig {
    return .{
        .sample_points = hull.sample_points,
        .cell_half_height = hull.cell_half_height,
        .cell_cross_section = hull.cell_cross_section,
        .drag_per_point = hull.drag_per_point,
    };
}

/// Apply whatever the watcher flagged. Errors are logged and swallowed —
/// a typo in YAML or a broken shader must not kill the running sandbox;
/// the user fixes the file and saves again.
fn handleReload(
    gpa: std.mem.Allocator,
    ocean: *render.Ocean,
    box: *render.Box,
    arrows: *render.WindArrows,
    hull: *notatlas.hull_params.HullParams,
    buoy: *physics.Buoyancy,
    wind_params: *notatlas.wind_query.WindParams,
    render_pass: render.types.vk.VkRenderPass,
    events: render.file_watch.Events,
) void {
    var timer = std.time.Timer.start() catch return;

    if (events.ocean) {
        if (loadOcean(gpa, ocean_config_path)) |p| {
            ocean.setOceanParams(p);
            std.log.info("reload {s} ({d} ms)", .{ ocean_config_path, timer.lap() / std.time.ns_per_ms });
        } else |err| {
            std.log.err("reload {s}: {s}", .{ ocean_config_path, @errorName(err) });
        }
    }

    if (events.wave) {
        if (loadWaves(gpa, wave_config_path)) |p| {
            ocean.setWaveParams(p);
            std.log.info("reload {s} ({d} ms)", .{ wave_config_path, timer.lap() / std.time.ns_per_ms });
        } else |err| {
            std.log.err("reload {s}: {s}", .{ wave_config_path, @errorName(err) });
        }
    }

    // Hull hot-reload only updates buoyancy params + render scale.
    // mass_kg / half_extents changes need a restart — the Jolt body's
    // mass properties and collision shape are baked at create time.
    if (events.hull) {
        if (loadHull(gpa, hull_config_path)) |new_hull| {
            if (new_hull.mass_kg != hull.mass_kg or
                !std.mem.eql(f32, &new_hull.half_extents, &hull.half_extents))
            {
                std.log.warn("hull mass/half_extents changed — restart sandbox to pick up", .{});
            }
            hull.deinit(gpa);
            hull.* = new_hull;
            buoy.cfg = buoyancyConfigFromHull(new_hull);
            std.log.info("reload {s} ({d} ms)", .{ hull_config_path, timer.lap() / std.time.ns_per_ms });
        } else |err| {
            std.log.err("reload {s}: {s}", .{ hull_config_path, @errorName(err) });
        }
    }

    if (events.wind) {
        if (loadWind(gpa, wind_config_path)) |new_params| {
            wind_params.deinit(gpa);
            wind_params.* = new_params;
            std.log.info("reload {s} ({d} ms)", .{ wind_config_path, timer.lap() / std.time.ns_per_ms });
            logWind(new_params, 0.0);
        } else |err| {
            std.log.err("reload {s}: {s}", .{ wind_config_path, @errorName(err) });
        }
    }

    // Watcher emits a single .shader bool — no per-file granularity. Both
    // pipelines recompile on any shader edit. Cheap (~100ms total) and
    // simpler than fan-out per-shader bookkeeping.
    if (events.shader) {
        const vert_spv = render.shader_compile.compileGlsl(gpa, vert_shader_path, "fullscreen.vert") catch return;
        defer gpa.free(vert_spv);
        const frag_spv = render.shader_compile.compileGlsl(gpa, frag_shader_path, "water.frag") catch return;
        defer gpa.free(frag_spv);
        ocean.reloadShaders(render_pass, vert_spv, frag_spv) catch |err| {
            std.log.err("reload water shaders: {s}", .{@errorName(err)});
            return;
        };

        const box_vert_spv = render.shader_compile.compileGlsl(gpa, box_vert_shader_path, "box.vert") catch return;
        defer gpa.free(box_vert_spv);
        const box_frag_spv = render.shader_compile.compileGlsl(gpa, box_frag_shader_path, "box.frag") catch return;
        defer gpa.free(box_frag_spv);
        box.reloadShaders(render_pass, box_vert_spv, box_frag_spv) catch |err| {
            std.log.err("reload box shaders: {s}", .{@errorName(err)});
            return;
        };

        const arrows_vert_spv = render.shader_compile.compileGlsl(gpa, arrows_vert_path, "wind_arrows.vert") catch return;
        defer gpa.free(arrows_vert_spv);
        const arrows_frag_spv = render.shader_compile.compileGlsl(gpa, arrows_frag_path, "wind_arrows.frag") catch return;
        defer gpa.free(arrows_frag_spv);
        arrows.reloadShaders(render_pass, arrows_vert_spv, arrows_frag_spv) catch |err| {
            std.log.err("reload wind_arrows shaders: {s}", .{@errorName(err)});
            return;
        };

        std.log.info("reload shaders ({d} ms)", .{timer.lap() / std.time.ns_per_ms});
    }
}

fn recordScene(
    ctx: *anyopaque,
    cb: render.types.vk.VkCommandBuffer,
    extent: render.types.vk.VkExtent2D,
) void {
    const scene: *Scene = @ptrCast(@alignCast(ctx));
    scene.ocean.record(cb, extent);
    scene.box.record(cb, extent);
    scene.arrows.record(cb, extent);
}

/// Fill `out` with `arrow_grid_dim²` windAt samples on a centered grid.
fn sampleWindGrid(
    wind_params: notatlas.wind_query.WindParams,
    t: f32,
    out: *[arrow_count]render.wind_arrows.ArrowInstance,
) void {
    const half: f32 = 0.5 * @as(f32, @floatFromInt(arrow_grid_dim - 1)) * arrow_grid_step_m;
    var idx: usize = 0;
    var i: u32 = 0;
    while (i < arrow_grid_dim) : (i += 1) {
        const x = -half + @as(f32, @floatFromInt(i)) * arrow_grid_step_m;
        var j: u32 = 0;
        while (j < arrow_grid_dim) : (j += 1) {
            const z = -half + @as(f32, @floatFromInt(j)) * arrow_grid_step_m;
            const w = notatlas.wind_query.windAt(wind_params, x, z, t);
            out[idx] = .{ .pos_xz = .{ x, z }, .wind_xz = w };
            idx += 1;
        }
    }
}

const Cli = struct {
    uncap: bool = false,
    capture: bool = false,
    /// Run the loop for this many seconds with pose telemetry accumulated,
    /// then print stats and exit. 0 = normal interactive run.
    soak_seconds: f32 = 0,
};

fn parseCli(gpa: std.mem.Allocator) !Cli {
    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();
    _ = args.next(); // skip exe name
    var cli: Cli = .{};
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--uncap")) {
            cli.uncap = true;
        } else if (std.mem.eql(u8, a, "--capture")) {
            cli.capture = true;
        } else if (std.mem.eql(u8, a, "--soak")) {
            const v = args.next() orelse return error.MissingSoakValue;
            cli.soak_seconds = try std.fmt.parseFloat(f32, v);
        }
    }
    return cli;
}

/// Per-frame pose telemetry for the M3.5 stability gate. Tracks running
/// extrema and counts NaN appearances; bounded numbers across a 5-min run
/// are the gate.
const SoakStats = struct {
    samples: u64 = 0,
    nan_count: u64 = 0,

    pos_min: [3]f32 = .{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) },
    pos_max: [3]f32 = .{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) },
    speed_max: f32 = 0,
    angvel_max: f32 = 0,

    fn observe(self: *SoakStats, pos: [3]f32, lin_v: [3]f32, ang_v: [3]f32) void {
        self.samples += 1;
        for (pos) |c| if (std.math.isNan(c)) {
            self.nan_count += 1;
            return;
        };
        for (lin_v) |c| if (std.math.isNan(c)) {
            self.nan_count += 1;
            return;
        };
        for (ang_v) |c| if (std.math.isNan(c)) {
            self.nan_count += 1;
            return;
        };
        for (0..3) |i| {
            if (pos[i] < self.pos_min[i]) self.pos_min[i] = pos[i];
            if (pos[i] > self.pos_max[i]) self.pos_max[i] = pos[i];
        }
        const speed = @sqrt(lin_v[0] * lin_v[0] + lin_v[1] * lin_v[1] + lin_v[2] * lin_v[2]);
        const angsp = @sqrt(ang_v[0] * ang_v[0] + ang_v[1] * ang_v[1] + ang_v[2] * ang_v[2]);
        if (speed > self.speed_max) self.speed_max = speed;
        if (angsp > self.angvel_max) self.angvel_max = angsp;
    }

    fn report(self: SoakStats, duration_s: f32) void {
        std.log.info(
            \\soak: {d:.1}s, {d} samples, {d} NaN
            \\  pos x: [{d:.2}, {d:.2}]
            \\  pos y: [{d:.2}, {d:.2}]
            \\  pos z: [{d:.2}, {d:.2}]
            \\  max |lin v|: {d:.2} m/s
            \\  max |ang v|: {d:.2} rad/s
        , .{
            duration_s,           self.samples,
            self.nan_count,
            self.pos_min[0],      self.pos_max[0],
            self.pos_min[1],      self.pos_max[1],
            self.pos_min[2],      self.pos_max[2],
            self.speed_max,
            self.angvel_max,
        });
    }
};

/// M4.4 stability gate for the wind field. Observes the same 16×16 grid
/// that the arrows renderer is already filling each frame, plus the per-
/// storm centers (via `stormCenter`), and reports aggregate stats at the
/// end of the soak.
///
/// Pass criteria (informal — the user reads the log):
///   - `nan_count` is 0
///   - `mag_max` ≤ `base_speed_mps + Σ strength_mps` × small slack
///   - For each storm: `path_length` ≈ `speed_mps × duration` (within ~1%
///     for wrap-free runs; per-frame steps small relative to that average)
///   - `max_step` ≪ world size — no teleports / wrap discontinuities slip
///     through the wrap-aware delta
const max_tracked_storms: usize = 8;
const WindSoakStats = struct {
    samples: u64 = 0,
    nan_count: u64 = 0,
    mag_min: f32 = std.math.floatMax(f32),
    mag_max: f32 = -std.math.floatMax(f32),

    storm_count: u32 = 0,
    storm_first_center: [max_tracked_storms][2]f32 = .{.{ 0, 0 }} ** max_tracked_storms,
    storm_last_center: [max_tracked_storms][2]f32 = .{.{ 0, 0 }} ** max_tracked_storms,
    storm_max_step: [max_tracked_storms]f32 = .{0} ** max_tracked_storms,
    storm_path_length: [max_tracked_storms]f32 = .{0} ** max_tracked_storms,

    fn observe(
        self: *WindSoakStats,
        p: notatlas.wind_query.WindParams,
        t: f32,
        grid: []const render.wind_arrows.ArrowInstance,
    ) void {
        const first = self.samples == 0;
        if (first) self.storm_count = @intCast(@min(p.storms.len, max_tracked_storms));

        for (grid) |inst| {
            self.samples += 1;
            const wx = inst.wind_xz[0];
            const wz = inst.wind_xz[1];
            if (std.math.isNan(wx) or std.math.isNan(wz)) {
                self.nan_count += 1;
                continue;
            }
            const m = @sqrt(wx * wx + wz * wz);
            if (m < self.mag_min) self.mag_min = m;
            if (m > self.mag_max) self.mag_max = m;
        }

        const half = p.storm_world_m * 0.5;
        var i: usize = 0;
        while (i < self.storm_count) : (i += 1) {
            const c = notatlas.wind_query.stormCenter(p, i, t);
            if (first) {
                self.storm_first_center[i] = c;
                self.storm_last_center[i] = c;
                continue;
            }
            const last = self.storm_last_center[i];
            // Wrap-aware delta — when a storm crosses the world edge the
            // raw c-last jump looks like ±world_m; subtracting the world
            // size folds it back to the true short-path step.
            var dx = c[0] - last[0];
            var dz = c[1] - last[1];
            if (dx > half) dx -= p.storm_world_m;
            if (dx < -half) dx += p.storm_world_m;
            if (dz > half) dz -= p.storm_world_m;
            if (dz < -half) dz += p.storm_world_m;
            const step = @sqrt(dx * dx + dz * dz);
            if (step > self.storm_max_step[i]) self.storm_max_step[i] = step;
            self.storm_path_length[i] += step;
            self.storm_last_center[i] = c;
        }
    }

    fn report(self: WindSoakStats, p: notatlas.wind_query.WindParams, duration_s: f32) void {
        std.log.info(
            \\wind soak: {d:.1}s, {d} samples, {d} NaN
            \\  mag range: [{d:.3}, {d:.3}] m/s
            \\  storms tracked: {d}/{d}
        , .{
            duration_s,    self.samples,
            self.nan_count, self.mag_min,
            self.mag_max,   self.storm_count,
            p.storms.len,
        });
        var i: usize = 0;
        while (i < self.storm_count) : (i += 1) {
            const expected = p.storms[i].speed_mps * duration_s;
            std.log.info("  storm[{d}]: path={d:.1} m, max-step={d:.4} m, expected drift={d:.1} m", .{
                i, self.storm_path_length[i], self.storm_max_step[i], expected,
            });
        }
    }
};

const PerfWindow = struct {
    accum_ns: u64 = 0,
    frames: u32 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
    accum_dt: f32 = 0,
    skip_first: bool = true,

    /// Roll a frame-time sample into the 1-second window. Logs and
    /// resets when the window closes. `frame_ns` includes the entire
    /// CPU loop iteration — pollEvents, watcher poll, draw record +
    /// submit, present — which is what the gate cares about.
    fn tick(self: *PerfWindow, frame_ns: u64) void {
        if (self.skip_first) {
            self.skip_first = false;
            return;
        }
        self.accum_ns += frame_ns;
        self.frames += 1;
        if (frame_ns < self.min_ns) self.min_ns = frame_ns;
        if (frame_ns > self.max_ns) self.max_ns = frame_ns;
        self.accum_dt += @as(f32, @floatFromInt(frame_ns)) / @as(f32, std.time.ns_per_s);
        if (self.accum_dt >= 1.0) {
            const avg_ns = self.accum_ns / self.frames;
            std.log.info("perf: avg {d:.2} ms / min {d:.2} ms / max {d:.2} ms ({d} fps)", .{
                @as(f64, @floatFromInt(avg_ns)) / 1.0e6,
                @as(f64, @floatFromInt(self.min_ns)) / 1.0e6,
                @as(f64, @floatFromInt(self.max_ns)) / 1.0e6,
                std.time.ns_per_s / avg_ns,
            });
            self.accum_ns = 0;
            self.frames = 0;
            self.min_ns = std.math.maxInt(u64);
            self.max_ns = 0;
            self.accum_dt = 0;
        }
    }
};
