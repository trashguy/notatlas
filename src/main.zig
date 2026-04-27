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

const wave_config_path = "data/waves/storm.yaml";
const ocean_config_path = "data/ocean.yaml";
const vert_shader_path = "assets/shaders/fullscreen.vert";
const frag_shader_path = "assets/shaders/water.frag";

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var window = try render.Window.init(.{});
    defer window.deinit();

    var gpu = try render.GpuContext.init(gpa, &window, .{});
    defer gpu.deinit();
    gpu.printCapabilities();

    var swapchain = try render.Swapchain.init(gpa, &gpu, window.framebufferSize(), .{});
    defer swapchain.deinit();

    var frame = try render.Frame.init(gpa, &gpu, &swapchain);
    defer frame.deinit();

    var ocean = try render.Ocean.init(gpa, &gpu, frame.render_pass, .{});
    defer ocean.deinit();

    const wave_params = try loadWaves(gpa, wave_config_path);
    ocean.setWaveParams(wave_params);

    const ocean_params = try loadOcean(gpa, ocean_config_path);
    ocean.setOceanParams(ocean_params);

    var watcher = try render.file_watch.Watcher.init(.{
        .wave_basename = std.fs.path.basename(wave_config_path),
    });
    defer watcher.deinit();
    std.log.info("hot-reload watching {s}, {s}, assets/shaders/*", .{
        ocean_config_path,
        wave_config_path,
    });

    var timer = try std.time.Timer.start();
    var t: f32 = 0.0;

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
        if (events.any()) handleReload(gpa, &ocean, frame.render_pass, events);

        const dt: f32 = @as(f32, @floatFromInt(timer.lap())) / @as(f32, std.time.ns_per_s);
        t += dt;

        // Orbit at 80m radius, half a turn per 16 seconds. Altitude bobs
        // between -8m and +20m so a stretch of every orbit is below the
        // waterline — exercises the underwater fog path without input.
        const radius: f32 = 80.0;
        const angle = t * (std.math.tau / 16.0);
        const altitude: f32 = 6.0 + 14.0 * @sin(angle);
        const camera: render.Camera = .{
            .eye = notatlas.math.Vec3.init(@cos(angle) * radius, altitude, @sin(angle) * radius),
            .target = notatlas.math.Vec3.zero,
            .fov_y = std.math.degreesToRadians(60.0),
            .aspect = @as(f32, @floatFromInt(size[0])) / @as(f32, @floatFromInt(size[1])),
        };
        ocean.updateCamera(camera);
        ocean.updateTime(t);

        const result = try frame.draw(&swapchain, clear, recordOcean, &ocean);
        if (result == .resize_needed) {
            try swapchain.recreate(window.framebufferSize());
            try frame.recreateFramebuffers(&gpu, &swapchain);
        }
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

/// Apply whatever the watcher flagged. Errors are logged and swallowed —
/// a typo in YAML or a broken shader must not kill the running sandbox;
/// the user fixes the file and saves again.
fn handleReload(
    gpa: std.mem.Allocator,
    ocean: *render.Ocean,
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

    if (events.shader) {
        const vert_spv = render.shader_compile.compileGlsl(gpa, vert_shader_path, "fullscreen.vert") catch return;
        defer gpa.free(vert_spv);
        const frag_spv = render.shader_compile.compileGlsl(gpa, frag_shader_path, "water.frag") catch return;
        defer gpa.free(frag_spv);

        ocean.reloadShaders(render_pass, vert_spv, frag_spv) catch |err| {
            std.log.err("reload shaders: {s}", .{@errorName(err)});
            return;
        };
        std.log.info("reload shaders ({d} ms)", .{timer.lap() / std.time.ns_per_ms});
    }
}

fn recordOcean(
    ctx: *anyopaque,
    cb: render.types.vk.VkCommandBuffer,
    extent: render.types.vk.VkExtent2D,
) void {
    const ocean: *render.Ocean = @ptrCast(@alignCast(ctx));
    ocean.record(cb, extent);
}
