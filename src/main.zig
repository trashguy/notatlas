//! notatlas sandbox entry point. M2.2: opens a window, brings up the
//! Vulkan device + swapchain, and renders an animated clear-to-color in
//! a frame loop until the window is closed. Resize is handled by
//! recreating the swapchain + framebuffers on OUT_OF_DATE / SUBOPTIMAL.

const std = @import("std");
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

    var timer = try std.time.Timer.start();
    var t: f32 = 0.0;

    while (!window.shouldClose()) {
        render.Window.pollEvents();

        // Sleep while minimized; redrawing a 0-extent swapchain is invalid.
        var size = window.framebufferSize();
        while ((size[0] == 0 or size[1] == 0) and !window.shouldClose()) {
            render.Window.waitEvents();
            size = window.framebufferSize();
        }
        if (window.shouldClose()) break;

        const dt: f32 = @as(f32, @floatFromInt(timer.lap())) / @as(f32, std.time.ns_per_s);
        t += dt;

        const clear = [4]f32{
            0.5 + 0.5 * @sin(t * 0.7),
            0.5 + 0.5 * @sin(t * 1.1 + 2.0),
            0.5 + 0.5 * @sin(t * 1.3 + 4.0),
            1.0,
        };

        const result = try frame.draw(&swapchain, clear);
        if (result == .resize_needed) {
            try swapchain.recreate(window.framebufferSize());
            try frame.recreateFramebuffers(&swapchain);
        }
    }
}
