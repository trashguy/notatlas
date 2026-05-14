//! M14.2c texture upload pipeline.
//!
//! `Texture` owns the (VkImage, VkImageView, VkSampler) triple plus
//! the VMA-backed device-local memory. Init takes a loaded `ktx.Texture2`
//! (libktx already validated the format and pulled bytes into host
//! memory), uploads via a transient staging buffer + one-shot command
//! buffer, and transitions to SHADER_READ_ONLY_OPTIMAL.
//!
//! v1 scope (per current_work.md M14 plan):
//!   - 2D textures only (no cubemaps, no arrays)
//!   - One mip level — mip generation lands at M14.3 if the test asset
//!     stops looking right at distance.
//!   - Linear sampler with REPEAT wrap. Anisotropy off (enable when
//!     M14.3 hits ground textures).
//!   - Uncompressed RGBA8 first; format enum trusts whatever vkFormat
//!     libktx surfaces. BC7/BC5 work without code changes once the
//!     test asset uses them (Vulkan accepts compressed formats here
//!     identically — VkImageCreateInfo.format = VK_FORMAT_BC7_*).
//!
//! Allocation: VMA with `device_local` MemoryUsage. The staging buffer
//! is `host_seq_write` and lives only inside `init`.

const std = @import("std");
const types = @import("vulkan_types.zig");
const gpu_mod = @import("gpu.zig");
const buffer_mod = @import("buffer.zig");
const vma = @import("vma");
const ktx = @import("ktx");

const vk = types.vk;
const VulkanError = types.VulkanError;

pub const Texture = struct {
    device: vk.VkDevice,
    image: vma.c.VkImage,
    allocation: vma.c.VmaAllocation,
    allocator: vma.c.VmaAllocator,
    view: vk.VkImageView,
    sampler: vk.VkSampler,
    width: u32,
    height: u32,
    format: vk.VkFormat,

    /// Upload a libktx-loaded texture into device-local Vulkan memory
    /// and return a sampler-ready resource. Callers typically hand
    /// this straight into a descriptor set write.
    ///
    /// Layout transitions:
    ///   UNDEFINED → TRANSFER_DST_OPTIMAL  (barrier 1)
    ///   <copy>
    ///   TRANSFER_DST_OPTIMAL → SHADER_READ_ONLY_OPTIMAL  (barrier 2)
    ///
    /// The transient command pool + one-shot command buffer are
    /// destroyed before init returns; queue is fenced + waited on so
    /// the staging buffer is safe to free.
    pub fn init(gpu: *const gpu_mod.GpuContext, src: ktx.Texture2) !Texture {
        if (src.needsTranscode()) return VulkanError.UnsupportedTextureFormat;
        const fmt: vk.VkFormat = @intCast(src.vkFormat());
        if (fmt == vk.VK_FORMAT_UNDEFINED) return VulkanError.UnsupportedTextureFormat;

        const w = src.width();
        const h = src.height();
        std.debug.assert(w > 0 and h > 0);

        // 1. Create the device-local VkImage via VMA.
        const image_ci: vma.c.VkImageCreateInfo = .{
            .sType = vma.c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = vma.c.VK_IMAGE_TYPE_2D,
            .format = @intCast(fmt),
            .extent = .{ .width = w, .height = h, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vma.c.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vma.c.VK_IMAGE_TILING_OPTIMAL,
            .usage = vma.c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | vma.c.VK_IMAGE_USAGE_SAMPLED_BIT,
            .sharingMode = vma.c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = vma.c.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        const u = vma.mapUsage(.device_local);
        const alloc_ci: vma.c.VmaAllocationCreateInfo = .{
            .flags = u.flags,
            .usage = u.vma_usage,
            .requiredFlags = 0,
            .preferredFlags = 0,
            .memoryTypeBits = 0,
            .pool = null,
            .pUserData = null,
            .priority = 0,
        };
        var image: vma.c.VkImage = null;
        var allocation: vma.c.VmaAllocation = null;
        vma.check(vma.c.vmaCreateImage(
            gpu.allocator.raw,
            &image_ci,
            &alloc_ci,
            &image,
            &allocation,
            null,
        )) catch return VulkanError.ImageCreationFailed;
        errdefer vma.c.vmaDestroyImage(gpu.allocator.raw, image, allocation);

        // 2. Staging buffer — host-visible, sequential write, sized to
        // the source data.
        const data = src.data();
        var staging = try buffer_mod.Buffer.initWith(gpu, data.len, .{
            .usage = vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            .memory = .host_seq_write,
        });
        defer staging.deinit();
        staging.upload(data);

        // 3. One-shot command buffer for the upload + barriers.
        const pool = try createTransientPool(gpu.device, gpu.families.graphics);
        defer vk.vkDestroyCommandPool(gpu.device, pool, null);
        const cb = try allocateOneShotCB(gpu.device, pool);

        try recordUpload(cb, image, @ptrCast(staging.handle), w, h);

        try submitAndWait(gpu.device, gpu.graphics_queue, cb);

        // 4. View + sampler.
        const view = try createView(gpu.device, @ptrCast(image), fmt);
        errdefer vk.vkDestroyImageView(gpu.device, view, null);

        const sampler = try createSampler(gpu.device);
        errdefer vk.vkDestroySampler(gpu.device, sampler, null);

        return .{
            .device = gpu.device,
            .image = image,
            .allocation = allocation,
            .allocator = gpu.allocator.raw,
            .view = view,
            .sampler = sampler,
            .width = w,
            .height = h,
            .format = fmt,
        };
    }

    pub fn deinit(self: *Texture) void {
        vk.vkDestroySampler(self.device, self.sampler, null);
        vk.vkDestroyImageView(self.device, self.view, null);
        vma.c.vmaDestroyImage(self.allocator, self.image, self.allocation);
    }

    /// `VkDescriptorImageInfo` ready to drop into a descriptor write.
    /// Layout assumed SHADER_READ_ONLY_OPTIMAL — true post-init.
    pub fn descriptorImageInfo(self: *const Texture) vk.VkDescriptorImageInfo {
        return .{
            .sampler = self.sampler,
            .imageView = self.view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
    }
};

fn createTransientPool(device: vk.VkDevice, family: u32) !vk.VkCommandPool {
    const ci = vk.VkCommandPoolCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .pNext = null,
        .flags = vk.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
        .queueFamilyIndex = family,
    };
    var pool: vk.VkCommandPool = undefined;
    try types.check(
        vk.vkCreateCommandPool(device, &ci, null, &pool),
        VulkanError.CommandPoolCreationFailed,
    );
    return pool;
}

fn allocateOneShotCB(device: vk.VkDevice, pool: vk.VkCommandPool) !vk.VkCommandBuffer {
    const ai = vk.VkCommandBufferAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = pool,
        .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    var cb: vk.VkCommandBuffer = undefined;
    try types.check(
        vk.vkAllocateCommandBuffers(device, &ai, &cb),
        VulkanError.CommandBufferAllocationFailed,
    );
    return cb;
}

fn recordUpload(
    cb: vk.VkCommandBuffer,
    image: vma.c.VkImage,
    staging: vk.VkBuffer,
    width: u32,
    height: u32,
) !void {
    const begin = vk.VkCommandBufferBeginInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    try types.check(
        vk.vkBeginCommandBuffer(cb, &begin),
        VulkanError.CommandBufferBeginFailed,
    );

    // Barrier 1: UNDEFINED → TRANSFER_DST_OPTIMAL
    const to_dst = vk.VkImageMemoryBarrier{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = 0,
        .dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
        .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .image = @ptrCast(image),
        .subresourceRange = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    vk.vkCmdPipelineBarrier(
        cb,
        vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
        0,
        0, null,
        0, null,
        1, &to_dst,
    );

    // Copy staging buffer → image.
    const region = vk.VkBufferImageCopy{
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
        .imageExtent = .{ .width = width, .height = height, .depth = 1 },
    };
    vk.vkCmdCopyBufferToImage(
        cb,
        staging,
        @ptrCast(image),
        vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        1,
        &region,
    );

    // Barrier 2: TRANSFER_DST_OPTIMAL → SHADER_READ_ONLY_OPTIMAL
    const to_read = vk.VkImageMemoryBarrier{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
        .oldLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .newLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .image = @ptrCast(image),
        .subresourceRange = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    vk.vkCmdPipelineBarrier(
        cb,
        vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
        vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        0,
        0, null,
        0, null,
        1, &to_read,
    );

    try types.check(
        vk.vkEndCommandBuffer(cb),
        VulkanError.CommandBufferEndFailed,
    );
}

fn submitAndWait(device: vk.VkDevice, queue: vk.VkQueue, cb: vk.VkCommandBuffer) !void {
    _ = device; // queue-wait-idle handles fencing; device kept for future fence-based path
    var cb_local = cb;
    const submit = vk.VkSubmitInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = null,
        .waitSemaphoreCount = 0,
        .pWaitSemaphores = null,
        .pWaitDstStageMask = null,
        .commandBufferCount = 1,
        .pCommandBuffers = &cb_local,
        .signalSemaphoreCount = 0,
        .pSignalSemaphores = null,
    };
    try types.check(
        vk.vkQueueSubmit(queue, 1, &submit, null),
        VulkanError.QueueSubmitFailed,
    );
    // Wait synchronously — texture upload runs at init time, frame
    // budget doesn't apply. M14.3+ may move to a fence + per-frame
    // poll if texture streaming is needed.
    _ = vk.vkQueueWaitIdle(queue);
}

fn createView(device: vk.VkDevice, image: vk.VkImage, format: vk.VkFormat) !vk.VkImageView {
    const ci = vk.VkImageViewCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .image = image,
        .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
        .format = format,
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
    var view: vk.VkImageView = undefined;
    try types.check(
        vk.vkCreateImageView(device, &ci, null, &view),
        VulkanError.ImageViewCreationFailed,
    );
    return view;
}

fn createSampler(device: vk.VkDevice) !vk.VkSampler {
    // M14.2c v1: linear filter, REPEAT wrap, no anisotropy. Anisotropy
    // requires a device feature toggle; enabling it now is premature
    // — re-evaluate when M14.3 surfaces ground/wood textures viewed at
    // shallow angles.
    const ci = vk.VkSamplerCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .magFilter = vk.VK_FILTER_LINEAR,
        .minFilter = vk.VK_FILTER_LINEAR,
        .mipmapMode = vk.VK_SAMPLER_MIPMAP_MODE_LINEAR,
        .addressModeU = vk.VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .addressModeV = vk.VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .mipLodBias = 0,
        .anisotropyEnable = vk.VK_FALSE,
        .maxAnisotropy = 1,
        .compareEnable = vk.VK_FALSE,
        .compareOp = vk.VK_COMPARE_OP_ALWAYS,
        .minLod = 0,
        .maxLod = 0,
        .borderColor = vk.VK_BORDER_COLOR_INT_OPAQUE_BLACK,
        .unnormalizedCoordinates = vk.VK_FALSE,
    };
    var sampler: vk.VkSampler = undefined;
    try types.check(
        vk.vkCreateSampler(device, &ci, null, &sampler),
        VulkanError.SamplerCreationFailed,
    );
    return sampler;
}
