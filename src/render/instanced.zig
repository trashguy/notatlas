//! M10.1 GPU-driven instancing renderer (CPU multi-draw stage).
//!
//! Replaces Box's per-instance push-constant + drawIndexed loop with:
//!   - A shared `MeshPalette` (vertex/index buffers packed across all
//!     piece types).
//!   - A per-instance SSBO of `{mat4 model, vec4 albedo, vec4 bounds}` rows,
//!     indexed in the vertex shader via `gl_InstanceIndex`.
//!   - One `vkCmdDrawIndexed(..., instanceCount = bucket_size)` per piece
//!     type per frame, with `firstInstance` pointing at the bucket's base
//!     row in the SSBO.
//!
//! Per-frame flow (`record`):
//!   1. Walk active slots, counting how many use each piece_id.
//!   2. Prefix-sum into per-piece offsets in the upload scratch buffer.
//!   3. Scatter the per-slot `Instance` rows into bucket order.
//!   4. memcpy the populated portion of scratch into the SSBO (host-visible
//!      coherent — no explicit flush).
//!   5. Bind pipeline + descriptor set + palette vertex/index buffers.
//!   6. Issue one `vkCmdDrawIndexed` per non-empty bucket.
//!
//! Stages M10.2 (indirect draws) and M10.3 (compute culling) replace
//! step 6 and the CPU-side count/scatter respectively; the SSBO layout
//! stays.

const std = @import("std");
const types = @import("vulkan_types.zig");
const gpu_mod = @import("gpu.zig");
const buffer_mod = @import("buffer.zig");
const shader_mod = @import("shader.zig");
const palette_mod = @import("mesh_palette.zig");

const vk = types.vk;
const VulkanError = types.VulkanError;

const instanced_vert_spv align(4) = @embedFile("instanced_vert_spv").*;
const instanced_frag_spv align(4) = @embedFile("instanced_frag_spv").*;

/// SSBO row layout. Must match `struct Instance` in instanced.vert / the
/// cull shader (M10.3). std430-friendly: mat4 + vec4 + vec4 = 96 B, 16 B
/// aligned, no padding.
pub const Instance = extern struct {
    model: [16]f32,
    albedo: [4]f32,
    bounds: [4]f32, // xyz = world-space center, w = radius
};

comptime {
    std.debug.assert(@sizeOf(Instance) == 96);
    std.debug.assert(@offsetOf(Instance, "model") == 0);
    std.debug.assert(@offsetOf(Instance, "albedo") == 64);
    std.debug.assert(@offsetOf(Instance, "bounds") == 80);
}

/// Wire-compatible with `VkDrawIndexedIndirectCommand`. 20 B fixed layout
/// per the Vulkan spec; we build one entry per non-empty piece bucket each
/// frame, upload to `indirect_buffer`, and let the driver dispatch via
/// `vkCmdDrawIndexedIndirect`.
pub const DrawIndexedIndirectCommand = extern struct {
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
    first_instance: u32,
};

comptime {
    std.debug.assert(@sizeOf(DrawIndexedIndirectCommand) == 20);
}

/// Sentinel piece_id meaning "this slot is dead — skip at draw time."
/// `addInstance` rejects this value as input; `destroy` writes it.
const TOMBSTONE: u32 = std.math.maxInt(u32);

pub const InstanceId = u32;

pub const InstancedError = error{
    NoInstancesAvailable,
    InvalidPieceId,
    InvalidInstanceId,
    TombstonedInstanceId,
} || VulkanError || std.mem.Allocator.Error;

pub const Instanced = struct {
    gpa: std.mem.Allocator,
    device: vk.VkDevice,

    palette: *const palette_mod.MeshPalette,

    descriptor_set_layout: vk.VkDescriptorSetLayout,
    pipeline_layout: vk.VkPipelineLayout,
    pipeline: vk.VkPipeline,

    descriptor_pool: vk.VkDescriptorPool,
    descriptor_set: vk.VkDescriptorSet,

    /// Per-instance SSBO. Host-visible coherent so `record` writes through
    /// the persistent map; M10.3 may move to a device-local + staging copy
    /// once we measure the cost of host-visible-on-GPU bandwidth.
    instance_buffer: buffer_mod.Buffer,
    max_instances: u32,

    /// M10.2 indirect-draw command buffer. Sized for one
    /// `DrawIndexedIndirectCommand` per piece type. Per frame we populate
    /// the first `draw_count` entries and call `vkCmdDrawIndexedIndirect`
    /// once. M10.3 will swap this CPU build for compute-shader output and
    /// use `vkCmdDrawIndexedIndirectCount`.
    indirect_buffer: buffer_mod.Buffer,
    indirect_scratch: []DrawIndexedIndirectCommand,

    /// CPU storage. Slot index is the stable `InstanceId`. `n_slots` is the
    /// high-water mark — slots [0, n_slots) are either active or
    /// tombstoned; slots [n_slots, max_instances) are unused.
    instances: []Instance,
    pieces_per_instance: []u32,
    free_list: std.ArrayList(u32),
    n_slots: u32,

    /// Per-frame scratch. Sized at init to avoid hot-path allocation.
    upload_scratch: []Instance,
    bucket_counts: []u32, // one per piece type
    bucket_offsets: []u32, // prefix-sum of bucket_counts
    bucket_cursors: []u32, // scratch for the scatter step

    pub fn init(
        gpa: std.mem.Allocator,
        gpu: *const gpu_mod.GpuContext,
        render_pass: vk.VkRenderPass,
        camera_ubo: vk.VkBuffer,
        palette: *const palette_mod.MeshPalette,
        max_instances: u32,
    ) InstancedError!Instanced {
        std.debug.assert(max_instances > 0);
        std.debug.assert(palette.pieces.len > 0);

        const set_layout = try createSetLayout(gpu.device);
        errdefer vk.vkDestroyDescriptorSetLayout(gpu.device, set_layout, null);

        const pipeline_layout = try createPipelineLayout(gpu.device, set_layout);
        errdefer vk.vkDestroyPipelineLayout(gpu.device, pipeline_layout, null);

        const vert_module = try shader_mod.fromSpv(gpu.device, &instanced_vert_spv);
        defer vk.vkDestroyShaderModule(gpu.device, vert_module, null);
        const frag_module = try shader_mod.fromSpv(gpu.device, &instanced_frag_spv);
        defer vk.vkDestroyShaderModule(gpu.device, frag_module, null);

        const pipeline = try createPipelineHandle(
            gpu.device,
            render_pass,
            pipeline_layout,
            vert_module,
            frag_module,
        );
        errdefer vk.vkDestroyPipeline(gpu.device, pipeline, null);

        var instance_buffer = try buffer_mod.Buffer.init(
            gpu,
            @as(vk.VkDeviceSize, max_instances) * @sizeOf(Instance),
            vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        );
        errdefer instance_buffer.deinit();

        var indirect_buffer = try buffer_mod.Buffer.init(
            gpu,
            @as(vk.VkDeviceSize, palette.pieces.len) * @sizeOf(DrawIndexedIndirectCommand),
            vk.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT,
        );
        errdefer indirect_buffer.deinit();

        const pool = try createDescriptorPool(gpu.device);
        errdefer vk.vkDestroyDescriptorPool(gpu.device, pool, null);

        const set = try allocateDescriptorSet(gpu.device, pool, set_layout);
        writeDescriptors(gpu.device, set, camera_ubo, instance_buffer.handle);

        const instances = try gpa.alloc(Instance, max_instances);
        errdefer gpa.free(instances);
        const pieces = try gpa.alloc(u32, max_instances);
        errdefer gpa.free(pieces);
        const scratch = try gpa.alloc(Instance, max_instances);
        errdefer gpa.free(scratch);

        const piece_count = palette.pieces.len;
        const counts = try gpa.alloc(u32, piece_count);
        errdefer gpa.free(counts);
        const offsets = try gpa.alloc(u32, piece_count);
        errdefer gpa.free(offsets);
        const cursors = try gpa.alloc(u32, piece_count);
        errdefer gpa.free(cursors);
        const indirect = try gpa.alloc(DrawIndexedIndirectCommand, piece_count);
        errdefer gpa.free(indirect);

        return .{
            .gpa = gpa,
            .device = gpu.device,
            .palette = palette,
            .descriptor_set_layout = set_layout,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
            .descriptor_pool = pool,
            .descriptor_set = set,
            .instance_buffer = instance_buffer,
            .max_instances = max_instances,
            .indirect_buffer = indirect_buffer,
            .indirect_scratch = indirect,
            .instances = instances,
            .pieces_per_instance = pieces,
            .free_list = .empty,
            .n_slots = 0,
            .upload_scratch = scratch,
            .bucket_counts = counts,
            .bucket_offsets = offsets,
            .bucket_cursors = cursors,
        };
    }

    pub fn deinit(self: *Instanced) void {
        self.free_list.deinit(self.gpa);
        self.gpa.free(self.indirect_scratch);
        self.gpa.free(self.bucket_cursors);
        self.gpa.free(self.bucket_offsets);
        self.gpa.free(self.bucket_counts);
        self.gpa.free(self.upload_scratch);
        self.gpa.free(self.pieces_per_instance);
        self.gpa.free(self.instances);

        vk.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
        self.indirect_buffer.deinit();
        self.instance_buffer.deinit();
        vk.vkDestroyPipeline(self.device, self.pipeline, null);
        vk.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        vk.vkDestroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);
    }

    /// Allocate a slot, fill it, return the stable handle. Reuses
    /// tombstoned slots from the free list before growing `n_slots`.
    pub fn addInstance(
        self: *Instanced,
        piece_id: u32,
        model: [16]f32,
        albedo: [4]f32,
    ) InstancedError!InstanceId {
        if (piece_id >= self.palette.pieces.len) return InstancedError.InvalidPieceId;
        const entry = self.palette.pieces[piece_id];

        const slot: u32 = if (self.free_list.pop()) |reused|
            reused
        else blk: {
            if (self.n_slots >= self.max_instances) return InstancedError.NoInstancesAvailable;
            const s = self.n_slots;
            self.n_slots += 1;
            break :blk s;
        };

        self.pieces_per_instance[slot] = piece_id;
        self.instances[slot] = .{
            .model = model,
            .albedo = albedo,
            .bounds = .{
                entry.bounds_center[0],
                entry.bounds_center[1],
                entry.bounds_center[2],
                entry.bounds_radius,
            },
        };
        return slot;
    }

    pub fn updateTransform(self: *Instanced, id: InstanceId, model: [16]f32) void {
        std.debug.assert(id < self.n_slots);
        std.debug.assert(self.pieces_per_instance[id] != TOMBSTONE);
        self.instances[id].model = model;
    }

    pub fn updateAlbedo(self: *Instanced, id: InstanceId, albedo: [4]f32) void {
        std.debug.assert(id < self.n_slots);
        std.debug.assert(self.pieces_per_instance[id] != TOMBSTONE);
        self.instances[id].albedo = albedo;
    }

    /// Mark a slot dead and return it to the free list. Subsequent
    /// `addInstance` calls may reuse the same id, so callers must drop
    /// their handle on destroy.
    pub fn destroy(self: *Instanced, id: InstanceId) InstancedError!void {
        if (id >= self.n_slots) return InstancedError.InvalidInstanceId;
        if (self.pieces_per_instance[id] == TOMBSTONE) return InstancedError.TombstonedInstanceId;
        self.pieces_per_instance[id] = TOMBSTONE;
        try self.free_list.append(self.gpa, id);
    }

    pub fn activeCount(self: *const Instanced) u32 {
        return self.n_slots - @as(u32, @intCast(self.free_list.items.len));
    }

    /// One-frame upload + bind + multi-draw. Caller is mid-render-pass.
    /// Returns the number of `vkCmdDrawIndexed` calls issued (= number of
    /// non-empty piece buckets); useful for the M10.4 gate harness.
    pub fn record(self: *Instanced, cb: vk.VkCommandBuffer, extent: vk.VkExtent2D) u32 {
        const piece_count: u32 = @intCast(self.palette.pieces.len);

        // 1. Bucket counts.
        @memset(self.bucket_counts, 0);
        var s: u32 = 0;
        while (s < self.n_slots) : (s += 1) {
            const pid = self.pieces_per_instance[s];
            if (pid == TOMBSTONE) continue;
            self.bucket_counts[pid] += 1;
        }

        // 2. Prefix-sum into offsets; bucket_cursors starts as a copy.
        var running: u32 = 0;
        var p: u32 = 0;
        while (p < piece_count) : (p += 1) {
            self.bucket_offsets[p] = running;
            self.bucket_cursors[p] = running;
            running += self.bucket_counts[p];
        }
        const total_active = running;

        if (total_active == 0) return 0;

        // 3. Scatter slots into bucket order.
        s = 0;
        while (s < self.n_slots) : (s += 1) {
            const pid = self.pieces_per_instance[s];
            if (pid == TOMBSTONE) continue;
            const dst = self.bucket_cursors[pid];
            self.upload_scratch[dst] = self.instances[s];
            self.bucket_cursors[pid] = dst + 1;
        }

        // 4. Upload populated prefix.
        const upload_bytes = std.mem.sliceAsBytes(self.upload_scratch[0..total_active]);
        @memcpy(self.instance_buffer.mapped[0..upload_bytes.len], upload_bytes);

        // 5. Bind pipeline + state + descriptor set + palette buffers.
        vk.vkCmdBindPipeline(cb, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);

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
            self.pipeline_layout,
            0,
            1,
            &self.descriptor_set,
            0,
            null,
        );

        const offset: vk.VkDeviceSize = 0;
        vk.vkCmdBindVertexBuffers(cb, 0, 1, &self.palette.vertex_buffer.handle, &offset);
        vk.vkCmdBindIndexBuffer(cb, self.palette.index_buffer.handle, 0, vk.VK_INDEX_TYPE_UINT16);

        // 6. M10.2: pack one indirect command per non-empty bucket and let
        // the driver dispatch them in a single vkCmdDrawIndexedIndirect.
        // The actual API draw-call count is now exactly 1 regardless of
        // the number of piece types; the returned `draw_count` is the
        // number of *logical* indirect commands, which is what the M10
        // gate cares about (≤20 piece types renderable at once).
        var draw_count: u32 = 0;
        p = 0;
        while (p < piece_count) : (p += 1) {
            const count = self.bucket_counts[p];
            if (count == 0) continue;
            const entry = self.palette.pieces[p];
            self.indirect_scratch[draw_count] = .{
                .index_count = entry.index_count,
                .instance_count = count,
                .first_index = entry.first_index,
                .vertex_offset = entry.vertex_offset,
                .first_instance = self.bucket_offsets[p],
            };
            draw_count += 1;
        }

        if (draw_count == 0) return 0;

        const cmd_bytes = std.mem.sliceAsBytes(self.indirect_scratch[0..draw_count]);
        @memcpy(self.indirect_buffer.mapped[0..cmd_bytes.len], cmd_bytes);

        vk.vkCmdDrawIndexedIndirect(
            cb,
            self.indirect_buffer.handle,
            0,
            draw_count,
            @sizeOf(DrawIndexedIndirectCommand),
        );
        return draw_count;
    }

    /// Hot-reload entry: rebuild the pipeline against fresh SPIR-V. Mirrors
    /// `Box.reloadShaders`. Descriptor set/pool stay valid because bindings
    /// don't change.
    pub fn reloadShaders(
        self: *Instanced,
        render_pass: vk.VkRenderPass,
        vert_spv: []align(4) const u8,
        frag_spv: []align(4) const u8,
    ) !void {
        const new_vert = try shader_mod.fromSpv(self.device, vert_spv);
        defer vk.vkDestroyShaderModule(self.device, new_vert, null);
        const new_frag = try shader_mod.fromSpv(self.device, frag_spv);
        defer vk.vkDestroyShaderModule(self.device, new_frag, null);

        const new_handle = try createPipelineHandle(
            self.device,
            render_pass,
            self.pipeline_layout,
            new_vert,
            new_frag,
        );
        _ = vk.vkDeviceWaitIdle(self.device);
        vk.vkDestroyPipeline(self.device, self.pipeline, null);
        self.pipeline = new_handle;
    }
};

fn createSetLayout(device: vk.VkDevice) !vk.VkDescriptorSetLayout {
    const bindings = [_]vk.VkDescriptorSetLayoutBinding{
        .{
            .binding = 0,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        .{
            .binding = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
            .pImmutableSamplers = null,
        },
    };
    const ci = vk.VkDescriptorSetLayoutCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .bindingCount = bindings.len,
        .pBindings = &bindings,
    };
    var layout: vk.VkDescriptorSetLayout = undefined;
    try types.check(
        vk.vkCreateDescriptorSetLayout(device, &ci, null, &layout),
        VulkanError.DescriptorSetLayoutCreationFailed,
    );
    return layout;
}

fn createPipelineLayout(
    device: vk.VkDevice,
    set_layout: vk.VkDescriptorSetLayout,
) !vk.VkPipelineLayout {
    const ci = vk.VkPipelineLayoutCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = 1,
        .pSetLayouts = &set_layout,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = null,
    };
    var layout: vk.VkPipelineLayout = undefined;
    try types.check(
        vk.vkCreatePipelineLayout(device, &ci, null, &layout),
        VulkanError.PipelineLayoutCreationFailed,
    );
    return layout;
}

fn createPipelineHandle(
    device: vk.VkDevice,
    render_pass: vk.VkRenderPass,
    pipeline_layout: vk.VkPipelineLayout,
    vert_module: vk.VkShaderModule,
    frag_module: vk.VkShaderModule,
) !vk.VkPipeline {
    const stages = [_]vk.VkPipelineShaderStageCreateInfo{
        .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = vk.VK_SHADER_STAGE_VERTEX_BIT,
            .module = vert_module,
            .pName = "main",
            .pSpecializationInfo = null,
        },
        .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = frag_module,
            .pName = "main",
            .pSpecializationInfo = null,
        },
    };

    // Same vertex layout as Box — palette pieces use box_mod.Vertex.
    const binding = vk.VkVertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(palette_mod.Vertex),
        .inputRate = vk.VK_VERTEX_INPUT_RATE_VERTEX,
    };
    const attrs = [_]vk.VkVertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = vk.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(palette_mod.Vertex, "pos") },
        .{ .location = 1, .binding = 0, .format = vk.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(palette_mod.Vertex, "normal") },
    };
    const vertex_input = vk.VkPipelineVertexInputStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .vertexBindingDescriptionCount = 1,
        .pVertexBindingDescriptions = &binding,
        .vertexAttributeDescriptionCount = attrs.len,
        .pVertexAttributeDescriptions = &attrs,
    };

    const input_assembly = vk.VkPipelineInputAssemblyStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = vk.VK_FALSE,
    };

    const viewport_state = vk.VkPipelineViewportStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .viewportCount = 1,
        .pViewports = null,
        .scissorCount = 1,
        .pScissors = null,
    };

    // Match Box's CULL_NONE — Vulkan's y-flipped projection inverts world
    // winding into NDC; same caveat. M11 piece meshes will pick a winding.
    const rasterizer = vk.VkPipelineRasterizationStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .depthClampEnable = vk.VK_FALSE,
        .rasterizerDiscardEnable = vk.VK_FALSE,
        .polygonMode = vk.VK_POLYGON_MODE_FILL,
        .cullMode = vk.VK_CULL_MODE_NONE,
        .frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .depthBiasEnable = vk.VK_FALSE,
        .depthBiasConstantFactor = 0,
        .depthBiasClamp = 0,
        .depthBiasSlopeFactor = 0,
        .lineWidth = 1,
    };

    const multisampling = vk.VkPipelineMultisampleStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT,
        .sampleShadingEnable = vk.VK_FALSE,
        .minSampleShading = 0,
        .pSampleMask = null,
        .alphaToCoverageEnable = vk.VK_FALSE,
        .alphaToOneEnable = vk.VK_FALSE,
    };

    const color_blend_attachment = vk.VkPipelineColorBlendAttachmentState{
        .blendEnable = vk.VK_FALSE,
        .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE,
        .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
        .colorBlendOp = vk.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
        .alphaBlendOp = vk.VK_BLEND_OP_ADD,
        .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT |
            vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
    };
    const color_blend = vk.VkPipelineColorBlendStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .logicOpEnable = vk.VK_FALSE,
        .logicOp = vk.VK_LOGIC_OP_COPY,
        .attachmentCount = 1,
        .pAttachments = &color_blend_attachment,
        .blendConstants = .{ 0, 0, 0, 0 },
    };

    const depth_stencil = vk.VkPipelineDepthStencilStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .depthTestEnable = vk.VK_TRUE,
        .depthWriteEnable = vk.VK_TRUE,
        .depthCompareOp = vk.VK_COMPARE_OP_LESS,
        .depthBoundsTestEnable = vk.VK_FALSE,
        .stencilTestEnable = vk.VK_FALSE,
        .front = std.mem.zeroes(vk.VkStencilOpState),
        .back = std.mem.zeroes(vk.VkStencilOpState),
        .minDepthBounds = 0,
        .maxDepthBounds = 1,
    };

    const dynamic_states = [_]vk.VkDynamicState{
        vk.VK_DYNAMIC_STATE_VIEWPORT,
        vk.VK_DYNAMIC_STATE_SCISSOR,
    };
    const dynamic_state = vk.VkPipelineDynamicStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };

    const ci = vk.VkGraphicsPipelineCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stageCount = stages.len,
        .pStages = &stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &input_assembly,
        .pTessellationState = null,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterizer,
        .pMultisampleState = &multisampling,
        .pDepthStencilState = &depth_stencil,
        .pColorBlendState = &color_blend,
        .pDynamicState = &dynamic_state,
        .layout = pipeline_layout,
        .renderPass = render_pass,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };

    var handle: vk.VkPipeline = undefined;
    try types.check(
        vk.vkCreateGraphicsPipelines(device, null, 1, &ci, null, &handle),
        VulkanError.PipelineCreationFailed,
    );
    return handle;
}

fn createDescriptorPool(device: vk.VkDevice) !vk.VkDescriptorPool {
    const sizes = [_]vk.VkDescriptorPoolSize{
        .{ .type = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1 },
        .{ .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1 },
    };
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

fn writeDescriptors(
    device: vk.VkDevice,
    set: vk.VkDescriptorSet,
    camera: vk.VkBuffer,
    instances: vk.VkBuffer,
) void {
    const cam_info = vk.VkDescriptorBufferInfo{ .buffer = camera, .offset = 0, .range = vk.VK_WHOLE_SIZE };
    const inst_info = vk.VkDescriptorBufferInfo{ .buffer = instances, .offset = 0, .range = vk.VK_WHOLE_SIZE };
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
            .pBufferInfo = &cam_info,
            .pTexelBufferView = null,
        },
        .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = 1,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &inst_info,
            .pTexelBufferView = null,
        },
    };
    vk.vkUpdateDescriptorSets(device, writes.len, &writes, 0, null);
}
