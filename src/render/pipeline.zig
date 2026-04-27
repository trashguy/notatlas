//! Graphics pipeline + matching pipeline layout + descriptor set layout for
//! the M2.3 ocean pass.
//!
//! Single descriptor set, binding 0 = uniform buffer (vertex stage). Vertex
//! input is `Vertex` from mesh.zig. Viewport and scissor are dynamic so a
//! window resize doesn't require rebuilding the pipeline.

const std = @import("std");
const types = @import("vulkan_types.zig");
const mesh_mod = @import("mesh.zig");

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

pub fn create(
    device: vk.VkDevice,
    render_pass: vk.VkRenderPass,
    vert_module: vk.VkShaderModule,
    frag_module: vk.VkShaderModule,
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

    const binding = mesh_mod.Vertex.binding_description;
    const attrs = mesh_mod.Vertex.attribute_descriptions;
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

    // Viewport + scissor are dynamic; the actual values come from
    // vkCmdSetViewport / vkCmdSetScissor in the record path.
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
        .cullMode = vk.VK_CULL_MODE_NONE, // M2.3: see plane from below too
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
        .pDepthStencilState = null, // no depth attachment in render pass
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

    return .{
        .descriptor_set_layout = set_layout,
        .pipeline_layout = pipeline_layout,
        .handle = handle,
        .device = device,
    };
}

fn createSetLayout(device: vk.VkDevice) !vk.VkDescriptorSetLayout {
    const binding = vk.VkDescriptorSetLayoutBinding{
        .binding = 0,
        .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
        .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
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
