//! Thin Zig binding around AMD's Vulkan Memory Allocator (VMA).
//!
//! Per `feedback_thin_c_bindings.md` + `feedback_prefer_widely_used_oss.md`:
//! we vendor VMA's single-header source under
//! vendor/VulkanMemoryAllocator (v3.3.0) and bind against its own C
//! API. No zig-vulkan-memory-allocator wrapper layer.
//!
//! Vendor-neutral: VMA only uses standard Vulkan APIs and works on
//! NVIDIA / AMD / Intel / mobile. See
//! `feedback_vendor_agnostic_graphics.md`.
//!
//! This file owns:
//!   - Raw `c` re-export of `vk_mem_alloc.h`
//!   - `Allocator` handle (one per VkDevice)
//!   - `MemoryUsage` enum + mapping helper for the common usage
//!     patterns the project uses (host-mapped sequential write,
//!     device-local).
//!   - VkResult → Error translation
//!
//! Per-resource wrappers (Buffer, Image) live in `buffer.zig` and
//! `image.zig` so the project's Buffer API stays unchanged across the
//! VMA refactor.

const std = @import("std");

pub const c = @cImport({
    @cInclude("vulkan/vulkan.h");
    @cInclude("vk_mem_alloc.h");
});

pub const Error = error{
    OutOfHostMemory,
    OutOfDeviceMemory,
    InitializationFailed,
    MemoryMapFailed,
    InvalidExternalHandle,
    Fragmentation,
    InvalidOpaqueCaptureAddress,
    Unknown,
};

pub fn check(code: c.VkResult) Error!void {
    return switch (code) {
        c.VK_SUCCESS => {},
        c.VK_ERROR_OUT_OF_HOST_MEMORY => Error.OutOfHostMemory,
        c.VK_ERROR_OUT_OF_DEVICE_MEMORY => Error.OutOfDeviceMemory,
        c.VK_ERROR_INITIALIZATION_FAILED => Error.InitializationFailed,
        c.VK_ERROR_MEMORY_MAP_FAILED => Error.MemoryMapFailed,
        c.VK_ERROR_INVALID_EXTERNAL_HANDLE => Error.InvalidExternalHandle,
        c.VK_ERROR_FRAGMENTATION => Error.Fragmentation,
        c.VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS => Error.InvalidOpaqueCaptureAddress,
        else => Error.Unknown,
    };
}

/// Owning handle around `VmaAllocator`. Created once per `VkDevice` at
/// GPU context init, destroyed at shutdown. All buffers and images
/// route allocations through this handle.
pub const Allocator = struct {
    raw: c.VmaAllocator,

    pub const InitOptions = struct {
        instance: c.VkInstance,
        physical_device: c.VkPhysicalDevice,
        device: c.VkDevice,
        /// Vulkan API version the device was created with. Match
        /// gpu.zig (currently `c.VK_API_VERSION_1_3`).
        api_version: u32,
    };

    pub fn init(opts: InitOptions) Error!Allocator {
        const ci: c.VmaAllocatorCreateInfo = .{
            .flags = 0,
            .physicalDevice = opts.physical_device,
            .device = opts.device,
            .preferredLargeHeapBlockSize = 0, // VMA default (256 MB)
            .pAllocationCallbacks = null,
            .pDeviceMemoryCallbacks = null,
            .pHeapSizeLimit = null,
            .pVulkanFunctions = null, // VMA_STATIC_VULKAN_FUNCTIONS=1 in vma_impl.cpp
            .instance = opts.instance,
            .vulkanApiVersion = opts.api_version,
            .pTypeExternalMemoryHandleTypes = null,
        };
        var raw: c.VmaAllocator = null;
        try check(c.vmaCreateAllocator(&ci, &raw));
        return .{ .raw = raw };
    }

    pub fn deinit(self: *Allocator) void {
        c.vmaDestroyAllocator(self.raw);
        self.* = undefined;
    }
};

/// Suggested memory placement for a resource. Maps to VMA's auto-pick
/// usage + create flags. Covers what buffer.zig and image.zig need.
pub const MemoryUsage = enum {
    /// HOST_VISIBLE + persistent map, sequential write pattern.
    /// Use for: per-frame UBOs, vertex/index buffers updated each
    /// frame, staging buffers feeding device-local resources.
    host_seq_write,
    /// HOST_VISIBLE + persistent map, random access.
    /// Use for: rare; readbacks, debug uploads.
    host_random_access,
    /// DEVICE_LOCAL only. No host map.
    /// Use for: vertex/index buffers loaded once and never touched
    /// again; VkImage backing memory; SSBOs the GPU owns.
    device_local,
};

/// Translate a `MemoryUsage` to the (vma_usage, flags) pair VMA wants.
pub fn mapUsage(usage: MemoryUsage) struct {
    vma_usage: c.VmaMemoryUsage,
    flags: c.VmaAllocationCreateFlags,
} {
    return switch (usage) {
        .host_seq_write => .{
            .vma_usage = c.VMA_MEMORY_USAGE_AUTO_PREFER_HOST,
            .flags = c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT |
                c.VMA_ALLOCATION_CREATE_MAPPED_BIT,
        },
        .host_random_access => .{
            .vma_usage = c.VMA_MEMORY_USAGE_AUTO_PREFER_HOST,
            .flags = c.VMA_ALLOCATION_CREATE_HOST_ACCESS_RANDOM_BIT |
                c.VMA_ALLOCATION_CREATE_MAPPED_BIT,
        },
        .device_local => .{
            .vma_usage = c.VMA_MEMORY_USAGE_AUTO_PREFER_DEVICE,
            .flags = 0,
        },
    };
}
