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
    /// Force GLFW onto the X11 backend (via XWayland on Wayland sessions).
    /// The RenderDoc Vulkan layer doesn't support `VK_KHR_wayland_surface`,
    /// and `glfwGetRequiredInstanceExtensions` returns APIUnavailable when
    /// the layer is loaded on a Wayland-backed window — XWayland is the
    /// supported escape hatch.
    force_x11: bool = false,
};

// glfw constants for the platform init hint. These are stable in upstream
// GLFW and not directly re-exported by zglfw, so we hard-code the value
// rather than thread a wrapper through.
const GLFW_PLATFORM_X11: c_int = 0x00060004;

pub const Window = struct {
    handle: *zglfw.Window,

    pub fn init(cfg: Config) WindowError!Window {
        if (cfg.force_x11) zglfw.initHint(.platform, GLFW_PLATFORM_X11) catch {};
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

    pub fn waitEvents() void {
        zglfw.waitEvents();
    }

    pub fn framebufferSize(self: *Window) [2]u32 {
        const sz = self.handle.getFramebufferSize();
        return .{ @intCast(sz[0]), @intCast(sz[1]) };
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
