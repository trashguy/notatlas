//! M4.3 wind-field debug renderer. Draws a sparse grid of flat arrows
//! over the water; CPU samples `windAt` per cell each frame and uploads
//! a per-instance buffer of `(pos_xz, wind_xz)`. The vertex shader
//! generates 9 hard-coded arrow vertices via `gl_VertexIndex`, rotates
//! them to align with the wind direction, and scales by magnitude.
//! Arrows are flat in the XZ plane at a fixed altitude above the storm
//! preset's wave crests.
//!
//! Pipeline differences from `Box`:
//!   - No per-vertex buffer: arrow geometry is hard-coded in the shader.
//!     One vertex-input binding, INSTANCE-rate, two vec2 attributes.
//!   - No push constant; per-instance attribs carry all draw data.
//!   - Same camera UBO (set 0 binding 0) so view/proj/eye stay coherent
//!     with Ocean and Box.
//!
//! Caller owns the windAt-sampling step. `updateInstances` just blits a
//! caller-provided slice into the host-coherent instance buffer; the
//! WindArrows module has zero knowledge of `wind_query` so it stays a
//! pure renderer utility.

const std = @import("std");
const types = @import("vulkan_types.zig");
const gpu_mod = @import("gpu.zig");
const buffer_mod = @import("buffer.zig");
const shader_mod = @import("shader.zig");

const vk = types.vk;
const VulkanError = types.VulkanError;

const arrows_vert_spv align(4) = @embedFile("wind_arrows_vert_spv").*;
const arrows_frag_spv align(4) = @embedFile("wind_arrows_frag_spv").*;

/// Per-arrow instance data. `pos_xz` is the world-space ground position
/// (y is fixed in the shader); `wind_xz` is the world-space wind vector
/// in m/s. Shader handles the rotation, scaling, and color mapping.
pub const ArrowInstance = extern struct {
    pos_xz: [2]f32,
    wind_xz: [2]f32,
};

/// 9 vertices per arrow: 6 for the stem rect, 3 for the head triangle.
/// The vertex shader generates positions from `gl_VertexIndex`; this
/// constant lives here only to size the draw call.
pub const verts_per_arrow: u32 = 9;

pub const WindArrows = struct {
    device: vk.VkDevice,

    descriptor_set_layout: vk.VkDescriptorSetLayout,
    pipeline_layout: vk.VkPipelineLayout,
    pipeline: vk.VkPipeline,

    descriptor_pool: vk.VkDescriptorPool,
    descriptor_set: vk.VkDescriptorSet,

    instance_buffer: buffer_mod.Buffer,
    instance_capacity: u32,
    instance_count: u32,

    pub fn init(
        gpu: *const gpu_mod.GpuContext,
        render_pass: vk.VkRenderPass,
        camera_ubo: vk.VkBuffer,
        max_instances: u32,
    ) !WindArrows {
        const set_layout = try createSetLayout(gpu.device);
        errdefer vk.vkDestroyDescriptorSetLayout(gpu.device, set_layout, null);

        const pipeline_layout = try createPipelineLayout(gpu.device, set_layout);
        errdefer vk.vkDestroyPipelineLayout(gpu.device, pipeline_layout, null);

        const vert_module = try shader_mod.fromSpv(gpu.device, &arrows_vert_spv);
        defer vk.vkDestroyShaderModule(gpu.device, vert_module, null);
        const frag_module = try shader_mod.fromSpv(gpu.device, &arrows_frag_spv);
        defer vk.vkDestroyShaderModule(gpu.device, frag_module, null);

        const pipeline = try createPipelineHandle(gpu.device, render_pass, pipeline_layout, vert_module, frag_module);
        errdefer vk.vkDestroyPipeline(gpu.device, pipeline, null);

        const buf_bytes = @as(vk.VkDeviceSize, max_instances) * @sizeOf(ArrowInstance);
        var inst_buf = try buffer_mod.Buffer.init(
            gpu,
            buf_bytes,
            vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        );
        errdefer inst_buf.deinit();

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
            .instance_buffer = inst_buf,
            .instance_capacity = max_instances,
            .instance_count = 0,
        };
    }

    pub fn deinit(self: *WindArrows) void {
        vk.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
        self.instance_buffer.deinit();
        vk.vkDestroyPipeline(self.device, self.pipeline, null);
        vk.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        vk.vkDestroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);
    }

    /// Replace the instance buffer's contents and update the draw count.
    /// `instances.len` must be ≤ `instance_capacity`.
    pub fn updateInstances(self: *WindArrows, instances: []const ArrowInstance) void {
        std.debug.assert(instances.len <= self.instance_capacity);
        self.instance_buffer.upload(std.mem.sliceAsBytes(instances));
        self.instance_count = @intCast(instances.len);
    }

    pub fn reloadShaders(
        self: *WindArrows,
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

    pub fn record(self: *WindArrows, cb: vk.VkCommandBuffer, extent: vk.VkExtent2D) void {
        if (self.instance_count == 0) return;

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
        vk.vkCmdBindVertexBuffers(cb, 0, 1, &self.instance_buffer.handle, &offset);

        vk.vkCmdDraw(cb, verts_per_arrow, self.instance_count, 0, 0);
    }
};

fn createSetLayout(device: vk.VkDevice) !vk.VkDescriptorSetLayout {
    const bindings = [_]vk.VkDescriptorSetLayoutBinding{.{
        .binding = 0,
        .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
        .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
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
        .stride = @sizeOf(ArrowInstance),
        .inputRate = vk.VK_VERTEX_INPUT_RATE_INSTANCE,
    };
    const attrs = [_]vk.VkVertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = vk.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(ArrowInstance, "pos_xz") },
        .{ .location = 1, .binding = 0, .format = vk.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(ArrowInstance, "wind_xz") },
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

    // Cull NONE — flat arrows lie in the XZ plane and are seen from
    // above, but a low orbit camera occasionally grazes them edge-on;
    // disabling cull keeps both faces visible without doubling geometry.
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
