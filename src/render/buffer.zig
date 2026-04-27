//! Plain VkBuffer + VkDeviceMemory pair, host-visible and coherent, with a
//! persistent map. No VMA at M2.3 — total resident GPU memory is small
//! (one plane mesh + a 128 B UBO) and adding an allocator now is yak-shaving.
//! Switch to VMA-equivalent pooling in M5+ when there are ≥ hundreds of
//! buffers.

const std = @import("std");
const types = @import("vulkan_types.zig");
const gpu_mod = @import("gpu.zig");

const vk = types.vk;
const VulkanError = types.VulkanError;

pub const Buffer = struct {
    handle: vk.VkBuffer,
    memory: vk.VkDeviceMemory,
    size: vk.VkDeviceSize,
    mapped: [*]u8,
    device: vk.VkDevice,

    pub fn init(
        gpu: *const gpu_mod.GpuContext,
        size: vk.VkDeviceSize,
        usage: vk.VkBufferUsageFlags,
    ) !Buffer {
        const ci = vk.VkBufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = size,
            .usage = usage,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };
        var handle: vk.VkBuffer = undefined;
        try types.check(
            vk.vkCreateBuffer(gpu.device, &ci, null, &handle),
            VulkanError.BufferCreationFailed,
        );
        errdefer vk.vkDestroyBuffer(gpu.device, handle, null);

        var req: vk.VkMemoryRequirements = undefined;
        vk.vkGetBufferMemoryRequirements(gpu.device, handle, &req);

        const mem_type_idx = try findMemoryType(
            gpu.physical_device,
            req.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );

        const ai = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = req.size,
            .memoryTypeIndex = mem_type_idx,
        };
        var memory: vk.VkDeviceMemory = undefined;
        try types.check(
            vk.vkAllocateMemory(gpu.device, &ai, null, &memory),
            VulkanError.MemoryAllocationFailed,
        );
        errdefer vk.vkFreeMemory(gpu.device, memory, null);

        try types.check(
            vk.vkBindBufferMemory(gpu.device, handle, memory, 0),
            VulkanError.MemoryAllocationFailed,
        );

        var raw: ?*anyopaque = null;
        try types.check(
            vk.vkMapMemory(gpu.device, memory, 0, vk.VK_WHOLE_SIZE, 0, &raw),
            VulkanError.MemoryMapFailed,
        );

        return .{
            .handle = handle,
            .memory = memory,
            .size = size,
            .mapped = @ptrCast(@alignCast(raw.?)),
            .device = gpu.device,
        };
    }

    pub fn deinit(self: *Buffer) void {
        vk.vkUnmapMemory(self.device, self.memory);
        vk.vkDestroyBuffer(self.device, self.handle, null);
        vk.vkFreeMemory(self.device, self.memory, null);
    }

    /// Copy bytes into the persistent map. Coherent memory needs no flush.
    pub fn upload(self: *Buffer, bytes: []const u8) void {
        std.debug.assert(bytes.len <= self.size);
        @memcpy(self.mapped[0..bytes.len], bytes);
    }
};

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
