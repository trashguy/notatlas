//! Per-frame command buffer + sync primitives + render pass + framebuffers.
//!
//! Single frame in flight for M2.2 — adequate for clear-to-color and avoids
//! the bookkeeping of MFIF until M2.3+ when there's actually GPU work to
//! pipeline against the next-frame CPU.

const std = @import("std");
const types = @import("vulkan_types.zig");
const gpu_mod = @import("gpu.zig");
const swapchain_mod = @import("swapchain.zig");

const vk = types.vk;
const VulkanError = types.VulkanError;

pub const DrawResult = enum { ok, resize_needed };

pub const Frame = struct {
    gpa: std.mem.Allocator,
    device: vk.VkDevice,
    graphics_queue: vk.VkQueue,
    present_queue: vk.VkQueue,

    render_pass: vk.VkRenderPass,
    framebuffers: []vk.VkFramebuffer,
    command_pool: vk.VkCommandPool,
    command_buffer: vk.VkCommandBuffer,

    image_available: vk.VkSemaphore,
    render_finished: vk.VkSemaphore,
    in_flight: vk.VkFence,

    pub fn init(
        gpa: std.mem.Allocator,
        gpu: *const gpu_mod.GpuContext,
        swapchain: *const swapchain_mod.Swapchain,
    ) !Frame {
        const render_pass = try createRenderPass(gpu.device, swapchain.format);
        errdefer vk.vkDestroyRenderPass(gpu.device, render_pass, null);

        const framebuffers = try createFramebuffers(gpa, gpu.device, render_pass, swapchain);
        errdefer destroyFramebuffers(gpa, gpu.device, framebuffers);

        const command_pool = try createCommandPool(gpu.device, gpu.families.graphics);
        errdefer vk.vkDestroyCommandPool(gpu.device, command_pool, null);

        const command_buffer = try allocateCommandBuffer(gpu.device, command_pool);

        var image_available: vk.VkSemaphore = undefined;
        var render_finished: vk.VkSemaphore = undefined;
        var in_flight: vk.VkFence = undefined;
        try createSync(gpu.device, &image_available, &render_finished, &in_flight);

        return .{
            .gpa = gpa,
            .device = gpu.device,
            .graphics_queue = gpu.graphics_queue,
            .present_queue = gpu.present_queue,
            .render_pass = render_pass,
            .framebuffers = framebuffers,
            .command_pool = command_pool,
            .command_buffer = command_buffer,
            .image_available = image_available,
            .render_finished = render_finished,
            .in_flight = in_flight,
        };
    }

    pub fn deinit(self: *Frame) void {
        _ = vk.vkDeviceWaitIdle(self.device);
        vk.vkDestroySemaphore(self.device, self.image_available, null);
        vk.vkDestroySemaphore(self.device, self.render_finished, null);
        vk.vkDestroyFence(self.device, self.in_flight, null);
        vk.vkDestroyCommandPool(self.device, self.command_pool, null);
        destroyFramebuffers(self.gpa, self.device, self.framebuffers);
        vk.vkDestroyRenderPass(self.device, self.render_pass, null);
    }

    /// Tear down the framebuffer set and rebuild it against the (already
    /// recreated) swapchain. Caller must have run `swapchain.recreate()`
    /// first; that call already waits on device idle.
    pub fn recreateFramebuffers(self: *Frame, swapchain: *const swapchain_mod.Swapchain) !void {
        destroyFramebuffers(self.gpa, self.device, self.framebuffers);
        self.framebuffers = &.{};
        self.framebuffers = try createFramebuffers(self.gpa, self.device, self.render_pass, swapchain);
    }

    pub fn draw(
        self: *Frame,
        swapchain: *const swapchain_mod.Swapchain,
        clear_color: [4]f32,
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

        try recordClear(
            self.command_buffer,
            self.render_pass,
            self.framebuffers[image_index],
            swapchain.extent,
            clear_color,
        );

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
            .pSignalSemaphores = &self.render_finished,
        };
        try types.check(
            vk.vkQueueSubmit(self.graphics_queue, 1, &submit_info, self.in_flight),
            VulkanError.QueueSubmitFailed,
        );

        const present_info = vk.VkPresentInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.render_finished,
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
    const color_attachment = vk.VkAttachmentDescription{
        .flags = 0,
        .format = format,
        .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };
    const color_ref = vk.VkAttachmentReference{
        .attachment = 0,
        .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };
    const subpass = vk.VkSubpassDescription{
        .flags = 0,
        .pipelineBindPoint = vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .inputAttachmentCount = 0,
        .pInputAttachments = null,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_ref,
        .pResolveAttachments = null,
        .pDepthStencilAttachment = null,
        .preserveAttachmentCount = 0,
        .pPreserveAttachments = null,
    };
    // External → subpass 0 dependency: don't write the attachment until the
    // image-available semaphore has been waited on at color-output stage.
    const dep = vk.VkSubpassDependency{
        .srcSubpass = vk.VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = 0,
        .dstAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .dependencyFlags = 0,
    };
    const ci = vk.VkRenderPassCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .attachmentCount = 1,
        .pAttachments = &color_attachment,
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

fn createFramebuffers(
    gpa: std.mem.Allocator,
    device: vk.VkDevice,
    render_pass: vk.VkRenderPass,
    swapchain: *const swapchain_mod.Swapchain,
) ![]vk.VkFramebuffer {
    const fbs = try gpa.alloc(vk.VkFramebuffer, swapchain.image_views.len);
    var created: usize = 0;
    errdefer {
        for (fbs[0..created]) |fb| vk.vkDestroyFramebuffer(device, fb, null);
        gpa.free(fbs);
    }
    for (swapchain.image_views) |iv| {
        const attachments = [_]vk.VkImageView{iv};
        const ci = vk.VkFramebufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .renderPass = render_pass,
            .attachmentCount = 1,
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

fn createSync(
    device: vk.VkDevice,
    image_available: *vk.VkSemaphore,
    render_finished: *vk.VkSemaphore,
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
        vk.vkCreateSemaphore(device, &sem_ci, null, render_finished),
        VulkanError.SemaphoreCreationFailed,
    );
    errdefer vk.vkDestroySemaphore(device, render_finished.*, null);

    try types.check(
        vk.vkCreateFence(device, &fence_ci, null, in_flight),
        VulkanError.FenceCreationFailed,
    );
}

fn recordClear(
    cb: vk.VkCommandBuffer,
    render_pass: vk.VkRenderPass,
    framebuffer: vk.VkFramebuffer,
    extent: vk.VkExtent2D,
    clear_color: [4]f32,
) !void {
    try types.check(vk.vkResetCommandBuffer(cb, 0), VulkanError.CommandBufferBeginFailed);

    const begin = vk.VkCommandBufferBeginInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = 0,
        .pInheritanceInfo = null,
    };
    try types.check(vk.vkBeginCommandBuffer(cb, &begin), VulkanError.CommandBufferBeginFailed);

    const clear = vk.VkClearValue{
        .color = .{ .float32 = clear_color },
    };
    const rp_begin = vk.VkRenderPassBeginInfo{
        .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .pNext = null,
        .renderPass = render_pass,
        .framebuffer = framebuffer,
        .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
        .clearValueCount = 1,
        .pClearValues = &clear,
    };
    vk.vkCmdBeginRenderPass(cb, &rp_begin, vk.VK_SUBPASS_CONTENTS_INLINE);
    vk.vkCmdEndRenderPass(cb);

    try types.check(vk.vkEndCommandBuffer(cb), VulkanError.CommandBufferEndFailed);
}
