//! Graphics pipeline + matching pipeline layout + descriptor set layout for
//! the M2 raymarched water pass — and, after the 2026-05-14 sky-pass split,
//! the depth-disabled sky pass too. Both pipelines share the same
//! descriptor set layout (camera + waves + ocean UBOs) and the same
//! fullscreen-triangle vertex shader; only the fragment shader and depth
//! state differ. `DepthMode` selects between them.
//!
//! No vertex input — the fullscreen triangle is emitted from
//! `gl_VertexIndex` in `fullscreen.vert`. All UBO bindings are fragment-
//! stage; the vertex shader doesn't read uniforms. Viewport and scissor
//! are dynamic so a window resize doesn't require rebuilding the pipeline.
//!
//! The water fragment shader writes `gl_FragDepth`, which forces late
//! depth-test and disables early-Z. We accept the perf hit at M2 — it's
//! free for future ship/structure passes that need correct occlusion
//! against the water surface (M5+). Sky doesn't write depth and runs with
//! depth test off entirely.

const std = @import("std");
const types = @import("vulkan_types.zig");

const vk = types.vk;
const VulkanError = types.VulkanError;

pub const Pipeline = struct {
    descriptor_set_layout: vk.VkDescriptorSetLayout,
    pipeline_layout: vk.VkPipelineLayout,
    handle: vk.VkPipeline,
    device: vk.VkDevice,

    pub fn deinit(self: *Pipeline) void {
        vk.vkDestroyPipeline(self.device, self.handle, null);
        vk.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        vk.vkDestroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);
    }
};

/// Depth state variant. Sky runs first with no test/write; water runs
/// after geometry with strict LESS (loadbearing — see `issue_waterline
/// _depth_flicker.md`: LESS_OR_EQUAL produced horizon-line flicker
/// against cleared sky depth = 1.0 before the sky pass moved out).
pub const DepthMode = enum { water_strict, sky_disabled };

pub fn create(
    device: vk.VkDevice,
    render_pass: vk.VkRenderPass,
    vert_module: vk.VkShaderModule,
    frag_module: vk.VkShaderModule,
    depth_mode: DepthMode,
) !Pipeline {
    const set_layout = try createSetLayout(device);
    errdefer vk.vkDestroyDescriptorSetLayout(device, set_layout, null);

    const layout_ci = vk.VkPipelineLayoutCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = 1,
        .pSetLayouts = &set_layout,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = null,
    };
    var pipeline_layout: vk.VkPipelineLayout = undefined;
    try types.check(
        vk.vkCreatePipelineLayout(device, &layout_ci, null, &pipeline_layout),
        VulkanError.PipelineLayoutCreationFailed,
    );
    errdefer vk.vkDestroyPipelineLayout(device, pipeline_layout, null);

    const handle = try createHandle(device, render_pass, pipeline_layout, vert_module, frag_module, depth_mode);

    return .{
        .descriptor_set_layout = set_layout,
        .pipeline_layout = pipeline_layout,
        .handle = handle,
        .device = device,
    };
}

/// Build a `VkPipeline` against an existing layout + render pass, used by
/// hot-reload to swap shader code without rebuilding descriptor set
/// layouts (which would invalidate the descriptor pool/set the renderer
/// already wrote into).
pub fn createHandle(
    device: vk.VkDevice,
    render_pass: vk.VkRenderPass,
    pipeline_layout: vk.VkPipelineLayout,
    vert_module: vk.VkShaderModule,
    frag_module: vk.VkShaderModule,
    depth_mode: DepthMode,
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

    // No vertex input — fullscreen tri from gl_VertexIndex.
    const vertex_input = vk.VkPipelineVertexInputStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .vertexBindingDescriptionCount = 0,
        .pVertexBindingDescriptions = null,
        .vertexAttributeDescriptionCount = 0,
        .pVertexAttributeDescriptions = null,
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

    // water_strict: frag writes gl_FragDepth + strict LESS test, so
    //   rasterized geometry drawn between sky and water occludes correctly.
    // sky_disabled: no test, no write — sky paints color into the cleared
    //   depth buffer, leaves depth at 1.0 for later passes to overwrite.
    const depth_test: vk.VkBool32 = switch (depth_mode) {
        .water_strict => vk.VK_TRUE,
        .sky_disabled => vk.VK_FALSE,
    };
    const depth_stencil = vk.VkPipelineDepthStencilStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .depthTestEnable = depth_test,
        .depthWriteEnable = depth_test,
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

fn createSetLayout(device: vk.VkDevice) !vk.VkDescriptorSetLayout {
    // All bindings fragment-only — fullscreen.vert reads no uniforms.
    // binding 0: camera UBO
    // binding 1: wave kernel UBO
    // binding 2: ocean shading UBO
    const bindings = [_]vk.VkDescriptorSetLayoutBinding{
        .{
            .binding = 0,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        .{
            .binding = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        },
        .{
            .binding = 2,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
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
