//! Vulkan swapchain: surface format/present-mode/extent selection,
//! image acquisition, image view creation, and resize recreation.
//!
//! Single-buffered ownership: the swapchain owns its handle, the slice of
//! images, and the image views derived from them. Framebuffers built from
//! these views live in `frame.zig` and must be recreated alongside the
//! swapchain on resize.

const std = @import("std");
const types = @import("vulkan_types.zig");
const gpu_mod = @import("gpu.zig");

const vk = types.vk;
const VulkanError = types.VulkanError;
const QueueFamilies = types.QueueFamilies;

pub const Config = struct {
    /// Preferred number of swapchain images. Clamped to surface min/max.
    /// 3 = triple-buffered; matches the project's 60 Hz cadence.
    desired_image_count: u32 = 3,
    /// FIFO is universally supported and v-synced. MAILBOX/IMMEDIATE
    /// fall back to FIFO if the surface does not advertise them.
    present_mode: vk.VkPresentModeKHR = vk.VK_PRESENT_MODE_FIFO_KHR,
};

pub const Swapchain = struct {
    handle: vk.VkSwapchainKHR,
    images: []vk.VkImage,
    image_views: []vk.VkImageView,
    format: vk.VkFormat,
    color_space: vk.VkColorSpaceKHR,
    extent: vk.VkExtent2D,

    gpa: std.mem.Allocator,
    device: vk.VkDevice,
    physical_device: vk.VkPhysicalDevice,
    surface: vk.VkSurfaceKHR,
    families: QueueFamilies,
    config: Config,

    pub fn init(
        gpa: std.mem.Allocator,
        gpu: *const gpu_mod.GpuContext,
        framebuffer_size: [2]u32,
        cfg: Config,
    ) !Swapchain {
        var self: Swapchain = .{
            .handle = null,
            .images = &.{},
            .image_views = &.{},
            .format = vk.VK_FORMAT_UNDEFINED,
            .color_space = vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
            .extent = .{ .width = 0, .height = 0 },
            .gpa = gpa,
            .device = gpu.device,
            .physical_device = gpu.physical_device,
            .surface = gpu.surface,
            .families = gpu.families,
            .config = cfg,
        };
        try self.create(framebuffer_size, null);
        return self;
    }

    pub fn deinit(self: *Swapchain) void {
        self.destroyViews();
        if (self.handle != null) vk.vkDestroySwapchainKHR(self.device, self.handle, null);
        if (self.images.len != 0) self.gpa.free(self.images);
    }

    /// Wait for device idle, then rebuild the swapchain in place. Old image
    /// views are destroyed; framebuffers built from them are NOT touched —
    /// the caller (frame.zig) recreates those after this returns.
    pub fn recreate(self: *Swapchain, framebuffer_size: [2]u32) !void {
        _ = vk.vkDeviceWaitIdle(self.device);
        self.destroyViews();
        const old = self.handle;
        self.gpa.free(self.images);
        self.images = &.{};
        self.handle = null;
        try self.create(framebuffer_size, old);
        if (old != null) vk.vkDestroySwapchainKHR(self.device, old, null);
    }

    fn destroyViews(self: *Swapchain) void {
        for (self.image_views) |iv| vk.vkDestroyImageView(self.device, iv, null);
        if (self.image_views.len != 0) self.gpa.free(self.image_views);
        self.image_views = &.{};
    }

    fn create(
        self: *Swapchain,
        framebuffer_size: [2]u32,
        old_swapchain: vk.VkSwapchainKHR,
    ) !void {
        var caps: vk.VkSurfaceCapabilitiesKHR = undefined;
        try types.check(
            vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface, &caps),
            VulkanError.SwapchainCreationFailed,
        );

        const surface_format = try pickSurfaceFormat(self.gpa, self.physical_device, self.surface);
        const present_mode = try pickPresentMode(
            self.gpa,
            self.physical_device,
            self.surface,
            self.config.present_mode,
        );
        const extent = chooseExtent(caps, framebuffer_size);

        var image_count = @max(self.config.desired_image_count, caps.minImageCount);
        if (caps.maxImageCount > 0 and image_count > caps.maxImageCount)
            image_count = caps.maxImageCount;

        const queue_indices = [_]u32{ self.families.graphics, self.families.present };
        const concurrent = self.families.graphics != self.families.present;
        const sharing_mode: vk.VkSharingMode = if (concurrent)
            vk.VK_SHARING_MODE_CONCURRENT
        else
            vk.VK_SHARING_MODE_EXCLUSIVE;

        const create_info = vk.VkSwapchainCreateInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = surface_format.format,
            .imageColorSpace = surface_format.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = sharing_mode,
            .queueFamilyIndexCount = if (concurrent) 2 else 0,
            .pQueueFamilyIndices = if (concurrent) &queue_indices else null,
            .preTransform = caps.currentTransform,
            .compositeAlpha = vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = present_mode,
            .clipped = vk.VK_TRUE,
            .oldSwapchain = old_swapchain,
        };

        var handle: vk.VkSwapchainKHR = undefined;
        try types.check(
            vk.vkCreateSwapchainKHR(self.device, &create_info, null, &handle),
            VulkanError.SwapchainCreationFailed,
        );
        errdefer vk.vkDestroySwapchainKHR(self.device, handle, null);

        var n: u32 = 0;
        _ = vk.vkGetSwapchainImagesKHR(self.device, handle, &n, null);
        const images = try self.gpa.alloc(vk.VkImage, n);
        errdefer self.gpa.free(images);
        _ = vk.vkGetSwapchainImagesKHR(self.device, handle, &n, images.ptr);

        const image_views = try self.gpa.alloc(vk.VkImageView, n);
        var created: usize = 0;
        errdefer {
            for (image_views[0..created]) |iv| vk.vkDestroyImageView(self.device, iv, null);
            self.gpa.free(image_views);
        }
        for (images) |img| {
            const iv_ci = vk.VkImageViewCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .image = img,
                .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
                .format = surface_format.format,
                .components = .{
                    .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                },
                .subresourceRange = .{
                    .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
            };
            try types.check(
                vk.vkCreateImageView(self.device, &iv_ci, null, &image_views[created]),
                VulkanError.ImageViewCreationFailed,
            );
            created += 1;
        }

        self.handle = handle;
        self.images = images;
        self.image_views = image_views;
        self.format = surface_format.format;
        self.color_space = surface_format.colorSpace;
        self.extent = extent;
    }
};

fn pickSurfaceFormat(
    gpa: std.mem.Allocator,
    physical_device: vk.VkPhysicalDevice,
    surface: vk.VkSurfaceKHR,
) !vk.VkSurfaceFormatKHR {
    var n: u32 = 0;
    if (vk.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &n, null) != vk.VK_SUCCESS)
        return VulkanError.SurfaceFormatEnumerationFailed;
    if (n == 0) return VulkanError.SurfaceFormatEnumerationFailed;

    const formats = try gpa.alloc(vk.VkSurfaceFormatKHR, n);
    defer gpa.free(formats);
    _ = vk.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &n, formats.ptr);

    for (formats) |f| {
        if (f.format == vk.VK_FORMAT_B8G8R8A8_SRGB and f.colorSpace == vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
            return f;
    }
    return formats[0];
}

fn pickPresentMode(
    gpa: std.mem.Allocator,
    physical_device: vk.VkPhysicalDevice,
    surface: vk.VkSurfaceKHR,
    requested: vk.VkPresentModeKHR,
) !vk.VkPresentModeKHR {
    var n: u32 = 0;
    _ = vk.vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &n, null);
    if (n == 0) return vk.VK_PRESENT_MODE_FIFO_KHR;

    const modes = try gpa.alloc(vk.VkPresentModeKHR, n);
    defer gpa.free(modes);
    _ = vk.vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &n, modes.ptr);

    for (modes) |m| if (m == requested) return requested;
    return vk.VK_PRESENT_MODE_FIFO_KHR;
}

fn chooseExtent(caps: vk.VkSurfaceCapabilitiesKHR, framebuffer_size: [2]u32) vk.VkExtent2D {
    if (caps.currentExtent.width != std.math.maxInt(u32)) return caps.currentExtent;
    return .{
        .width = std.math.clamp(
            framebuffer_size[0],
            caps.minImageExtent.width,
            caps.maxImageExtent.width,
        ),
        .height = std.math.clamp(
            framebuffer_size[1],
            caps.minImageExtent.height,
            caps.maxImageExtent.height,
        ),
    };
}
