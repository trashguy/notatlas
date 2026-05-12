//! M11.1 cluster-merge — anchorage structures baked into a single mesh
//! for distance-LOD rendering.
//!
//! API mirrors docs/03-engine-subsystems.md §11. The pure-CPU primitive
//! `mergeCluster` is here; `MergedMesh` owns the GPU VBO/IBO; the
//! pipeline + draw recorder live on `MergedMeshRenderer`. M11.2 adds the
//! `Anchorage` type + LOD selection on top; M11.3 moves the bake to a
//! worker thread and double-buffers the swap.
//!
//! Why a separate pipeline (vs reusing `Instanced`):
//!   - Merged geometry is pre-baked into world space, so vertices carry
//!     final `pos` + `normal` + `albedo` already. No per-instance SSBO,
//!     no `gl_InstanceIndex` indirection — one drawIndexed covers the
//!     whole anchorage.
//!   - Replaces N per-piece instanced draws (one per piece type bucket)
//!     with one draw, at the cost of vertex memory (each piece's
//!     vertices appear once per instance instead of being shared).
//!     The trade is worth it past the LOD distance threshold where
//!     pixel coverage of any individual piece is small.

const std = @import("std");
const notatlas = @import("notatlas");
const types = @import("vulkan_types.zig");
const gpu_mod = @import("gpu.zig");
const buffer_mod = @import("buffer.zig");
const shader_mod = @import("shader.zig");
const palette_mod = @import("mesh_palette.zig");

const vk = types.vk;
const VulkanError = types.VulkanError;
const Mat4 = notatlas.math.Mat4;
const Vec3 = notatlas.math.Vec3;

/// Per-vertex format consumed by `merged.vert`. Pos + normal are baked
/// into world space at merge time so the vertex shader's model
/// transform is identity. Albedo is per-vertex (replicated across each
/// piece's verts) so one draw handles N piece colors with no per-instance
/// state. 36 B; no padding needed (vertex input has no std430 alignment
/// rules — each attribute carries its own offset).
pub const MergedVertex = extern struct {
    pos: [3]f32,
    normal: [3]f32,
    albedo: [3]f32,
};

comptime {
    std.debug.assert(@sizeOf(MergedVertex) == 36);
    std.debug.assert(@offsetOf(MergedVertex, "pos") == 0);
    std.debug.assert(@offsetOf(MergedVertex, "normal") == 12);
    std.debug.assert(@offsetOf(MergedVertex, "albedo") == 24);
}

pub const MergeError = error{
    EmptyCluster,
    VertexCountOverflow,
    IndexCountOverflow,
    SliceLengthMismatch,
} || VulkanError || std.mem.Allocator.Error;

/// Input to `mergeCluster`. The three slices are parallel — entry `i`
/// describes the i'th piece in the cluster. Caller owns memory.
pub const MergeJob = struct {
    pieces: []const palette_mod.PieceMesh,
    transforms: []const Mat4,
    /// xyz = sRGB-ish color; w slot ignored (kept [4]f32 to match
    /// `Instanced.addInstance` so an anchorage can hand the same array
    /// to both code paths).
    albedos: []const [4]f32,
};

/// Stats returned by `mergeCluster` for the harness + logging.
pub const MergeStats = struct {
    vertex_count: u32,
    index_count: u32,
    centroid: Vec3,
    radius: f32,
};

/// Sum vertices + indices across all pieces. Caller uses these to size
/// the output buffers before invoking `mergeCluster`.
pub fn measureCluster(job: MergeJob) MergeError!struct { vertices: u32, indices: u32 } {
    if (job.pieces.len == 0) return MergeError.EmptyCluster;
    if (job.transforms.len != job.pieces.len) return MergeError.SliceLengthMismatch;
    if (job.albedos.len != job.pieces.len) return MergeError.SliceLengthMismatch;

    var v_total: u64 = 0;
    var i_total: u64 = 0;
    for (job.pieces) |p| {
        v_total += p.vertices.len;
        i_total += p.indices.len;
    }
    if (v_total > std.math.maxInt(u32)) return MergeError.VertexCountOverflow;
    if (i_total > std.math.maxInt(u32)) return MergeError.IndexCountOverflow;
    return .{ .vertices = @intCast(v_total), .indices = @intCast(i_total) };
}

/// Pure CPU bake. Writes baked vertices into `out_vertices` and rebased
/// indices into `out_indices`. Returns vertex/index counts written +
/// cluster bounding sphere (centroid of baked positions; radius = max
/// distance from centroid).
///
/// Output slices must be sized via `measureCluster` — this fn asserts
/// the lengths match.
///
/// Index width: cluster total vertex count may exceed 65535 once
/// pieces are mid-poly, so we emit u32 indices (rebased = original
/// piece index + running vertex offset). Input piece indices are u16
/// because that's what `palette_mod.PieceMesh` uses; we widen on the
/// way out.
///
/// Normal transform: pieces are rigid-ish (TRS with uniform-ish
/// scale), so `mat3(model)` is an adequate normal-matrix
/// approximation. We don't pay the inverse-transpose cost; if a piece
/// needs non-uniform scale later, fix in M11.2 alongside that piece's
/// authoring path.
pub fn mergeCluster(
    job: MergeJob,
    out_vertices: []MergedVertex,
    out_indices: []u32,
) MergeError!MergeStats {
    const measured = try measureCluster(job);
    std.debug.assert(out_vertices.len >= measured.vertices);
    std.debug.assert(out_indices.len >= measured.indices);

    var v_cursor: u32 = 0;
    var i_cursor: u32 = 0;

    // Pass 1 — bake vertices + remap indices.
    for (job.pieces, 0..) |piece, p| {
        const m = job.transforms[p];
        const albedo = job.albedos[p];

        const piece_base = v_cursor;
        for (piece.vertices) |v| {
            const wp = transformPos(m, v.pos);
            const wn = transformDir(m, v.normal);
            out_vertices[v_cursor] = .{
                .pos = wp,
                .normal = normalize3(wn),
                .albedo = .{ albedo[0], albedo[1], albedo[2] },
            };
            v_cursor += 1;
        }
        for (piece.indices) |idx| {
            out_indices[i_cursor] = piece_base + @as(u32, idx);
            i_cursor += 1;
        }
    }

    std.debug.assert(v_cursor == measured.vertices);
    std.debug.assert(i_cursor == measured.indices);

    // Pass 2 — bounding sphere (centroid + radius). One pass for
    // centroid, one for radius — adequate for v0; tighter bounds
    // (Ritter's or Welzl) only worth it if we ever cull anchorages
    // GPU-side past M11.
    var cx: f64 = 0;
    var cy: f64 = 0;
    var cz: f64 = 0;
    for (out_vertices[0..measured.vertices]) |v| {
        cx += v.pos[0];
        cy += v.pos[1];
        cz += v.pos[2];
    }
    const inv: f64 = 1.0 / @as(f64, @floatFromInt(measured.vertices));
    const centroid: Vec3 = .{
        .x = @floatCast(cx * inv),
        .y = @floatCast(cy * inv),
        .z = @floatCast(cz * inv),
    };
    var r2_max: f32 = 0;
    for (out_vertices[0..measured.vertices]) |v| {
        const dx = v.pos[0] - centroid.x;
        const dy = v.pos[1] - centroid.y;
        const dz = v.pos[2] - centroid.z;
        const r2 = dx * dx + dy * dy + dz * dz;
        if (r2 > r2_max) r2_max = r2;
    }

    return .{
        .vertex_count = measured.vertices,
        .index_count = measured.indices,
        .centroid = centroid,
        .radius = @sqrt(r2_max),
    };
}

/// GPU resource: vertex + index buffers for one anchorage's merged mesh.
/// Host-visible coherent matches `Buffer`'s only mode (buffer.zig:1).
/// Writes happen at merge time only (rare); reads are once per frame.
pub const MergedMesh = struct {
    vertex_buffer: buffer_mod.Buffer,
    index_buffer: buffer_mod.Buffer,
    vertex_count: u32,
    index_count: u32,
    centroid: Vec3,
    radius: f32,

    pub fn initFromJob(
        gpu: *const gpu_mod.GpuContext,
        gpa: std.mem.Allocator,
        job: MergeJob,
    ) MergeError!MergedMesh {
        const measured = try measureCluster(job);

        const vbo_size: vk.VkDeviceSize = @as(vk.VkDeviceSize, measured.vertices) * @sizeOf(MergedVertex);
        const ibo_size: vk.VkDeviceSize = @as(vk.VkDeviceSize, measured.indices) * @sizeOf(u32);

        var vbo = try buffer_mod.Buffer.init(
            gpu,
            vbo_size,
            vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        );
        errdefer vbo.deinit();

        var ibo = try buffer_mod.Buffer.init(
            gpu,
            ibo_size,
            vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
        );
        errdefer ibo.deinit();

        // Bake into a heap scratch then memcpy into the mapped buffers.
        // We could bake directly into the mapped pointers, but that
        // makes the worker-thread path in M11.3 messier (worker must
        // not touch GPU memory). Keep the CPU bake → GPU upload split
        // explicit from day one.
        const verts_scratch = try gpa.alloc(MergedVertex, measured.vertices);
        defer gpa.free(verts_scratch);
        const idx_scratch = try gpa.alloc(u32, measured.indices);
        defer gpa.free(idx_scratch);

        const stats = try mergeCluster(job, verts_scratch, idx_scratch);

        @memcpy(vbo.mapped[0..vbo_size], std.mem.sliceAsBytes(verts_scratch));
        @memcpy(ibo.mapped[0..ibo_size], std.mem.sliceAsBytes(idx_scratch));

        return .{
            .vertex_buffer = vbo,
            .index_buffer = ibo,
            .vertex_count = stats.vertex_count,
            .index_count = stats.index_count,
            .centroid = stats.centroid,
            .radius = stats.radius,
        };
    }

    pub fn deinit(self: *MergedMesh) void {
        self.index_buffer.deinit();
        self.vertex_buffer.deinit();
    }
};

/// Pipeline + descriptor set for the merged-mesh draw path. One
/// instance covers all anchorages — descriptor set 0 binds the shared
/// camera UBO at binding 0; per-draw state lives in the vertex/index
/// buffers passed to `record`.
pub const MergedMeshRenderer = struct {
    device: vk.VkDevice,

    descriptor_set_layout: vk.VkDescriptorSetLayout,
    pipeline_layout: vk.VkPipelineLayout,
    pipeline: vk.VkPipeline,

    descriptor_pool: vk.VkDescriptorPool,
    descriptor_set: vk.VkDescriptorSet,

    pub fn init(
        gpu: *const gpu_mod.GpuContext,
        render_pass: vk.VkRenderPass,
        camera_ubo: vk.VkBuffer,
    ) !MergedMeshRenderer {
        const set_layout = try createSetLayout(gpu.device);
        errdefer vk.vkDestroyDescriptorSetLayout(gpu.device, set_layout, null);

        const pipeline_layout = try createPipelineLayout(gpu.device, set_layout);
        errdefer vk.vkDestroyPipelineLayout(gpu.device, pipeline_layout, null);

        // @embedFile lives inside init (rather than module-level) so unit
        // tests of the pure-CPU bake can compile without the sandbox's
        // anonymous SPV imports being present.
        const merged_vert_spv align(4) = @embedFile("merged_vert_spv").*;
        const merged_frag_spv align(4) = @embedFile("merged_frag_spv").*;
        const vert_module = try shader_mod.fromSpv(gpu.device, &merged_vert_spv);
        defer vk.vkDestroyShaderModule(gpu.device, vert_module, null);
        const frag_module = try shader_mod.fromSpv(gpu.device, &merged_frag_spv);
        defer vk.vkDestroyShaderModule(gpu.device, frag_module, null);

        const pipeline = try createPipelineHandle(
            gpu.device,
            render_pass,
            pipeline_layout,
            vert_module,
            frag_module,
        );
        errdefer vk.vkDestroyPipeline(gpu.device, pipeline, null);

        const pool = try createDescriptorPool(gpu.device);
        errdefer vk.vkDestroyDescriptorPool(gpu.device, pool, null);

        const set = try allocateDescriptorSet(gpu.device, pool, set_layout);
        writeDescriptors(gpu.device, set, camera_ubo);

        return .{
            .device = gpu.device,
            .descriptor_set_layout = set_layout,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
            .descriptor_pool = pool,
            .descriptor_set = set,
        };
    }

    pub fn deinit(self: *MergedMeshRenderer) void {
        vk.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
        vk.vkDestroyPipeline(self.device, self.pipeline, null);
        vk.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        vk.vkDestroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);
    }

    /// Bind state once + issue one drawIndexed for one anchorage's
    /// merged mesh. Caller invokes inside the render pass alongside
    /// `Instanced.record`. Returns the number of draw calls issued
    /// (always 1) so the gate harness can sum across anchorages.
    pub fn record(
        self: *MergedMeshRenderer,
        cb: vk.VkCommandBuffer,
        extent: vk.VkExtent2D,
        mesh: *const MergedMesh,
    ) u32 {
        if (mesh.index_count == 0) return 0;

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
        vk.vkCmdBindVertexBuffers(cb, 0, 1, &mesh.vertex_buffer.handle, &offset);
        vk.vkCmdBindIndexBuffer(cb, mesh.index_buffer.handle, 0, vk.VK_INDEX_TYPE_UINT32);

        vk.vkCmdDrawIndexed(cb, mesh.index_count, 1, 0, 0, 0);
        return 1;
    }

    /// Hot-reload entry: rebuild the pipeline against fresh SPIR-V.
    /// Mirrors `Instanced.reloadShaders` at instanced.zig:628.
    pub fn reloadShaders(
        self: *MergedMeshRenderer,
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

// --- helpers (Vulkan setup) ---

fn createSetLayout(device: vk.VkDevice) !vk.VkDescriptorSetLayout {
    const binding = vk.VkDescriptorSetLayoutBinding{
        .binding = 0,
        .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
        .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
        .pImmutableSamplers = null,
    };
    const ci = vk.VkDescriptorSetLayoutCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .bindingCount = 1,
        .pBindings = &binding,
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

    const binding = vk.VkVertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(MergedVertex),
        .inputRate = vk.VK_VERTEX_INPUT_RATE_VERTEX,
    };
    const attrs = [_]vk.VkVertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = vk.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(MergedVertex, "pos") },
        .{ .location = 1, .binding = 0, .format = vk.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(MergedVertex, "normal") },
        .{ .location = 2, .binding = 0, .format = vk.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(MergedVertex, "albedo") },
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

    // Match Instanced + Box — Vulkan's y-flipped projection inverts world
    // winding into NDC; cull=NONE keeps both faces visible. Piece meshes
    // pick a winding when real geometry lands.
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
    const size = vk.VkDescriptorPoolSize{
        .type = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
    };
    const ci = vk.VkDescriptorPoolCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .maxSets = 1,
        .poolSizeCount = 1,
        .pPoolSizes = &size,
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
) void {
    const info = vk.VkDescriptorBufferInfo{ .buffer = camera, .offset = 0, .range = vk.VK_WHOLE_SIZE };
    const write = vk.VkWriteDescriptorSet{
        .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .pNext = null,
        .dstSet = set,
        .dstBinding = 0,
        .dstArrayElement = 0,
        .descriptorCount = 1,
        .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .pImageInfo = null,
        .pBufferInfo = &info,
        .pTexelBufferView = null,
    };
    vk.vkUpdateDescriptorSets(device, 1, &write, 0, null);
}

// --- math helpers (column-major Mat4 stored as data[col*4+row]) ---

fn transformPos(m: Mat4, p: [3]f32) [3]f32 {
    // Multiply m * vec4(p, 1) — column-major dot:
    // out_r = m[0][r]*p.x + m[1][r]*p.y + m[2][r]*p.z + m[3][r]
    const d = m.data;
    const x = d[0] * p[0] + d[4] * p[1] + d[8] * p[2] + d[12];
    const y = d[1] * p[0] + d[5] * p[1] + d[9] * p[2] + d[13];
    const z = d[2] * p[0] + d[6] * p[1] + d[10] * p[2] + d[14];
    return .{ x, y, z };
}

fn transformDir(m: Mat4, n: [3]f32) [3]f32 {
    // mat3(m) * n — drops translation. Adequate for rigid-ish piece
    // transforms (rotation + uniform-ish scale); non-uniform scale
    // would require inverse-transpose, deferred until piece authoring
    // demands it.
    const d = m.data;
    const x = d[0] * n[0] + d[4] * n[1] + d[8] * n[2];
    const y = d[1] * n[0] + d[5] * n[1] + d[9] * n[2];
    const z = d[2] * n[0] + d[6] * n[1] + d[10] * n[2];
    return .{ x, y, z };
}

fn normalize3(v: [3]f32) [3]f32 {
    const len2 = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
    if (len2 == 0) return v;
    const inv = 1.0 / @sqrt(len2);
    return .{ v[0] * inv, v[1] * inv, v[2] * inv };
}

// --- tests ---

test "mergeCluster bakes positions and rebases indices" {
    const t = std.testing;
    const palette = @import("mesh_palette.zig");

    // Piece A: 3 verts at unit-x axis, identity transform.
    const a_verts = [_]palette.Vertex{
        .{ .pos = .{ 0, 0, 0 }, .normal = .{ 0, 1, 0 } },
        .{ .pos = .{ 1, 0, 0 }, .normal = .{ 0, 1, 0 } },
        .{ .pos = .{ 0, 0, 1 }, .normal = .{ 0, 1, 0 } },
    };
    const a_idx = [_]u16{ 0, 1, 2 };

    // Piece B: 4 verts, translate by +10 on x.
    const b_verts = [_]palette.Vertex{
        .{ .pos = .{ 0, 0, 0 }, .normal = .{ 1, 0, 0 } },
        .{ .pos = .{ 0, 1, 0 }, .normal = .{ 1, 0, 0 } },
        .{ .pos = .{ 0, 1, 1 }, .normal = .{ 1, 0, 0 } },
        .{ .pos = .{ 0, 0, 1 }, .normal = .{ 1, 0, 0 } },
    };
    const b_idx = [_]u16{ 0, 1, 2, 0, 2, 3 };

    const pieces = [_]palette.PieceMesh{
        .{ .vertices = &a_verts, .indices = &a_idx },
        .{ .vertices = &b_verts, .indices = &b_idx },
    };
    const t_a = Mat4.identity;
    const t_b = Mat4.trs(Vec3.init(10, 0, 0), .{ 0, 0, 0, 1 }, Vec3.init(1, 1, 1));
    const transforms = [_]Mat4{ t_a, t_b };
    const albedos = [_][4]f32{
        .{ 0.8, 0.2, 0.2, 0 },
        .{ 0.2, 0.8, 0.2, 0 },
    };

    var verts: [7]MergedVertex = undefined;
    var idxs: [9]u32 = undefined;

    const stats = try mergeCluster(.{
        .pieces = &pieces,
        .transforms = &transforms,
        .albedos = &albedos,
    }, &verts, &idxs);

    try t.expectEqual(@as(u32, 7), stats.vertex_count);
    try t.expectEqual(@as(u32, 9), stats.index_count);

    // Piece A vertices are at original positions.
    try t.expectEqual(@as(f32, 0), verts[0].pos[0]);
    try t.expectEqual(@as(f32, 1), verts[1].pos[0]);

    // Piece B vertices translated by +10x.
    try t.expectEqual(@as(f32, 10), verts[3].pos[0]);
    try t.expectEqual(@as(f32, 10), verts[6].pos[0]);

    // Piece A albedo on piece A verts; piece B albedo on piece B verts.
    try t.expectEqual(@as(f32, 0.8), verts[0].albedo[0]);
    try t.expectEqual(@as(f32, 0.2), verts[3].albedo[0]);

    // Index rebase: piece B's `0,1,2,0,2,3` becomes `3,4,5,3,5,6`.
    try t.expectEqual(@as(u32, 0), idxs[0]);
    try t.expectEqual(@as(u32, 1), idxs[1]);
    try t.expectEqual(@as(u32, 2), idxs[2]);
    try t.expectEqual(@as(u32, 3), idxs[3]);
    try t.expectEqual(@as(u32, 4), idxs[4]);
    try t.expectEqual(@as(u32, 5), idxs[5]);
    try t.expectEqual(@as(u32, 3), idxs[6]);
    try t.expectEqual(@as(u32, 5), idxs[7]);
    try t.expectEqual(@as(u32, 6), idxs[8]);
}

test "mergeCluster computes centroid + radius bounding sphere" {
    const t = std.testing;
    const palette = @import("mesh_palette.zig");

    // Two-vertex degenerate "pieces" at +10/-10 on x.
    const v_left = [_]palette.Vertex{.{ .pos = .{ -10, 0, 0 }, .normal = .{ 0, 1, 0 } }};
    const v_right = [_]palette.Vertex{.{ .pos = .{ 10, 0, 0 }, .normal = .{ 0, 1, 0 } }};
    const idx = [_]u16{0};

    const pieces = [_]palette.PieceMesh{
        .{ .vertices = &v_left, .indices = &idx },
        .{ .vertices = &v_right, .indices = &idx },
    };
    const transforms = [_]Mat4{ Mat4.identity, Mat4.identity };
    const albedos = [_][4]f32{ .{ 1, 1, 1, 0 }, .{ 1, 1, 1, 0 } };

    var verts: [2]MergedVertex = undefined;
    var idxs: [2]u32 = undefined;

    const stats = try mergeCluster(.{
        .pieces = &pieces,
        .transforms = &transforms,
        .albedos = &albedos,
    }, &verts, &idxs);

    try t.expectApproxEqAbs(@as(f32, 0), stats.centroid.x, 1e-5);
    try t.expectApproxEqAbs(@as(f32, 10), stats.radius, 1e-5);
}

test "measureCluster errors on slice mismatch" {
    const t = std.testing;
    const palette = @import("mesh_palette.zig");
    const v = [_]palette.Vertex{.{ .pos = .{ 0, 0, 0 }, .normal = .{ 0, 1, 0 } }};
    const i = [_]u16{0};
    const pieces = [_]palette.PieceMesh{.{ .vertices = &v, .indices = &i }};
    const transforms = [_]Mat4{Mat4.identity};
    const albedos: [0][4]f32 = .{}; // wrong length

    const result = measureCluster(.{
        .pieces = &pieces,
        .transforms = &transforms,
        .albedos = &albedos,
    });
    try t.expectError(MergeError.SliceLengthMismatch, result);
}
