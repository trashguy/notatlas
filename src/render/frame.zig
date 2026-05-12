//! Per-frame command buffer + sync primitives + render pass + framebuffers
//! + depth buffer.
//!
//! Single frame in flight for M2.2 — adequate for clear-to-color and avoids
//! the bookkeeping of MFIF until M2.3+ when there's actually GPU work to
//! pipeline against the next-frame CPU. Depth attachment was added at M2.5
//! once the surface had real 3D structure (Gerstner crests overlap and
//! occlude each other; without z-test, the triangles paint in vertex order
//! and produce picket-fence artifacts along the horizon).

const std = @import("std");
const types = @import("vulkan_types.zig");
const gpu_mod = @import("gpu.zig");
const swapchain_mod = @import("swapchain.zig");

const vk = types.vk;
const VulkanError = types.VulkanError;

/// D32_SFLOAT is mandatory in Vulkan core; no fallback path needed.
pub const DEPTH_FORMAT: vk.VkFormat = vk.VK_FORMAT_D32_SFLOAT;

const DepthBuffer = struct {
    image: vk.VkImage,
    memory: vk.VkDeviceMemory,
    view: vk.VkImageView,

    fn deinit(self: DepthBuffer, device: vk.VkDevice) void {
        vk.vkDestroyImageView(device, self.view, null);
        vk.vkDestroyImage(device, self.image, null);
        vk.vkFreeMemory(device, self.memory, null);
    }
};

pub const DrawResult = enum { ok, resize_needed };

/// Caller-provided pass recorder. Invoked between vkCmdBeginRenderPass and
/// vkCmdEndRenderPass with the active command buffer and swapchain extent.
/// `ctx` is whatever pointer the caller passed alongside the function.
pub const RecordPassFn = *const fn (ctx: *anyopaque, cb: vk.VkCommandBuffer, extent: vk.VkExtent2D) void;

/// Optional pre-pass recorder. Invoked AFTER vkBeginCommandBuffer but
/// BEFORE vkCmdBeginRenderPass. Use for compute dispatches + their
/// pipeline barriers — neither legal inside a render pass. M10.3 GPU
/// frustum culling rides this hook. Ctx pointer model matches
/// `RecordPassFn`.
pub const PrePassFn = *const fn (ctx: *anyopaque, cb: vk.VkCommandBuffer, extent: vk.VkExtent2D) void;

pub const Frame = struct {
    gpa: std.mem.Allocator,
    device: vk.VkDevice,
    physical_device: vk.VkPhysicalDevice,
    graphics_queue: vk.VkQueue,
    present_queue: vk.VkQueue,

    render_pass: vk.VkRenderPass,
    depth: DepthBuffer,
    framebuffers: []vk.VkFramebuffer,
    command_pool: vk.VkCommandPool,
    command_buffer: vk.VkCommandBuffer,

    image_available: vk.VkSemaphore,
    /// One render-finished semaphore per swapchain image. Indexed by the
    /// image returned from vkAcquireNextImageKHR. A single shared semaphore
    /// here would violate VUID-vkQueueSubmit-pSignalSemaphores-00067 because
    /// the WSI may still hold the previous present's signal semaphore when
    /// the next submit signals it.
    render_finished_per_image: []vk.VkSemaphore,
    in_flight: vk.VkFence,

    pub fn init(
        gpa: std.mem.Allocator,
        gpu: *const gpu_mod.GpuContext,
        swapchain: *const swapchain_mod.Swapchain,
    ) !Frame {
        const render_pass = try createRenderPass(gpu.device, swapchain.format);
        errdefer vk.vkDestroyRenderPass(gpu.device, render_pass, null);

        const depth = try createDepthBuffer(gpu, swapchain.extent);
        errdefer depth.deinit(gpu.device);

        const framebuffers = try createFramebuffers(gpa, gpu.device, render_pass, swapchain, depth.view);
        errdefer destroyFramebuffers(gpa, gpu.device, framebuffers);

        const command_pool = try createCommandPool(gpu.device, gpu.families.graphics);
        errdefer vk.vkDestroyCommandPool(gpu.device, command_pool, null);

        const command_buffer = try allocateCommandBuffer(gpu.device, command_pool);

        var image_available: vk.VkSemaphore = undefined;
        var in_flight: vk.VkFence = undefined;
        try createSyncSingles(gpu.device, &image_available, &in_flight);
        errdefer vk.vkDestroySemaphore(gpu.device, image_available, null);
        errdefer vk.vkDestroyFence(gpu.device, in_flight, null);

        const render_finished = try createPerImageSemaphores(gpa, gpu.device, swapchain.images.len);

        return .{
            .gpa = gpa,
            .device = gpu.device,
            .physical_device = gpu.physical_device,
            .graphics_queue = gpu.graphics_queue,
            .present_queue = gpu.present_queue,
            .render_pass = render_pass,
            .depth = depth,
            .framebuffers = framebuffers,
            .command_pool = command_pool,
            .command_buffer = command_buffer,
            .image_available = image_available,
            .render_finished_per_image = render_finished,
            .in_flight = in_flight,
        };
    }

    pub fn deinit(self: *Frame) void {
        _ = vk.vkDeviceWaitIdle(self.device);
        vk.vkDestroySemaphore(self.device, self.image_available, null);
        destroyPerImageSemaphores(self.gpa, self.device, self.render_finished_per_image);
        vk.vkDestroyFence(self.device, self.in_flight, null);
        vk.vkDestroyCommandPool(self.device, self.command_pool, null);
        destroyFramebuffers(self.gpa, self.device, self.framebuffers);
        self.depth.deinit(self.device);
        vk.vkDestroyRenderPass(self.device, self.render_pass, null);
    }

    /// Tear down framebuffers + per-image semaphores + depth buffer and
    /// rebuild them against the (already recreated) swapchain. All three
    /// depend on the swapchain extent or image count. Caller must have
    /// run `swapchain.recreate()` first; that already waits idle.
    pub fn recreateFramebuffers(
        self: *Frame,
        gpu: *const gpu_mod.GpuContext,
        swapchain: *const swapchain_mod.Swapchain,
    ) !void {
        destroyFramebuffers(self.gpa, self.device, self.framebuffers);
        self.framebuffers = &.{};

        self.depth.deinit(self.device);
        self.depth = try createDepthBuffer(gpu, swapchain.extent);

        self.framebuffers = try createFramebuffers(self.gpa, self.device, self.render_pass, swapchain, self.depth.view);

        destroyPerImageSemaphores(self.gpa, self.device, self.render_finished_per_image);
        self.render_finished_per_image = &.{};
        self.render_finished_per_image = try createPerImageSemaphores(self.gpa, self.device, swapchain.images.len);
    }

    pub fn draw(
        self: *Frame,
        swapchain: *const swapchain_mod.Swapchain,
        clear_color: [4]f32,
        record_pass: ?RecordPassFn,
        record_ctx: ?*anyopaque,
        pre_pass: ?PrePassFn,
        pre_pass_ctx: ?*anyopaque,
    ) !DrawResult {
        _ = vk.vkWaitForFences(self.device, 1, &self.in_flight, vk.VK_TRUE, std.math.maxInt(u64));

        var image_index: u32 = 0;
        const acquire_res = vk.vkAcquireNextImageKHR(
            self.device,
            swapchain.handle,
            std.math.maxInt(u64),
            self.image_available,
            null,
            &image_index,
        );
        if (acquire_res == vk.VK_ERROR_OUT_OF_DATE_KHR) return .resize_needed;
        if (acquire_res != vk.VK_SUCCESS and acquire_res != vk.VK_SUBOPTIMAL_KHR)
            return VulkanError.AcquireImageFailed;

        // Reset only after a successful acquire; otherwise we'd deadlock if
        // we returned early on resize and never signalled the fence.
        _ = vk.vkResetFences(self.device, 1, &self.in_flight);

        try recordPass(
            self.command_buffer,
            self.render_pass,
            self.framebuffers[image_index],
            swapchain.extent,
            clear_color,
            record_pass,
            record_ctx,
            pre_pass,
            pre_pass_ctx,
        );

        const render_finished = self.render_finished_per_image[image_index];
        const wait_stage: vk.VkPipelineStageFlags = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        const submit_info = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.image_available,
            .pWaitDstStageMask = &wait_stage,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.command_buffer,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &render_finished,
        };
        try types.check(
            vk.vkQueueSubmit(self.graphics_queue, 1, &submit_info, self.in_flight),
            VulkanError.QueueSubmitFailed,
        );

        const present_info = vk.VkPresentInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &render_finished,
            .swapchainCount = 1,
            .pSwapchains = &swapchain.handle,
            .pImageIndices = &image_index,
            .pResults = null,
        };
        const present_res = vk.vkQueuePresentKHR(self.present_queue, &present_info);
        if (present_res == vk.VK_ERROR_OUT_OF_DATE_KHR or present_res == vk.VK_SUBOPTIMAL_KHR)
            return .resize_needed;
        if (present_res != vk.VK_SUCCESS) return VulkanError.QueuePresentFailed;

        return .ok;
    }
};

fn createRenderPass(device: vk.VkDevice, format: vk.VkFormat) !vk.VkRenderPass {
    const attachments = [_]vk.VkAttachmentDescription{
        .{
            .flags = 0,
            .format = format,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        },
        .{
            .flags = 0,
            .format = DEPTH_FORMAT,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
            // Depth is consumed only within this pass; presenting doesn't read it.
            .storeOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = vk.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        },
    };
    const color_ref = vk.VkAttachmentReference{
        .attachment = 0,
        .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };
    const depth_ref = vk.VkAttachmentReference{
        .attachment = 1,
        .layout = vk.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    };
    const subpass = vk.VkSubpassDescription{
        .flags = 0,
        .pipelineBindPoint = vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .inputAttachmentCount = 0,
        .pInputAttachments = null,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_ref,
        .pResolveAttachments = null,
        .pDepthStencilAttachment = &depth_ref,
        .preserveAttachmentCount = 0,
        .pPreserveAttachments = null,
    };
    // External → subpass 0 dependency: cover both color-attachment writes
    // (synchronized against the image-available semaphore) and the
    // early-fragment depth read/write that happens before the fragment
    // shader runs.
    const dep = vk.VkSubpassDependency{
        .srcSubpass = vk.VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
            vk.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        .dstStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
            vk.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        .srcAccessMask = 0,
        .dstAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
            vk.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        .dependencyFlags = 0,
    };
    const ci = vk.VkRenderPassCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .attachmentCount = attachments.len,
        .pAttachments = &attachments,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 1,
        .pDependencies = &dep,
    };
    var rp: vk.VkRenderPass = undefined;
    try types.check(
        vk.vkCreateRenderPass(device, &ci, null, &rp),
        VulkanError.RenderPassCreationFailed,
    );
    return rp;
}

fn createDepthBuffer(
    gpu: *const gpu_mod.GpuContext,
    extent: vk.VkExtent2D,
) !DepthBuffer {
    const image_ci = vk.VkImageCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .imageType = vk.VK_IMAGE_TYPE_2D,
        .format = DEPTH_FORMAT,
        .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
        .usage = vk.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
    };
    var image: vk.VkImage = undefined;
    try types.check(
        vk.vkCreateImage(gpu.device, &image_ci, null, &image),
        VulkanError.ImageCreationFailed,
    );
    errdefer vk.vkDestroyImage(gpu.device, image, null);

    var req: vk.VkMemoryRequirements = undefined;
    vk.vkGetImageMemoryRequirements(gpu.device, image, &req);

    const mem_idx = try findMemoryType(
        gpu.physical_device,
        req.memoryTypeBits,
        vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    );
    const alloc_ci = vk.VkMemoryAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = req.size,
        .memoryTypeIndex = mem_idx,
    };
    var memory: vk.VkDeviceMemory = undefined;
    try types.check(
        vk.vkAllocateMemory(gpu.device, &alloc_ci, null, &memory),
        VulkanError.MemoryAllocationFailed,
    );
    errdefer vk.vkFreeMemory(gpu.device, memory, null);

    try types.check(
        vk.vkBindImageMemory(gpu.device, image, memory, 0),
        VulkanError.MemoryAllocationFailed,
    );

    const view_ci = vk.VkImageViewCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .image = image,
        .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
        .format = DEPTH_FORMAT,
        .components = .{
            .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
        },
        .subresourceRange = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_DEPTH_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    var view: vk.VkImageView = undefined;
    try types.check(
        vk.vkCreateImageView(gpu.device, &view_ci, null, &view),
        VulkanError.ImageViewCreationFailed,
    );
    return .{ .image = image, .memory = memory, .view = view };
}

fn findMemoryType(
    physical_device: vk.VkPhysicalDevice,
    type_filter: u32,
    properties: vk.VkMemoryPropertyFlags,
) !u32 {
    var props: vk.VkPhysicalDeviceMemoryProperties = undefined;
    vk.vkGetPhysicalDeviceMemoryProperties(physical_device, &props);

    var i: u32 = 0;
    while (i < props.memoryTypeCount) : (i += 1) {
        const bit: u32 = @as(u32, 1) << @intCast(i);
        if ((type_filter & bit) == 0) continue;
        if ((props.memoryTypes[i].propertyFlags & properties) == properties) return i;
    }
    return VulkanError.NoSuitableMemoryType;
}

fn createFramebuffers(
    gpa: std.mem.Allocator,
    device: vk.VkDevice,
    render_pass: vk.VkRenderPass,
    swapchain: *const swapchain_mod.Swapchain,
    depth_view: vk.VkImageView,
) ![]vk.VkFramebuffer {
    const fbs = try gpa.alloc(vk.VkFramebuffer, swapchain.image_views.len);
    var created: usize = 0;
    errdefer {
        for (fbs[0..created]) |fb| vk.vkDestroyFramebuffer(device, fb, null);
        gpa.free(fbs);
    }
    for (swapchain.image_views) |iv| {
        // Depth view is shared across all swapchain images — only one frame
        // is in flight, so they can't read/write it concurrently.
        const attachments = [_]vk.VkImageView{ iv, depth_view };
        const ci = vk.VkFramebufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .renderPass = render_pass,
            .attachmentCount = attachments.len,
            .pAttachments = &attachments,
            .width = swapchain.extent.width,
            .height = swapchain.extent.height,
            .layers = 1,
        };
        try types.check(
            vk.vkCreateFramebuffer(device, &ci, null, &fbs[created]),
            VulkanError.FramebufferCreationFailed,
        );
        created += 1;
    }
    return fbs;
}

fn destroyFramebuffers(gpa: std.mem.Allocator, device: vk.VkDevice, fbs: []vk.VkFramebuffer) void {
    for (fbs) |fb| vk.vkDestroyFramebuffer(device, fb, null);
    if (fbs.len != 0) gpa.free(fbs);
}

fn createCommandPool(device: vk.VkDevice, graphics_family: u32) !vk.VkCommandPool {
    const ci = vk.VkCommandPoolCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .pNext = null,
        .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = graphics_family,
    };
    var pool: vk.VkCommandPool = undefined;
    try types.check(
        vk.vkCreateCommandPool(device, &ci, null, &pool),
        VulkanError.CommandPoolCreationFailed,
    );
    return pool;
}

fn allocateCommandBuffer(device: vk.VkDevice, pool: vk.VkCommandPool) !vk.VkCommandBuffer {
    const ai = vk.VkCommandBufferAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = pool,
        .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    var buf: vk.VkCommandBuffer = undefined;
    try types.check(
        vk.vkAllocateCommandBuffers(device, &ai, &buf),
        VulkanError.CommandBufferAllocationFailed,
    );
    return buf;
}

fn createSyncSingles(
    device: vk.VkDevice,
    image_available: *vk.VkSemaphore,
    in_flight: *vk.VkFence,
) !void {
    const sem_ci = vk.VkSemaphoreCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
    };
    // Created signalled so the first vkWaitForFences in draw() doesn't block.
    const fence_ci = vk.VkFenceCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .pNext = null,
        .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
    };

    try types.check(
        vk.vkCreateSemaphore(device, &sem_ci, null, image_available),
        VulkanError.SemaphoreCreationFailed,
    );
    errdefer vk.vkDestroySemaphore(device, image_available.*, null);

    try types.check(
        vk.vkCreateFence(device, &fence_ci, null, in_flight),
        VulkanError.FenceCreationFailed,
    );
}

fn createPerImageSemaphores(
    gpa: std.mem.Allocator,
    device: vk.VkDevice,
    count: usize,
) ![]vk.VkSemaphore {
    const sems = try gpa.alloc(vk.VkSemaphore, count);
    var created: usize = 0;
    errdefer {
        for (sems[0..created]) |s| vk.vkDestroySemaphore(device, s, null);
        gpa.free(sems);
    }
    const sem_ci = vk.VkSemaphoreCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
    };
    while (created < count) : (created += 1) {
        try types.check(
            vk.vkCreateSemaphore(device, &sem_ci, null, &sems[created]),
            VulkanError.SemaphoreCreationFailed,
        );
    }
    return sems;
}

fn destroyPerImageSemaphores(gpa: std.mem.Allocator, device: vk.VkDevice, sems: []vk.VkSemaphore) void {
    for (sems) |s| vk.vkDestroySemaphore(device, s, null);
    if (sems.len != 0) gpa.free(sems);
}

fn recordPass(
    cb: vk.VkCommandBuffer,
    render_pass: vk.VkRenderPass,
    framebuffer: vk.VkFramebuffer,
    extent: vk.VkExtent2D,
    clear_color: [4]f32,
    record_fn: ?RecordPassFn,
    ctx: ?*anyopaque,
    pre_pass_fn: ?PrePassFn,
    pre_pass_ctx: ?*anyopaque,
) !void {
    try types.check(vk.vkResetCommandBuffer(cb, 0), VulkanError.CommandBufferBeginFailed);

    const begin = vk.VkCommandBufferBeginInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = 0,
        .pInheritanceInfo = null,
    };
    try types.check(vk.vkBeginCommandBuffer(cb, &begin), VulkanError.CommandBufferBeginFailed);

    // Pre-pass: compute dispatches + barriers, outside the render pass.
    // M10.3 GPU frustum culling runs here.
    if (pre_pass_fn) |f| f(pre_pass_ctx.?, cb, extent);

    const clears = [_]vk.VkClearValue{
        .{ .color = .{ .float32 = clear_color } },
        .{ .depthStencil = .{ .depth = 1.0, .stencil = 0 } },
    };
    const rp_begin = vk.VkRenderPassBeginInfo{
        .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .pNext = null,
        .renderPass = render_pass,
        .framebuffer = framebuffer,
        .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
        .clearValueCount = clears.len,
        .pClearValues = &clears,
    };
    vk.vkCmdBeginRenderPass(cb, &rp_begin, vk.VK_SUBPASS_CONTENTS_INLINE);
    if (record_fn) |f| f(ctx.?, cb, extent);
    vk.vkCmdEndRenderPass(cb);

    try types.check(vk.vkEndCommandBuffer(cb), VulkanError.CommandBufferEndFailed);
}
