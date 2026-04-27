//! M2.3 ocean pass: a flat tessellated XZ plane drawn with a UBO-driven
//! camera. Owns the mesh, pipeline, descriptor pool/set, and a UBO buffer.
//!
//! M2.4 will move the vertex displacement into the shader and wire a second
//! UBO with wave parameters from `data/waves/*.yaml`. M2.5 adds shading.

const std = @import("std");
const types = @import("vulkan_types.zig");
const gpu_mod = @import("gpu.zig");
const buffer_mod = @import("buffer.zig");
const mesh_mod = @import("mesh.zig");
const pipeline_mod = @import("pipeline.zig");
const shader_mod = @import("shader.zig");
const camera_mod = @import("camera.zig");

const vk = types.vk;
const VulkanError = types.VulkanError;

// SPIR-V blobs produced by build.zig's glslc step. The `align(4)` and `.*`
// dereference force the embedded bytes into a 4-aligned slot in the data
// segment, which Vulkan requires for `pCode`.
const ocean_vert_spv align(4) = @embedFile("ocean_vert_spv").*;
const ocean_frag_spv align(4) = @embedFile("ocean_frag_spv").*;

pub const Config = struct {
    plane_resolution: u32 = 256,
    plane_size_m: f32 = 1024.0,
};

pub const Ocean = struct {
    gpa: std.mem.Allocator,
    device: vk.VkDevice,

    mesh: mesh_mod.Mesh,
    pipeline: pipeline_mod.Pipeline,

    ubo_buffer: buffer_mod.Buffer,
    descriptor_pool: vk.VkDescriptorPool,
    descriptor_set: vk.VkDescriptorSet,

    pub fn init(
        gpa: std.mem.Allocator,
        gpu: *const gpu_mod.GpuContext,
        render_pass: vk.VkRenderPass,
        cfg: Config,
    ) !Ocean {
        var mesh = try mesh_mod.generatePlane(gpa, gpu, .{
            .resolution = cfg.plane_resolution,
            .size_m = cfg.plane_size_m,
        });
        errdefer mesh.deinit();

        const vert_module = try shader_mod.fromSpv(gpu.device, &ocean_vert_spv);
        defer vk.vkDestroyShaderModule(gpu.device, vert_module, null);
        const frag_module = try shader_mod.fromSpv(gpu.device, &ocean_frag_spv);
        defer vk.vkDestroyShaderModule(gpu.device, frag_module, null);

        var pipeline = try pipeline_mod.create(gpu.device, render_pass, vert_module, frag_module);
        errdefer pipeline.deinit();

        var ubo = try buffer_mod.Buffer.init(
            gpu,
            @sizeOf(camera_mod.Ubo),
            vk.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        );
        errdefer ubo.deinit();

        const pool = try createDescriptorPool(gpu.device);
        errdefer vk.vkDestroyDescriptorPool(gpu.device, pool, null);

        const set = try allocateDescriptorSet(gpu.device, pool, pipeline.descriptor_set_layout);
        writeUboDescriptor(gpu.device, set, ubo.handle);

        return .{
            .gpa = gpa,
            .device = gpu.device,
            .mesh = mesh,
            .pipeline = pipeline,
            .ubo_buffer = ubo,
            .descriptor_pool = pool,
            .descriptor_set = set,
        };
    }

    pub fn deinit(self: *Ocean) void {
        // Descriptor sets are freed implicitly when the pool is destroyed.
        vk.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
        self.ubo_buffer.deinit();
        self.pipeline.deinit();
        self.mesh.deinit();
    }

    /// Update the UBO with a new camera. Coherent host memory; visible to
    /// the GPU on the next vkQueueSubmit.
    pub fn updateCamera(self: *Ocean, camera: camera_mod.Camera) void {
        const ubo = camera_mod.Ubo.fromCamera(camera);
        self.ubo_buffer.upload(std.mem.asBytes(&ubo));
    }

    /// Record the ocean draw into `cb`. Must be called inside an active
    /// render pass; viewport/scissor are dynamic and set here from `extent`.
    pub fn record(self: *Ocean, cb: vk.VkCommandBuffer, extent: vk.VkExtent2D) void {
        vk.vkCmdBindPipeline(cb, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline.handle);

        const viewport = vk.VkViewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(extent.width),
            .height = @floatFromInt(extent.height),
            .minDepth = 0,
            .maxDepth = 1,
        };
        vk.vkCmdSetViewport(cb, 0, 1, &viewport);

        const scissor = vk.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = extent,
        };
        vk.vkCmdSetScissor(cb, 0, 1, &scissor);

        vk.vkCmdBindDescriptorSets(
            cb,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.pipeline.pipeline_layout,
            0,
            1,
            &self.descriptor_set,
            0,
            null,
        );

        self.mesh.bindAndDraw(cb);
    }
};

fn createDescriptorPool(device: vk.VkDevice) !vk.VkDescriptorPool {
    const sizes = [_]vk.VkDescriptorPoolSize{.{
        .type = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
    }};
    const ci = vk.VkDescriptorPoolCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .maxSets = 1,
        .poolSizeCount = sizes.len,
        .pPoolSizes = &sizes,
    };
    var pool: vk.VkDescriptorPool = undefined;
    try types.check(
        vk.vkCreateDescriptorPool(device, &ci, null, &pool),
        VulkanError.DescriptorPoolCreationFailed,
    );
    return pool;
}

fn allocateDescriptorSet(
    device: vk.VkDevice,
    pool: vk.VkDescriptorPool,
    layout: vk.VkDescriptorSetLayout,
) !vk.VkDescriptorSet {
    const ai = vk.VkDescriptorSetAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &layout,
    };
    var set: vk.VkDescriptorSet = undefined;
    try types.check(
        vk.vkAllocateDescriptorSets(device, &ai, &set),
        VulkanError.DescriptorSetAllocationFailed,
    );
    return set;
}

fn writeUboDescriptor(device: vk.VkDevice, set: vk.VkDescriptorSet, ubo: vk.VkBuffer) void {
    const buffer_info = vk.VkDescriptorBufferInfo{
        .buffer = ubo,
        .offset = 0,
        .range = vk.VK_WHOLE_SIZE,
    };
    const write = vk.VkWriteDescriptorSet{
        .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .pNext = null,
        .dstSet = set,
        .dstBinding = 0,
        .dstArrayElement = 0,
        .descriptorCount = 1,
        .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .pImageInfo = null,
        .pBufferInfo = &buffer_info,
        .pTexelBufferView = null,
    };
    vk.vkUpdateDescriptorSets(device, 1, &write, 0, null);
}
