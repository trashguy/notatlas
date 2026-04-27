//! notatlas sandbox entry point. M2.3: an XZ tessellated plane drawn by
//! the ocean pass with an orbiting flying camera. Single-process; no
//! networking.

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

    var ocean = try render.Ocean.init(gpa, &gpu, frame.render_pass, .{
        .plane_resolution = 128,
        .plane_size_m = 256.0,
    });
    defer ocean.deinit();

    var timer = try std.time.Timer.start();
    var t: f32 = 0.0;

    // Sky-ish background; the ocean fragment shader paints over the
    // visible portion of the framebuffer.
    const clear: [4]f32 = .{ 0.55, 0.70, 0.85, 1.0 };

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

        // Orbit the origin at 60m radius, 25m altitude, half a turn per
        // 12 seconds. Lets us see the plane stretch into the distance
        // and confirm the perspective is sane.
        const radius: f32 = 60.0;
        const altitude: f32 = 25.0;
        const angle = t * (std.math.tau / 12.0);
        const camera: render.Camera = .{
            .eye = notatlas.math.Vec3.init(@cos(angle) * radius, altitude, @sin(angle) * radius),
            .target = notatlas.math.Vec3.zero,
            .fov_y = std.math.degreesToRadians(60.0),
            .aspect = @as(f32, @floatFromInt(size[0])) / @as(f32, @floatFromInt(size[1])),
        };
        ocean.updateCamera(camera);

        const result = try frame.draw(&swapchain, clear, recordOcean, &ocean);
        if (result == .resize_needed) {
            try swapchain.recreate(window.framebufferSize());
            try frame.recreateFramebuffers(&swapchain);
        }
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
