//! GLFW window wrapper. Owns the GLFW global init/terminate lifecycle.

const std = @import("std");
const zglfw = @import("zglfw");
const types = @import("vulkan_types.zig");
const vk = types.vk;

pub const WindowError = error{
    GlfwInitFailed,
    VulkanUnsupported,
    WindowCreateFailed,
    SurfaceCreationFailed,
};

pub const Config = struct {
    width: i32 = 1280,
    height: i32 = 720,
    title: [:0]const u8 = "notatlas sandbox",
    resizable: bool = true,
};

pub const Window = struct {
    handle: *zglfw.Window,

    pub fn init(cfg: Config) WindowError!Window {
        zglfw.init() catch return error.GlfwInitFailed;
        errdefer zglfw.terminate();

        if (!zglfw.isVulkanSupported()) return error.VulkanUnsupported;

        zglfw.windowHint(.client_api, .no_api);
        zglfw.windowHint(.resizable, cfg.resizable);
        zglfw.windowHint(.visible, true);

        const handle = zglfw.createWindow(cfg.width, cfg.height, cfg.title, null, null) catch
            return error.WindowCreateFailed;
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Window) void {
        zglfw.destroyWindow(self.handle);
        zglfw.terminate();
    }

    pub fn shouldClose(self: *Window) bool {
        return zglfw.windowShouldClose(self.handle);
    }

    pub fn pollEvents() void {
        zglfw.pollEvents();
    }

    /// Vulkan instance extensions GLFW needs for surface support.
    pub fn requiredInstanceExtensions() ![][*:0]const u8 {
        return zglfw.getRequiredInstanceExtensions();
    }

    pub fn createSurface(self: *Window, instance: vk.VkInstance) WindowError!vk.VkSurfaceKHR {
        var surface: vk.VkSurfaceKHR = undefined;
        zglfw.createWindowSurface(
            @ptrCast(instance),
            self.handle,
            null,
            @ptrCast(&surface),
        ) catch return error.SurfaceCreationFailed;
        return surface;
    }
};
