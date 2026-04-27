//! VkShaderModule from a 4-byte-aligned SPIR-V byte slice.
//!
//! Caller must pass a slice with at least 4-byte alignment. The expected
//! pattern at the call site is:
//!
//!     const spv align(4) = @embedFile("ocean_vert_spv").*;
//!     const m = try shader.fromSpv(device, &spv);
//!
//! The `align(4)` annotation on the const decl forces the embedded blob into
//! a 4-aligned slot in the data segment, which Vulkan requires for `pCode`.

const std = @import("std");
const types = @import("vulkan_types.zig");

const vk = types.vk;
const VulkanError = types.VulkanError;

pub fn fromSpv(device: vk.VkDevice, spv: []align(4) const u8) !vk.VkShaderModule {
    std.debug.assert(spv.len % 4 == 0);
    const ci = vk.VkShaderModuleCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .codeSize = spv.len,
        .pCode = @ptrCast(spv.ptr),
    };
    var m: vk.VkShaderModule = undefined;
    try types.check(
        vk.vkCreateShaderModule(device, &ci, null, &m),
        VulkanError.ShaderModuleCreationFailed,
    );
    return m;
}
