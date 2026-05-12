//! Vulkan instance/device/queue creation, validation layers, and capability print.
//!
//! Validation layers are enabled in Debug builds when `VK_LAYER_KHRONOS_validation`
//! is present on the system; if it's missing we skip with a warning and keep going.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("vulkan_types.zig");
const window_mod = @import("window.zig");

const vk = types.vk;
const VulkanError = types.VulkanError;
const QueueFamilies = types.QueueFamilies;

pub const validation_enabled_default: bool = builtin.mode == .Debug;
const validation_layer_name: [*:0]const u8 = "VK_LAYER_KHRONOS_validation";

pub const Config = struct {
    enable_validation: bool = validation_enabled_default,
    app_name: [:0]const u8 = "notatlas",
};

pub const GpuContext = struct {
    instance: vk.VkInstance,
    debug_messenger: vk.VkDebugUtilsMessengerEXT, // null when validation disabled
    surface: vk.VkSurfaceKHR,
    physical_device: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    graphics_queue: vk.VkQueue,
    present_queue: vk.VkQueue,
    families: QueueFamilies,
    validation_active: bool,

    pub fn init(
        gpa: std.mem.Allocator,
        window: *window_mod.Window,
        cfg: Config,
    ) !GpuContext {
        const validation_active = cfg.enable_validation and try validationLayerAvailable(gpa);
        if (cfg.enable_validation and !validation_active) {
            std.debug.print(
                "[warn] validation layers requested but '{s}' not available; continuing without\n",
                .{validation_layer_name},
            );
        }

        const instance = try createInstance(gpa, cfg.app_name, validation_active);
        errdefer vk.vkDestroyInstance(instance, null);

        const debug_messenger = if (validation_active)
            try createDebugMessenger(instance)
        else
            null;
        errdefer if (validation_active) destroyDebugMessenger(instance, debug_messenger);

        const surface = try window.createSurface(instance);
        errdefer vk.vkDestroySurfaceKHR(instance, surface, null);

        const physical_device = try pickPhysicalDevice(gpa, instance, surface);
        const families = try findQueueFamilies(gpa, physical_device, surface);

        const device_result = try createLogicalDevice(physical_device, families);

        return .{
            .instance = instance,
            .debug_messenger = debug_messenger,
            .surface = surface,
            .physical_device = physical_device,
            .device = device_result.device,
            .graphics_queue = device_result.graphics_queue,
            .present_queue = device_result.present_queue,
            .families = families,
            .validation_active = validation_active,
        };
    }

    pub fn deinit(self: *GpuContext) void {
        _ = vk.vkDeviceWaitIdle(self.device);
        vk.vkDestroyDevice(self.device, null);
        vk.vkDestroySurfaceKHR(self.instance, self.surface, null);
        if (self.validation_active) destroyDebugMessenger(self.instance, self.debug_messenger);
        vk.vkDestroyInstance(self.instance, null);
    }

    pub fn printCapabilities(self: *const GpuContext) void {
        var props: vk.VkPhysicalDeviceProperties = undefined;
        vk.vkGetPhysicalDeviceProperties(self.physical_device, &props);

        const api = props.apiVersion;
        const api_major = vk.VK_API_VERSION_MAJOR(api);
        const api_minor = vk.VK_API_VERSION_MINOR(api);
        const api_patch = vk.VK_API_VERSION_PATCH(api);

        var ext_count: u32 = 0;
        _ = vk.vkEnumerateDeviceExtensionProperties(self.physical_device, null, &ext_count, null);

        std.debug.print("== gpu ==\n", .{});
        std.debug.print("  device          : {s}\n", .{@as([*:0]const u8, @ptrCast(&props.deviceName))});
        std.debug.print("  type            : {s}\n", .{deviceTypeName(props.deviceType)});
        std.debug.print("  vendor id       : 0x{x:0>4}\n", .{props.vendorID});
        std.debug.print("  api version     : {d}.{d}.{d}\n", .{ api_major, api_minor, api_patch });
        std.debug.print("  driver version  : 0x{x:0>8}\n", .{props.driverVersion});
        std.debug.print("  graphics queue  : family {d}\n", .{self.families.graphics});
        std.debug.print("  present queue   : family {d}{s}\n", .{
            self.families.present,
            if (self.families.graphics == self.families.present) " (shared)" else "",
        });
        std.debug.print("  device exts     : {d} available\n", .{ext_count});
        std.debug.print("  validation      : {s}\n", .{if (self.validation_active) "active" else "off"});
    }
};

fn deviceTypeName(t: vk.VkPhysicalDeviceType) []const u8 {
    return switch (t) {
        vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => "discrete",
        vk.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => "integrated",
        vk.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => "virtual",
        vk.VK_PHYSICAL_DEVICE_TYPE_CPU => "cpu",
        else => "other",
    };
}

fn validationLayerAvailable(gpa: std.mem.Allocator) !bool {
    var count: u32 = 0;
    if (vk.vkEnumerateInstanceLayerProperties(&count, null) != vk.VK_SUCCESS)
        return VulkanError.LayerEnumerationFailed;
    if (count == 0) return false;

    const layers = try gpa.alloc(vk.VkLayerProperties, count);
    defer gpa.free(layers);
    if (vk.vkEnumerateInstanceLayerProperties(&count, layers.ptr) != vk.VK_SUCCESS)
        return VulkanError.LayerEnumerationFailed;

    const wanted = std.mem.span(validation_layer_name);
    for (layers) |layer| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&layer.layerName)));
        if (std.mem.eql(u8, name, wanted)) return true;
    }
    return false;
}

fn createInstance(
    gpa: std.mem.Allocator,
    app_name: [:0]const u8,
    validation_active: bool,
) !vk.VkInstance {
    const glfw_exts = try window_mod.Window.requiredInstanceExtensions();

    var ext_list: std.ArrayList([*:0]const u8) = .empty;
    defer ext_list.deinit(gpa);
    try ext_list.appendSlice(gpa, glfw_exts);
    if (validation_active) try ext_list.append(gpa, vk.VK_EXT_DEBUG_UTILS_EXTENSION_NAME);

    const app_info = vk.VkApplicationInfo{
        .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pNext = null,
        .pApplicationName = app_name.ptr,
        .applicationVersion = vk.VK_MAKE_API_VERSION(0, 0, 0, 1),
        .pEngineName = "notatlas-engine",
        .engineVersion = vk.VK_MAKE_API_VERSION(0, 0, 0, 1),
        .apiVersion = vk.VK_API_VERSION_1_3,
    };

    var debug_ci = debugMessengerCreateInfo();
    const layers = [_][*:0]const u8{validation_layer_name};

    const create_info = vk.VkInstanceCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pNext = if (validation_active) @as(?*const anyopaque, @ptrCast(&debug_ci)) else null,
        .flags = 0,
        .pApplicationInfo = &app_info,
        .enabledLayerCount = if (validation_active) 1 else 0,
        .ppEnabledLayerNames = if (validation_active) &layers else null,
        .enabledExtensionCount = @intCast(ext_list.items.len),
        .ppEnabledExtensionNames = ext_list.items.ptr,
    };

    var instance: vk.VkInstance = undefined;
    try types.check(vk.vkCreateInstance(&create_info, null, &instance), VulkanError.InstanceCreationFailed);
    return instance;
}

fn debugMessengerCallback(
    severity: vk.VkDebugUtilsMessageSeverityFlagBitsEXT,
    msg_type: vk.VkDebugUtilsMessageTypeFlagsEXT,
    data: [*c]const vk.VkDebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(.c) vk.VkBool32 {
    _ = msg_type;
    _ = user_data;
    const tag: []const u8 = switch (severity) {
        vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT => "vk-err ",
        vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT => "vk-warn",
        vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT => "vk-info",
        else => "vk-dbg ",
    };
    if (data != null and data.*.pMessage != null) {
        std.debug.print("[{s}] {s}\n", .{ tag, data.*.pMessage });
    }
    return vk.VK_FALSE;
}

fn debugMessengerCreateInfo() vk.VkDebugUtilsMessengerCreateInfoEXT {
    return .{
        .sType = vk.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .pNext = null,
        .flags = 0,
        .messageSeverity = vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
            vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
        .messageType = vk.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
            vk.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
            vk.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
        .pfnUserCallback = debugMessengerCallback,
        .pUserData = null,
    };
}

fn createDebugMessenger(instance: vk.VkInstance) !vk.VkDebugUtilsMessengerEXT {
    const proc = vk.vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT");
    if (proc == null) return VulkanError.DebugMessengerCreationFailed;
    const create_fn: vk.PFN_vkCreateDebugUtilsMessengerEXT = @ptrCast(proc);

    const ci = debugMessengerCreateInfo();
    var messenger: vk.VkDebugUtilsMessengerEXT = undefined;
    try types.check(create_fn.?(instance, &ci, null, &messenger), VulkanError.DebugMessengerCreationFailed);
    return messenger;
}

fn destroyDebugMessenger(instance: vk.VkInstance, messenger: vk.VkDebugUtilsMessengerEXT) void {
    const proc = vk.vkGetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT");
    if (proc == null) return;
    const destroy_fn: vk.PFN_vkDestroyDebugUtilsMessengerEXT = @ptrCast(proc);
    destroy_fn.?(instance, messenger, null);
}

fn pickPhysicalDevice(
    gpa: std.mem.Allocator,
    instance: vk.VkInstance,
    surface: vk.VkSurfaceKHR,
) !vk.VkPhysicalDevice {
    var count: u32 = 0;
    _ = vk.vkEnumeratePhysicalDevices(instance, &count, null);
    if (count == 0) return VulkanError.NoVulkanDevices;

    const devices = try gpa.alloc(vk.VkPhysicalDevice, count);
    defer gpa.free(devices);
    _ = vk.vkEnumeratePhysicalDevices(instance, &count, devices.ptr);

    var best: ?vk.VkPhysicalDevice = null;
    var best_score: i32 = -1;
    for (devices) |d| {
        if (!isDeviceSuitable(gpa, d, surface)) continue;
        const score = scoreDevice(d);
        if (score > best_score) {
            best = d;
            best_score = score;
        }
    }
    return best orelse VulkanError.NoSuitableDevice;
}

fn scoreDevice(device: vk.VkPhysicalDevice) i32 {
    var props: vk.VkPhysicalDeviceProperties = undefined;
    vk.vkGetPhysicalDeviceProperties(device, &props);
    return switch (props.deviceType) {
        vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => 1000,
        vk.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => 100,
        vk.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => 10,
        vk.VK_PHYSICAL_DEVICE_TYPE_CPU => 1,
        else => 0,
    };
}

fn isDeviceSuitable(
    gpa: std.mem.Allocator,
    device: vk.VkPhysicalDevice,
    surface: vk.VkSurfaceKHR,
) bool {
    _ = findQueueFamilies(gpa, device, surface) catch return false;
    return hasExtension(gpa, device, vk.VK_KHR_SWAPCHAIN_EXTENSION_NAME) catch false;
}

fn hasExtension(
    gpa: std.mem.Allocator,
    device: vk.VkPhysicalDevice,
    name: [*:0]const u8,
) !bool {
    var count: u32 = 0;
    _ = vk.vkEnumerateDeviceExtensionProperties(device, null, &count, null);
    if (count == 0) return false;

    const exts = try gpa.alloc(vk.VkExtensionProperties, count);
    defer gpa.free(exts);
    _ = vk.vkEnumerateDeviceExtensionProperties(device, null, &count, exts.ptr);

    const wanted = std.mem.span(name);
    for (exts) |e| {
        const got = std.mem.span(@as([*:0]const u8, @ptrCast(&e.extensionName)));
        if (std.mem.eql(u8, got, wanted)) return true;
    }
    return false;
}

fn findQueueFamilies(
    gpa: std.mem.Allocator,
    device: vk.VkPhysicalDevice,
    surface: vk.VkSurfaceKHR,
) !QueueFamilies {
    var count: u32 = 0;
    vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, null);
    if (count == 0) return VulkanError.QueueFamilyNotFound;

    const families = try gpa.alloc(vk.VkQueueFamilyProperties, count);
    defer gpa.free(families);
    vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, families.ptr);

    var graphics: ?u32 = null;
    var present: ?u32 = null;
    for (families, 0..) |f, i| {
        const idx: u32 = @intCast(i);
        if (graphics == null and (f.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) != 0) graphics = idx;

        var present_support: vk.VkBool32 = vk.VK_FALSE;
        _ = vk.vkGetPhysicalDeviceSurfaceSupportKHR(device, idx, surface, &present_support);
        if (present == null and present_support == vk.VK_TRUE) present = idx;

        if (graphics != null and present != null) break;
    }
    if (graphics == null or present == null) return VulkanError.QueueFamilyNotFound;
    return .{ .graphics = graphics.?, .present = present.? };
}

const DeviceResult = struct {
    device: vk.VkDevice,
    graphics_queue: vk.VkQueue,
    present_queue: vk.VkQueue,
};

fn createLogicalDevice(
    physical_device: vk.VkPhysicalDevice,
    families: QueueFamilies,
) !DeviceResult {
    const priority: f32 = 1.0;

    var queue_infos: [2]vk.VkDeviceQueueCreateInfo = undefined;
    queue_infos[0] = .{
        .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueFamilyIndex = families.graphics,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    var queue_count: u32 = 1;
    if (families.graphics != families.present) {
        queue_infos[1] = .{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = families.present,
            .queueCount = 1,
            .pQueuePriorities = &priority,
        };
        queue_count = 2;
    }

    const exts = [_][*:0]const u8{vk.VK_KHR_SWAPCHAIN_EXTENSION_NAME};
    // M10.2: enable indirect-draw features. `multiDrawIndirect` lets
    // `vkCmdDrawIndexedIndirect` issue more than one command per call;
    // `drawIndirectFirstInstance` lets indirect commands carry a non-zero
    // firstInstance (we use it to point each piece-bucket at its base row
    // in the instance SSBO). Both are core 1.0 optional features supported
    // by every desktop GPU we target.
    var features = std.mem.zeroes(vk.VkPhysicalDeviceFeatures);
    features.multiDrawIndirect = vk.VK_TRUE;
    features.drawIndirectFirstInstance = vk.VK_TRUE;

    const create_info = vk.VkDeviceCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueCreateInfoCount = queue_count,
        .pQueueCreateInfos = &queue_infos,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = exts.len,
        .ppEnabledExtensionNames = &exts,
        .pEnabledFeatures = &features,
    };

    var device: vk.VkDevice = undefined;
    try types.check(
        vk.vkCreateDevice(physical_device, &create_info, null, &device),
        VulkanError.DeviceCreationFailed,
    );

    var graphics_queue: vk.VkQueue = undefined;
    var present_queue: vk.VkQueue = undefined;
    vk.vkGetDeviceQueue(device, families.graphics, 0, &graphics_queue);
    vk.vkGetDeviceQueue(device, families.present, 0, &present_queue);

    return .{ .device = device, .graphics_queue = graphics_queue, .present_queue = present_queue };
}
