//! M2.4 ocean pass: tessellated XZ plane displaced in the vertex shader by
//! the Gerstner port of `wave_query.waveDisplacement`. Owns the mesh, the
//! pipeline, two UBOs (camera + waves), and the descriptor pool/set.
//!
//! M2.5 will add fragment shading (foam, fresnel, underwater fog).

const std = @import("std");
const notatlas = @import("notatlas");
const types = @import("vulkan_types.zig");
const gpu_mod = @import("gpu.zig");
const buffer_mod = @import("buffer.zig");
const mesh_mod = @import("mesh.zig");
const pipeline_mod = @import("pipeline.zig");
const shader_mod = @import("shader.zig");
const camera_mod = @import("camera.zig");
const waves_mod = @import("waves.zig");

const vk = types.vk;
const VulkanError = types.VulkanError;
const wave = notatlas.wave_query;

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

    camera_ubo: buffer_mod.Buffer,
    wave_ubo: buffer_mod.Buffer,
    descriptor_pool: vk.VkDescriptorPool,
    descriptor_set: vk.VkDescriptorSet,

    /// Cached wave UBO state. `setWaveParams` populates the param fields;
    /// `updateTime` refreshes `time` each frame without rebuilding components.
    wave_state: waves_mod.Ubo,

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

        var camera_ubo = try buffer_mod.Buffer.init(
            gpu,
            @sizeOf(camera_mod.Ubo),
            vk.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        );
        errdefer camera_ubo.deinit();

        var wave_ubo = try buffer_mod.Buffer.init(
            gpu,
            @sizeOf(waves_mod.Ubo),
            vk.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        );
        errdefer wave_ubo.deinit();

        const pool = try createDescriptorPool(gpu.device);
        errdefer vk.vkDestroyDescriptorPool(gpu.device, pool, null);

        const set = try allocateDescriptorSet(gpu.device, pool, pipeline.descriptor_set_layout);
        writeUboDescriptors(gpu.device, set, camera_ubo.handle, wave_ubo.handle);

        // Default wave state = flat (count=0). Caller should `setWaveParams`
        // before rendering if they want surface motion.
        const initial_wave_state: waves_mod.Ubo = .{
            .count = 0,
            .time = 0,
            .components = std.mem.zeroes([waves_mod.MAX_COMPONENTS]waves_mod.GerstnerUbo),
        };
        var ocean: Ocean = .{
            .gpa = gpa,
            .device = gpu.device,
            .mesh = mesh,
            .pipeline = pipeline,
            .camera_ubo = camera_ubo,
            .wave_ubo = wave_ubo,
            .descriptor_pool = pool,
            .descriptor_set = set,
            .wave_state = initial_wave_state,
        };
        ocean.flushWaveUbo();
        return ocean;
    }

    pub fn deinit(self: *Ocean) void {
        // Descriptor sets are freed implicitly when the pool is destroyed.
        vk.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
        self.wave_ubo.deinit();
        self.camera_ubo.deinit();
        self.pipeline.deinit();
        self.mesh.deinit();
    }

    /// Update the camera UBO. Coherent host memory; visible to the GPU on the
    /// next vkQueueSubmit.
    pub fn updateCamera(self: *Ocean, camera: camera_mod.Camera) void {
        const ubo = camera_mod.Ubo.fromCamera(camera);
        self.camera_ubo.upload(std.mem.asBytes(&ubo));
    }

    /// Replace the wave parameters. Recomputes phases from the seed and
    /// uploads the full UBO. Cheap (~272 bytes); call on hot-reload, not
    /// per frame.
    pub fn setWaveParams(self: *Ocean, params: wave.WaveParams) void {
        self.wave_state = waves_mod.Ubo.fromParams(params, self.wave_state.time);
        self.flushWaveUbo();
    }

    /// Advance simulated time. Cheap path: only the `time` field is rewritten.
    pub fn updateTime(self: *Ocean, t: f32) void {
        self.wave_state.time = t;
        self.flushWaveUbo();
    }

    fn flushWaveUbo(self: *Ocean) void {
        self.wave_ubo.upload(std.mem.asBytes(&self.wave_state));
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
    // 2 UBOs (camera + waves) in 1 set.
    const sizes = [_]vk.VkDescriptorPoolSize{.{
        .type = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 2,
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

fn writeUboDescriptors(
    device: vk.VkDevice,
    set: vk.VkDescriptorSet,
    camera: vk.VkBuffer,
    waves: vk.VkBuffer,
) void {
    const camera_info = vk.VkDescriptorBufferInfo{
        .buffer = camera,
        .offset = 0,
        .range = vk.VK_WHOLE_SIZE,
    };
    const wave_info = vk.VkDescriptorBufferInfo{
        .buffer = waves,
        .offset = 0,
        .range = vk.VK_WHOLE_SIZE,
    };
    const writes = [_]vk.VkWriteDescriptorSet{
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &camera_info,
            .pTexelBufferView = null,
        },
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = 1,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &wave_info,
            .pTexelBufferView = null,
        },
    };
    vk.vkUpdateDescriptorSets(device, writes.len, &writes, 0, null);
}
