//! M3.2 debug box pass. Renders a unit cube (±0.5 in object space) with
//! a vertex+fragment pipeline; the model matrix arrives as a vertex-stage
//! push constant so a single Box can render any TRS-transformed instance.
//!
//! Pipeline differences from `Ocean`:
//!   - Vertex input: 1 binding, 2 attributes (pos vec3 + normal vec3).
//!   - Descriptor set: 1 UBO (camera) at vertex+fragment stage. Buffer is
//!     supplied by caller — typically the same `Ocean.camera_ubo` so the
//!     two passes always agree on view/proj/eye without duplicate uploads.
//!   - Push constant: 64 B mat4 in the vertex stage.
//!   - Depth: test+write, COMPARE_OP_LESS (strict — frag does not write
//!     gl_FragDepth, unlike the water pass).
//!   - Cull: NONE for M3.2. Vulkan's y-flipped projection inverts world
//!     winding into NDC; we'll commit to a winding+cull pair when M5
//!     adds proper ship meshes.

const std = @import("std");
const types = @import("vulkan_types.zig");
const gpu_mod = @import("gpu.zig");
const buffer_mod = @import("buffer.zig");
const shader_mod = @import("shader.zig");

const vk = types.vk;
const VulkanError = types.VulkanError;

const box_vert_spv align(4) = @embedFile("box_vert_spv").*;
const box_frag_spv align(4) = @embedFile("box_frag_spv").*;

/// 6 floats per vertex: pos.xyz, normal.xyz. Matches the layout in box.vert.
pub const Vertex = extern struct {
    pos: [3]f32,
    normal: [3]f32,
};

/// 24-vertex unit cube (±0.5). Faces share corner positions but each face
/// gets its own normal, so we duplicate corners 3× across faces.
pub const cube_vertices: [24]Vertex = blk: {
    var verts: [24]Vertex = undefined;
    const faces = .{
        .{ .normal = .{ 1, 0, 0 }, .corners = .{ .{ 0.5, -0.5, 0.5 }, .{ 0.5, 0.5, 0.5 }, .{ 0.5, 0.5, -0.5 }, .{ 0.5, -0.5, -0.5 } } },
        .{ .normal = .{ -1, 0, 0 }, .corners = .{ .{ -0.5, -0.5, -0.5 }, .{ -0.5, 0.5, -0.5 }, .{ -0.5, 0.5, 0.5 }, .{ -0.5, -0.5, 0.5 } } },
        .{ .normal = .{ 0, 1, 0 }, .corners = .{ .{ -0.5, 0.5, 0.5 }, .{ -0.5, 0.5, -0.5 }, .{ 0.5, 0.5, -0.5 }, .{ 0.5, 0.5, 0.5 } } },
        .{ .normal = .{ 0, -1, 0 }, .corners = .{ .{ -0.5, -0.5, -0.5 }, .{ -0.5, -0.5, 0.5 }, .{ 0.5, -0.5, 0.5 }, .{ 0.5, -0.5, -0.5 } } },
        .{ .normal = .{ 0, 0, 1 }, .corners = .{ .{ -0.5, -0.5, 0.5 }, .{ 0.5, -0.5, 0.5 }, .{ 0.5, 0.5, 0.5 }, .{ -0.5, 0.5, 0.5 } } },
        .{ .normal = .{ 0, 0, -1 }, .corners = .{ .{ 0.5, -0.5, -0.5 }, .{ -0.5, -0.5, -0.5 }, .{ -0.5, 0.5, -0.5 }, .{ 0.5, 0.5, -0.5 } } },
    };
    var i: usize = 0;
    for (faces) |f| {
        for (f.corners) |c| {
            verts[i] = .{ .pos = c, .normal = f.normal };
            i += 1;
        }
    }
    break :blk verts;
};

/// 36 indices: 6 faces × 2 triangles × 3 verts. Each face's 4 verts are
/// laid out at (face_idx*4 + 0..3); we pull out tris (0,1,2), (0,2,3) per
/// face in the layout order above. Cull is OFF so winding is cosmetic.
pub const cube_indices: [36]u16 = blk: {
    var idx: [36]u16 = undefined;
    var f: u16 = 0;
    while (f < 6) : (f += 1) {
        const base: u16 = f * 4;
        idx[f * 6 + 0] = base + 0;
        idx[f * 6 + 1] = base + 1;
        idx[f * 6 + 2] = base + 2;
        idx[f * 6 + 3] = base + 0;
        idx[f * 6 + 4] = base + 2;
        idx[f * 6 + 5] = base + 3;
    }
    break :blk idx;
};

pub const Box = struct {
    device: vk.VkDevice,

    descriptor_set_layout: vk.VkDescriptorSetLayout,
    pipeline_layout: vk.VkPipelineLayout,
    pipeline: vk.VkPipeline,

    descriptor_pool: vk.VkDescriptorPool,
    descriptor_set: vk.VkDescriptorSet,

    vertex_buffer: buffer_mod.Buffer,
    index_buffer: buffer_mod.Buffer,

    /// Most recent model matrix. `record` reads this and pushes it; `setModel`
    /// just stores. Avoids needing a per-frame UBO for a single transform.
    model: [16]f32,

    pub fn init(
        gpu: *const gpu_mod.GpuContext,
        render_pass: vk.VkRenderPass,
        camera_ubo: vk.VkBuffer,
    ) !Box {
        const set_layout = try createSetLayout(gpu.device);
        errdefer vk.vkDestroyDescriptorSetLayout(gpu.device, set_layout, null);

        const pipeline_layout = try createPipelineLayout(gpu.device, set_layout);
        errdefer vk.vkDestroyPipelineLayout(gpu.device, pipeline_layout, null);

        const vert_module = try shader_mod.fromSpv(gpu.device, &box_vert_spv);
        defer vk.vkDestroyShaderModule(gpu.device, vert_module, null);
        const frag_module = try shader_mod.fromSpv(gpu.device, &box_frag_spv);
        defer vk.vkDestroyShaderModule(gpu.device, frag_module, null);

        const pipeline = try createPipelineHandle(gpu.device, render_pass, pipeline_layout, vert_module, frag_module);
        errdefer vk.vkDestroyPipeline(gpu.device, pipeline, null);

        var vbo = try buffer_mod.Buffer.init(
            gpu,
            @sizeOf(@TypeOf(cube_vertices)),
            vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        );
        errdefer vbo.deinit();
        vbo.upload(std.mem.asBytes(&cube_vertices));

        var ibo = try buffer_mod.Buffer.init(
            gpu,
            @sizeOf(@TypeOf(cube_indices)),
            vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
        );
        errdefer ibo.deinit();
        ibo.upload(std.mem.asBytes(&cube_indices));

        const pool = try createDescriptorPool(gpu.device);
        errdefer vk.vkDestroyDescriptorPool(gpu.device, pool, null);

        const set = try allocateDescriptorSet(gpu.device, pool, set_layout);
        writeCameraDescriptor(gpu.device, set, camera_ubo);

        return .{
            .device = gpu.device,
            .descriptor_set_layout = set_layout,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
            .descriptor_pool = pool,
            .descriptor_set = set,
            .vertex_buffer = vbo,
            .index_buffer = ibo,
            .model = identity_mat,
        };
    }

    pub fn deinit(self: *Box) void {
        vk.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
        self.index_buffer.deinit();
        self.vertex_buffer.deinit();
        vk.vkDestroyPipeline(self.device, self.pipeline, null);
        vk.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        vk.vkDestroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);
    }

    /// Replace the model matrix sent to the next draw. `data` is column-
    /// major, matching `notatlas.math.Mat4`.
    pub fn setModel(self: *Box, data: [16]f32) void {
        self.model = data;
    }

    /// Hot-reload entry: rebuild the pipeline against fresh SPIR-V. Mirrors
    /// `Ocean.reloadShaders`. Descriptor set/pool are reused — bindings
    /// don't change at runtime.
    pub fn reloadShaders(
        self: *Box,
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

    pub fn record(self: *Box, cb: vk.VkCommandBuffer, extent: vk.VkExtent2D) void {
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
        vk.vkCmdBindVertexBuffers(cb, 0, 1, &self.vertex_buffer.handle, &offset);
        vk.vkCmdBindIndexBuffer(cb, self.index_buffer.handle, 0, vk.VK_INDEX_TYPE_UINT16);

        vk.vkCmdPushConstants(
            cb,
            self.pipeline_layout,
            vk.VK_SHADER_STAGE_VERTEX_BIT,
            0,
            @sizeOf([16]f32),
            &self.model,
        );

        vk.vkCmdDrawIndexed(cb, cube_indices.len, 1, 0, 0, 0);
    }
};

const identity_mat: [16]f32 = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};

fn createSetLayout(device: vk.VkDevice) !vk.VkDescriptorSetLayout {
    const bindings = [_]vk.VkDescriptorSetLayoutBinding{.{
        .binding = 0,
        .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
        .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
        .pImmutableSamplers = null,
    }};
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
    const push_range = vk.VkPushConstantRange{
        .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
        .offset = 0,
        .size = @sizeOf([16]f32),
    };
    const ci = vk.VkPipelineLayoutCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = 1,
        .pSetLayouts = &set_layout,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_range,
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
        .stride = @sizeOf(Vertex),
        .inputRate = vk.VK_VERTEX_INPUT_RATE_VERTEX,
    };
    const attrs = [_]vk.VkVertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = vk.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(Vertex, "pos") },
        .{ .location = 1, .binding = 0, .format = vk.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(Vertex, "normal") },
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

    // Strict LESS — frag does not write gl_FragDepth, so the implicit
    // perspective-divided z is the source of truth. Water clears the depth
    // buffer to 1.0 and writes gl_FragDepth at every fragment, so the box
    // sees the wave surface or far-plane sky depth and z-tests correctly.
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

fn writeCameraDescriptor(device: vk.VkDevice, set: vk.VkDescriptorSet, camera: vk.VkBuffer) void {
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
