//! notatlas sandbox entry point. M2 raymarched water + atmospheric sky.
//! `data/waves/storm.yaml` drives the deterministic wave kernel;
//! `data/ocean.yaml` drives shading/foam/fog. Single-process; no networking.

const std = @import("std");
const notatlas = @import("notatlas");
const render = @import("render/render.zig");

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

    const wave_params = try loadWaves(gpa, "data/waves/storm.yaml");
    ocean.setWaveParams(wave_params);

    const ocean_params = try loadOcean(gpa, "data/ocean.yaml");
    ocean.setOceanParams(ocean_params);

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

fn recordOcean(
    ctx: *anyopaque,
    cb: render.types.vk.VkCommandBuffer,
    extent: render.types.vk.VkExtent2D,
) void {
    const ocean: *render.Ocean = @ptrCast(@alignCast(ctx));
    ocean.record(cb, extent);
}
