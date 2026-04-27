//! M2 ocean pass: a single fullscreen-triangle fragment shader that
//! raymarches the deterministic wave heightfield, shades it with Schlick
//! fresnel × atmosphere(reflect) + scatter + foam + underwater fog, and
//! draws the sky for rays pointing above the horizon.
//!
//! No mesh — `wave_query.zig` is the source of truth for surface heights;
//! the GPU re-evaluates the same kernel per pixel. Buoyancy queries
//! (M3+) hit the CPU function; ships/structures (M5+) draw on top of the
//! depth buffer this pass writes.

const std = @import("std");
const notatlas = @import("notatlas");
const types = @import("vulkan_types.zig");
const gpu_mod = @import("gpu.zig");
const buffer_mod = @import("buffer.zig");
const pipeline_mod = @import("pipeline.zig");
const shader_mod = @import("shader.zig");
const camera_mod = @import("camera.zig");
const waves_mod = @import("waves.zig");
const ocean_uniform_mod = @import("ocean_uniform.zig");

const vk = types.vk;
const VulkanError = types.VulkanError;
const wave = notatlas.wave_query;
const ocean_params_mod = notatlas.ocean_params;

const fullscreen_vert_spv align(4) = @embedFile("fullscreen_vert_spv").*;
const water_frag_spv align(4) = @embedFile("water_frag_spv").*;

/// Reserved for future renderer-level config (MSAA samples, ocean tile
/// strategy, etc). Iteration count moved to `WaveParams` — same value
/// drives CPU buoyancy and GPU raymarch so the two surfaces agree.
pub const Config = struct {};

pub const Ocean = struct {
    gpa: std.mem.Allocator,
    device: vk.VkDevice,

    pipeline: pipeline_mod.Pipeline,

    camera_ubo: buffer_mod.Buffer,
    wave_ubo: buffer_mod.Buffer,
    ocean_ubo: buffer_mod.Buffer,
    descriptor_pool: vk.VkDescriptorPool,
    descriptor_set: vk.VkDescriptorSet,

    /// Cached wave UBO state. Hot-path `updateTime` only rewrites the time
    /// field; `setWaveParams` rebuilds the rest (cheap — 64 B blit).
    wave_state: waves_mod.Ubo,
    wave_params: wave.WaveParams,

    pub fn init(
        gpa: std.mem.Allocator,
        gpu: *const gpu_mod.GpuContext,
        render_pass: vk.VkRenderPass,
        _: Config,
    ) !Ocean {
        const vert_module = try shader_mod.fromSpv(gpu.device, &fullscreen_vert_spv);
        defer vk.vkDestroyShaderModule(gpu.device, vert_module, null);
        const frag_module = try shader_mod.fromSpv(gpu.device, &water_frag_spv);
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

        var ocean_ubo = try buffer_mod.Buffer.init(
            gpu,
            @sizeOf(ocean_uniform_mod.Ubo),
            vk.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        );
        errdefer ocean_ubo.deinit();

        const pool = try createDescriptorPool(gpu.device);
        errdefer vk.vkDestroyDescriptorPool(gpu.device, pool, null);

        const set = try allocateDescriptorSet(gpu.device, pool, pipeline.descriptor_set_layout);
        writeUboDescriptors(gpu.device, set, camera_ubo.handle, wave_ubo.handle, ocean_ubo.handle);

        // Defaults so the frag never reads uninitialized memory — caller
        // is expected to overwrite via setWaveParams / setOceanParams
        // before rendering.
        const initial_params = wave.calm;
        const initial_wave_state = waves_mod.Ubo.fromParams(initial_params, 0);

        var ocean: Ocean = .{
            .gpa = gpa,
            .device = gpu.device,
            .pipeline = pipeline,
            .camera_ubo = camera_ubo,
            .wave_ubo = wave_ubo,
            .ocean_ubo = ocean_ubo,
            .descriptor_pool = pool,
            .descriptor_set = set,
            .wave_state = initial_wave_state,
            .wave_params = initial_params,
        };
        ocean.flushWaveUbo();
        ocean.setOceanParams(ocean_params_mod.OceanParams.default);
        return ocean;
    }

    pub fn deinit(self: *Ocean) void {
        vk.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
        self.ocean_ubo.deinit();
        self.wave_ubo.deinit();
        self.camera_ubo.deinit();
        self.pipeline.deinit();
    }

    pub fn updateCamera(self: *Ocean, camera: camera_mod.Camera) void {
        const ubo = camera_mod.Ubo.fromCamera(camera);
        self.camera_ubo.upload(std.mem.asBytes(&ubo));
    }

    /// Replace wave kernel params. Cheap (~64 B blit); call on hot-reload
    /// of `data/waves/*.yaml`. Re-derives the seed→initial_iter constant.
    pub fn setWaveParams(self: *Ocean, params: wave.WaveParams) void {
        self.wave_params = params;
        self.wave_state = waves_mod.Ubo.fromParams(params, self.wave_state.a.x);
        self.flushWaveUbo();
    }

    pub fn updateTime(self: *Ocean, t: f32) void {
        self.wave_state.a.x = t;
        self.flushWaveUbo();
    }

    fn flushWaveUbo(self: *Ocean) void {
        self.wave_ubo.upload(std.mem.asBytes(&self.wave_state));
    }

    pub fn setOceanParams(self: *Ocean, params: ocean_params_mod.OceanParams) void {
        const ubo = ocean_uniform_mod.Ubo.fromParams(params);
        self.ocean_ubo.upload(std.mem.asBytes(&ubo));
    }

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

        // Fullscreen triangle — three vertices, no buffers.
        vk.vkCmdDraw(cb, 3, 1, 0, 0);
    }
};

fn createDescriptorPool(device: vk.VkDevice) !vk.VkDescriptorPool {
    const sizes = [_]vk.VkDescriptorPoolSize{.{
        .type = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 3,
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
    ocean: vk.VkBuffer,
) void {
    const camera_info = vk.VkDescriptorBufferInfo{ .buffer = camera, .offset = 0, .range = vk.VK_WHOLE_SIZE };
    const wave_info = vk.VkDescriptorBufferInfo{ .buffer = waves, .offset = 0, .range = vk.VK_WHOLE_SIZE };
    const ocean_info = vk.VkDescriptorBufferInfo{ .buffer = ocean, .offset = 0, .range = vk.VK_WHOLE_SIZE };
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
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = 2,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &ocean_info,
            .pTexelBufferView = null,
        },
    };
    vk.vkUpdateDescriptorSets(device, writes.len, &writes, 0, null);
}
