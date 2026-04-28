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
const zglfw = @import("zglfw");

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

    // M5.1: physics runs at the locked 60Hz auth tick; render is uncapped.
    // We accumulate frame dt and step Jolt in fixed 1/60 s chunks. Each tick
    // snapshots the prior pose so the render frame can lerp/slerp between
    // (prev, curr) by `alpha = phys_accum / phys_dt_fixed`. The same
    // interpolation pattern carries forward to M5.3 where the passenger
    // composes against the *interpolated* ship pose — without it, a 144Hz
    // first-person camera on a 60Hz pitching deck shows visible jitter.
    //
    // `phys_t` is the simulation clock (advances by exactly phys_dt per step,
    // monotonic, identical run-to-run for a fixed soak duration). Wave queries
    // inside buoyancy use phys_t so successive ticks integrate against a
    // self-consistent height field. Camera, ocean shader time, and the
    // wind-arrow viz keep using the render-time `t` — they're cosmetic and
    // don't need bit-identical reproducibility.
    const phys_dt_fixed: f32 = 1.0 / 60.0;
    const max_steps_per_frame: u32 = 5;
    var phys_accum: f32 = 0;
    var phys_t: f32 = 0;
    var pose_prev_pos: [3]f32 = phys.getPosition(box_id) orelse .{ 0, 4, 0 };
    var pose_prev_rot: [4]f32 = phys.getRotation(box_id) orelse .{ 0, 0, 0, 1 };
    var pose_curr_pos: [3]f32 = pose_prev_pos;
    var pose_curr_rot: [4]f32 = pose_prev_rot;

    // M5.3 player. Spawn pre-boarded on top of the box: feet at local
    // y = +half_extents.y (deck surface), eye at +eye_height above. Yaw=0
    // looks down local -Z; the orbit-cam-era box position (0, 4, 0) puts
    // the bow toward -Z, so this faces "forward over the prow." When the
    // box pitches, the camera rolls with the deck because the world
    // composition rotates the local eye+forward by `ship_pose.rot`.
    //
    // attached_ship uses the Jolt BodyId since we have one ship and that's
    // the natural opaque handle. M5.5 multi-pax will need a registry layer
    // mapping ship handles to interpolated pose providers.
    var player: notatlas.player.Player = .{
        .pos = notatlas.math.Vec3.init(0, hull.half_extents[1], 0),
    };
    player.boardShip(box_id, player.pos);
    var last_cursor: ?[2]f64 = null;
    var cursor_captured: bool = false;
    // Capture the cursor at startup so mouse-look works from the first frame.
    // `.disabled` mode hides the cursor and reports unbounded virtual
    // positions — the FPS standard. Esc releases, left-click recaptures.
    if (!cli.capture and cli.soak_seconds == 0) {
        zglfw.setInputMode(window.handle, .cursor, .disabled) catch {};
        cursor_captured = true;
    }

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

        // Fixed-step physics. Owe `phys_accum` seconds of sim; consume in
        // exact 1/60 s chunks. `max_steps_per_frame` caps runaway: if the
        // sandbox stalls (RenderDoc capture pause, breakpoint), we'd
        // otherwise try to catch up by running hundreds of physics ticks
        // in one frame and tunneling through wave gradients. Better to
        // drop the residual and let the sim slow down briefly than to
        // explode the box.
        phys_accum += dt;
        var steps: u32 = 0;
        while (phys_accum >= phys_dt_fixed and steps < max_steps_per_frame) : (steps += 1) {
            pose_prev_pos = pose_curr_pos;
            pose_prev_rot = pose_curr_rot;
            buoy.step(&phys, box_id, wave_params, phys_t);
            phys.step(phys_dt_fixed, 1);
            phys_t += phys_dt_fixed;
            pose_curr_pos = phys.getPosition(box_id) orelse pose_curr_pos;
            pose_curr_rot = phys.getRotation(box_id) orelse pose_curr_rot;

            // Per-tick soak observations — uniform 1/60 s sampling, identical
            // to the rate the integrator actually steps at. Replaces the
            // pre-M5.1 per-render-frame sampling which redundantly observed
            // the same Jolt state ~15× per tick at uncapped framerates.
            if (cli.soak_seconds > 0) {
                const lin_v = phys.getLinearVelocity(box_id) orelse .{ 0, 0, 0 };
                const ang_v = phys.getAngularVelocity(box_id) orelse .{ 0, 0, 0 };
                soak_stats.observe(pose_curr_pos, lin_v, ang_v);
                wind_soak.observe(wind_params, phys_t);
            }
            phys_accum -= phys_dt_fixed;
        }
        if (steps == max_steps_per_frame and phys_accum >= phys_dt_fixed) {
            phys_accum = 0;
        }

        phys_log_accum += dt;
        if (phys_log_accum >= 1.0) {
            const vel = phys.getLinearVelocity(box_id) orelse .{ 0, 0, 0 };
            std.log.info("phys: box pos=({d:.2},{d:.2},{d:.2}) vel=({d:.2},{d:.2},{d:.2})", .{
                pose_curr_pos[0], pose_curr_pos[1], pose_curr_pos[2], vel[0], vel[1], vel[2],
            });
            logWind(wind_params, t);
            phys_log_accum = 0;
        }

        // Render the box at the interpolated pose between the two most recent
        // physics ticks. `alpha ∈ [0, 1]` is the fractional position into the
        // next tick; at exactly the tick boundary alpha=0 and we render the
        // last completed pose.
        const alpha: f32 = std.math.clamp(phys_accum / phys_dt_fixed, 0.0, 1.0);
        const render_pos = notatlas.math.Vec3.init(
            pose_prev_pos[0] + (pose_curr_pos[0] - pose_prev_pos[0]) * alpha,
            pose_prev_pos[1] + (pose_curr_pos[1] - pose_prev_pos[1]) * alpha,
            pose_prev_pos[2] + (pose_curr_pos[2] - pose_prev_pos[2]) * alpha,
        );
        const render_rot = notatlas.math.quatSlerp(pose_prev_rot, pose_curr_rot, alpha);
        const box_model = notatlas.math.Mat4.trs(
            render_pos,
            render_rot,
            notatlas.math.Vec3.init(2 * hull.half_extents[0], 2 * hull.half_extents[1], 2 * hull.half_extents[2]),
        );
        box.setModel(box_model.data);

        if (cli.soak_seconds > 0 and t >= cli.soak_seconds) break;

        // M5.2 input. Mouse delta drives yaw/pitch (only while captured);
        // WASD + Space/Ctrl drive position. Esc releases the cursor (so the
        // window is dismissable); left-click re-captures. We re-poll cursor
        // position every frame regardless of capture state so re-capturing
        // doesn't snap the view by the cursor's drift while released.
        const cursor = window.handle.getCursorPos();
        if (cursor_captured) {
            if (last_cursor) |lc| {
                const dx: f32 = @floatCast(cursor[0] - lc[0]);
                const dy: f32 = @floatCast(cursor[1] - lc[1]);
                player.applyMouseDelta(dx, dy);
            }
            const move = pollMove(&window);
            player.applyMove(move, dt);
            // M5.4: pin to deck plane. Without this, walking off the edge
            // floats you in local-space air; Space/Ctrl would lift you off
            // the deck. Inset 0.3 m keeps the eye off the deck-edge corner
            // (the box's exact edge would clip the camera into nothing).
            player.clampToDeck(
                hull.half_extents[1],
                hull.half_extents[0],
                hull.half_extents[2],
                0.3,
            );
        }
        last_cursor = cursor;
        if (cursor_captured and window.handle.getKey(.escape) == .press) {
            zglfw.setInputMode(window.handle, .cursor, .normal) catch {};
            cursor_captured = false;
            last_cursor = null;
        } else if (!cursor_captured and window.handle.getMouseButton(.left) == .press) {
            zglfw.setInputMode(window.handle, .cursor, .disabled) catch {};
            cursor_captured = true;
            last_cursor = null;
        }

        // M5.3 SoT-style world camera composition. Pass the *interpolated*
        // ship pose (M5.1) so the camera stays smooth at high render rates;
        // the player's local fields are static between input ticks, so any
        // visible jitter on a pitching deck would have to come from the
        // ship pose source. Standing still + watching the deck rock is the
        // M5.3 headline gate.
        const ship_pose: notatlas.player.Pose = .{ .pos = render_pos, .rot = render_rot };
        const world_eye = player.worldEye(ship_pose);
        const world_fwd = player.worldForward(ship_pose);
        const camera: render.Camera = .{
            .eye = world_eye,
            .target = notatlas.math.Vec3.add(world_eye, world_fwd),
            .fov_y = player.fov_y,
            .aspect = @as(f32, @floatFromInt(size[0])) / @as(f32, @floatFromInt(size[1])),
        };
        ocean.updateCamera(camera);
        ocean.updateTime(t);

        // Sample the wind on the debug grid and push to the arrows
        // instance buffer. 256 windAt() calls / frame; cheap (~0.1 ms).
        var arrow_instances: [arrow_count]render.wind_arrows.ArrowInstance = undefined;
        sampleWindGrid(wind_params, t, &arrow_instances);
        arrows.updateInstances(&arrow_instances);

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

/// Snapshot WASD / Space / Ctrl into a FlyCamera move vector. Each axis is
/// the difference of two boolean keys, so chord cancellation works the same
/// as any FPS (W+S = 0, A+D = 0). Diagonal (W+D) is unnormalized — gives
/// the classic √2× bonus on diagonals; not worth normalizing for sandbox.
fn pollMove(window: *render.Window) notatlas.player.Move {
    const fw: f32 = if (window.handle.getKey(.w) == .press) 1 else 0;
    const bw: f32 = if (window.handle.getKey(.s) == .press) 1 else 0;
    const lf: f32 = if (window.handle.getKey(.a) == .press) 1 else 0;
    const rt: f32 = if (window.handle.getKey(.d) == .press) 1 else 0;
    const up: f32 = if (window.handle.getKey(.space) == .press) 1 else 0;
    const dn: f32 = if (window.handle.getKey(.left_control) == .press) 1 else 0;
    return .{ .forward = fw - bw, .strafe = rt - lf, .up = up - dn };
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

/// M4.4 stability gate for the wind field. Each tick: samples a 16×16 grid
/// covering the entire toroidal storm world (so the σ rings are periodically
/// intersected as storms drift) and probes each storm's eye directly (so
/// peak / anti-peak magnitudes show up in the range regardless of where
/// storms happen to be). Tracks per-storm wrap-aware path length to verify
/// `stormCenter` translates linearly. Reports aggregate stats at end.
///
/// The renderer's arrow grid is intentionally NOT reused: it's centered on
/// the box at ±375 m, which on a 4096 m storm world rarely overlaps any
/// storm and would understate the magnitude range. The soak's job is to
/// verify the kernel globally, not to mirror what the camera sees.
///
/// Pass criteria (informal — the user reads the log):
///   - `nan_count` is 0
///   - `mag_max` close to the analytic upper bound
///     `base_speed_mps + max strength_mps` (depends on storm alignment;
///     for the storm preset, ~22 m/s is achievable when a storm's gust
///     aligns with the base wind direction at some moment)
///   - For each storm: `path_length` ≈ `speed_mps × duration` (within
///     a fraction of a meter over 5 min)
///   - `max_step` ≪ world size — no teleports / wrap discontinuities slip
///     through the wrap-aware delta
const max_tracked_storms: usize = 8;
const wind_soak_grid_dim: u32 = 16;

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

    fn observeMag(self: *WindSoakStats, w: [2]f32) void {
        self.samples += 1;
        if (std.math.isNan(w[0]) or std.math.isNan(w[1])) {
            self.nan_count += 1;
            return;
        }
        const m = @sqrt(w[0] * w[0] + w[1] * w[1]);
        if (m < self.mag_min) self.mag_min = m;
        if (m > self.mag_max) self.mag_max = m;
    }

    fn observe(self: *WindSoakStats, p: notatlas.wind_query.WindParams, t: f32) void {
        const first = self.samples == 0;
        if (first) self.storm_count = @intCast(@min(p.storms.len, max_tracked_storms));

        // Wide grid — covers the full storm world. Step ≈ world / 16 ≈ 256 m
        // for the 4096 m default, slightly under σ=300 m, so as storms drift
        // the grid passes through their σ rings and we observe peak magnitudes
        // every few seconds.
        const half = p.storm_world_m * 0.5;
        const step = p.storm_world_m / @as(f32, @floatFromInt(wind_soak_grid_dim));
        var i: u32 = 0;
        while (i < wind_soak_grid_dim) : (i += 1) {
            const x = -half + (@as(f32, @floatFromInt(i)) + 0.5) * step;
            var j: u32 = 0;
            while (j < wind_soak_grid_dim) : (j += 1) {
                const z = -half + (@as(f32, @floatFromInt(j)) + 0.5) * step;
                const w = notatlas.wind_query.windAt(p, x, z, t);
                self.observeMag(w);
            }
        }

        // Probe each storm's eye directly — guarantees peak / anti-peak
        // contribution shows up in the magnitude range every frame.
        var s: usize = 0;
        while (s < self.storm_count) : (s += 1) {
            const c = notatlas.wind_query.stormCenter(p, s, t);
            const w_eye = notatlas.wind_query.windAt(p, c[0], c[1], t);
            self.observeMag(w_eye);

            if (first) {
                self.storm_first_center[s] = c;
                self.storm_last_center[s] = c;
                continue;
            }
            const last = self.storm_last_center[s];
            // Wrap-aware delta — when a storm crosses the world edge the
            // raw c-last jump looks like ±world_m; subtracting the world
            // size folds it back to the true short-path step.
            var dx = c[0] - last[0];
            var dz = c[1] - last[1];
            if (dx > half) dx -= p.storm_world_m;
            if (dx < -half) dx += p.storm_world_m;
            if (dz > half) dz -= p.storm_world_m;
            if (dz < -half) dz += p.storm_world_m;
            const step_dist = @sqrt(dx * dx + dz * dz);
            if (step_dist > self.storm_max_step[s]) self.storm_max_step[s] = step_dist;
            self.storm_path_length[s] += step_dist;
            self.storm_last_center[s] = c;
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
