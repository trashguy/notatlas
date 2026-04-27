//! Vulkan + GLFW C interop and shared error/type aliases for the render layer.
//!
//! Window/input use the zglfw Zig wrapper. Raw Vulkan goes through `vk` here.

const std = @import("std");

pub const vk = @cImport({
    @cInclude("vulkan/vulkan.h");
});

pub const VulkanError = error{
    LayerEnumerationFailed,
    InstanceCreationFailed,
    DebugMessengerCreationFailed,
    SurfaceCreationFailed,
    NoVulkanDevices,
    NoSuitableDevice,
    QueueFamilyNotFound,
    DeviceCreationFailed,
    SwapchainCreationFailed,
    SurfaceFormatEnumerationFailed,
    ImageViewCreationFailed,
    RenderPassCreationFailed,
    FramebufferCreationFailed,
    CommandPoolCreationFailed,
    CommandBufferAllocationFailed,
    CommandBufferBeginFailed,
    CommandBufferEndFailed,
    SemaphoreCreationFailed,
    FenceCreationFailed,
    AcquireImageFailed,
    QueueSubmitFailed,
    QueuePresentFailed,
};

pub const QueueFamilies = struct {
    graphics: u32,
    present: u32,
};

pub fn check(result: vk.VkResult, comptime err: VulkanError) VulkanError!void {
    if (result != vk.VK_SUCCESS) return err;
}
