//! Plain VkBuffer + VmaAllocation pair, with an optional persistent
//! host map. Backed by VMA (vma.zig); replaces the prior per-resource
//! `vkAllocateMemory` pattern that hit Vulkan's allocation-count
//! ceiling at content scale.
//!
//! Public API stays the same shape callers used pre-VMA — `Buffer.init`
//! returns something with `handle`, `upload`, and `deinit` — so the 14
//! call sites across box/instanced/mesh_palette/cluster_merge/ocean/
//! wind_arrows didn't need to change.
//!
//! Default memory choice is `host_seq_write` (HOST_VISIBLE + COHERENT,
//! mapped) which matches every existing buffer's usage. New callers
//! that want device-local backing pass `.memory = .device_local` via
//! the `initWith` overload.

const std = @import("std");
const types = @import("vulkan_types.zig");
const gpu_mod = @import("gpu.zig");
const vma = @import("vma");

const vk = types.vk;
const VulkanError = types.VulkanError;

pub const Buffer = struct {
    handle: vk.VkBuffer,
    allocation: vma.c.VmaAllocation,
    size: vk.VkDeviceSize,
    /// Slice of mapped bytes for host-visible buffers. Empty for
    /// device-local buffers; assert in `upload`.
    mapped: []u8,
    allocator: vma.c.VmaAllocator,

    pub const Options = struct {
        usage: vk.VkBufferUsageFlags,
        memory: vma.MemoryUsage = .host_seq_write,
    };

    /// Default-path init matching the pre-VMA signature: HOST_VISIBLE +
    /// COHERENT + persistent map. Every existing caller keeps working.
    pub fn init(
        gpu: *const gpu_mod.GpuContext,
        size: vk.VkDeviceSize,
        usage: vk.VkBufferUsageFlags,
    ) !Buffer {
        return initWith(gpu, size, .{ .usage = usage });
    }

    /// Extended init for callers that want device-local backing
    /// (vertex/index buffers loaded once via staging, SSBOs the GPU
    /// owns) or a different memory strategy.
    pub fn initWith(
        gpu: *const gpu_mod.GpuContext,
        size: vk.VkDeviceSize,
        opts: Options,
    ) !Buffer {
        const buf_ci = vma.c.VkBufferCreateInfo{
            .sType = vma.c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = size,
            .usage = opts.usage,
            .sharingMode = vma.c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };
        const u = vma.mapUsage(opts.memory);
        const alloc_ci = vma.c.VmaAllocationCreateInfo{
            .flags = u.flags,
            .usage = u.vma_usage,
            .requiredFlags = 0,
            .preferredFlags = 0,
            .memoryTypeBits = 0,
            .pool = null,
            .pUserData = null,
            .priority = 0,
        };
        var handle: vma.c.VkBuffer = null;
        var allocation: vma.c.VmaAllocation = null;
        var alloc_info: vma.c.VmaAllocationInfo = undefined;
        vma.check(vma.c.vmaCreateBuffer(
            gpu.allocator.raw,
            &buf_ci,
            &alloc_ci,
            &handle,
            &allocation,
            &alloc_info,
        )) catch return VulkanError.BufferCreationFailed;

        const mapped: []u8 = if (alloc_info.pMappedData) |p|
            @as([*]u8, @ptrCast(p))[0..size]
        else
            &[_]u8{};

        return .{
            .handle = @ptrCast(handle),
            .allocation = allocation,
            .size = size,
            .mapped = mapped,
            .allocator = gpu.allocator.raw,
        };
    }

    pub fn deinit(self: *Buffer) void {
        vma.c.vmaDestroyBuffer(self.allocator, @ptrCast(self.handle), self.allocation);
    }

    /// Copy bytes into the persistent map. Coherent memory needs no
    /// flush. Asserts the buffer is host-visible.
    pub fn upload(self: *Buffer, bytes: []const u8) void {
        std.debug.assert(self.mapped.len > 0); // device-local buffers can't be uploaded directly
        std.debug.assert(bytes.len <= self.mapped.len);
        @memcpy(self.mapped[0..bytes.len], bytes);
    }
};
