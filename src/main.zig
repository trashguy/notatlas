//! notatlas sandbox entry point. M2.1: opens a window, creates a Vulkan
//! instance/device/queue with validation layers in Debug, prints capabilities,
//! and idles until the window is closed.

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

    while (!window.shouldClose()) {
        render.Window.pollEvents();
    }
}
