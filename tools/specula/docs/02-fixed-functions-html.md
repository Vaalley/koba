# Fixed-Function Pipeline State in Vulkan with Zig 0.16.0

## Overview

The previous lessons prepared Koba's rendering resources:

1. SDL3 creates the window.
2. Vulkan creates an instance.
3. SDL3 creates a Vulkan surface.
4. Koba selects a physical device.
5. Koba creates a logical device and graphics queue.
6. Koba creates a swap chain.
7. Koba retrieves the swap-chain images.
8. Koba creates image views.
9. Koba loads SPIR-V and creates a shader module.
10. Koba describes the vertex and fragment shader stages.

This lesson translates the **fixed-function portion** of graphics-pipeline creation from C++ to Zig.

Despite the name, “fixed function” does not mean that the GPU is inflexible. It means that these rendering choices are configured through Vulkan structures rather than written as shader code.

The pipeline will describe:

- dynamic viewport and scissor state,
- vertex input,
- triangle-list assembly,
- rasterization,
- multisampling,
- color blending,
- the pipeline layout,
- the render pass relationship.

The resulting Vulkan object relationship is:

```text
shader module
      +
shader-stage descriptions
      +
fixed-function state
      +
pipeline layout
      +
render pass
      |
      v
graphics pipeline
```

Koba uses the raw C Vulkan bindings generated with `addTranslateC`:

```zig
const std = @import("std");
const sdl = @import("sdl3");
const vk = @import("vulkan");
```

Therefore, this lesson uses calls such as:

```zig
vk.vkCreatePipelineLayout(...)
vk.vkCreateGraphicsPipelines(...)
vk.vkDestroyPipeline(...)
```

It does not use `vk.PipelineProxy`, `vk.DeviceProxy`, `self.device.create*`, or other wrapper-style APIs.

---

## Concepts & Explanations

### Why the graphics pipeline needs fixed-function state

A vertex shader transforms vertices, and a fragment shader produces colors. However, shaders do not define the entire journey from vertex data to a final swap-chain pixel.

The graphics pipeline also needs to know:

```text
vertex shader output
        |
        v
primitive assembly
        |
        v
viewport and scissor
        |
        v
rasterization
        |
        v
fragment shader
        |
        v
color blending
        |
        v
render target
```

These stages determine how Vulkan interprets shader output and how fragments become pixels.

Vulkan requires these choices to be explicit so that the driver can validate and optimize the pipeline before rendering begins.

### Pipeline state is mostly immutable

Once a graphics pipeline has been created, much of its state cannot be changed while drawing.

For example, changing any of these commonly requires another pipeline:

- shader modules,
- primitive topology,
- culling mode,
- polygon mode,
- multisampling configuration,
- blend factors,
- render-pass compatibility.

This is a deliberate Vulkan trade-off:

- **Benefit:** rendering is predictable and has less per-draw configuration overhead.
- **Cost:** engines may need several pipelines for different materials, passes, and render targets.

Some state can be made dynamic. This lesson makes the viewport and scissor dynamic because those values commonly change when the window or swap chain is resized.

### Why the viewport and scissor are dynamic

The viewport maps normalized device coordinates to framebuffer pixels. The scissor rectangle limits rasterization to a region of the framebuffer.

For the initial renderer, both values normally cover the entire swap-chain extent:

```text
viewport: [0, 0, swap-chain width, swap-chain height]
scissor:  [0, 0, swap-chain width, swap-chain height]
```

Making them dynamic means the pipeline does not need to be recreated just because the swap-chain extent changes. The command buffer will set them later with:

```zig
vk.vkCmdSetViewport(...)
vk.vkCmdSetScissor(...)
```

The trade-off is that every command buffer recording must set these values before drawing. If the values are omitted, Vulkan validation will report that required dynamic state was not set.

### Why vertex input is empty for this shader

The Slang vertex shader uses `SV_VertexID` and contains its vertex positions and colors internally. Therefore, the first triangle does not need:

- a vertex buffer,
- vertex binding descriptions,
- vertex attribute descriptions.

The Vulkan vertex-input state is still required, but it can be empty:

```zig
.vertexBindingDescriptionCount = 0,
.pVertexBindingDescriptions = null,
.vertexAttributeDescriptionCount = 0,
.pVertexAttributeDescriptions = null,
```

This is a temporary teaching choice. A real engine will normally use vertex buffers so that meshes and models can provide their own data.

### Why triangle-list assembly is used

The input assembly state tells Vulkan how vertices become primitives.

`VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST` means:

```text
vertices 0, 1, 2 -> triangle 0
vertices 3, 4, 5 -> triangle 1
```

Each group of three vertices is independent. This is simple and predictable for the first triangle.

Other topologies, such as triangle strips or line lists, change how vertices are grouped and are useful for different rendering tasks.

### Rasterization

Rasterization converts primitives into fragments.

This lesson uses:

- polygon fill mode,
- back-face culling,
- clockwise front faces,
- no depth bias,
- no rasterizer discard.

The `frontFace` choice must agree with the coordinate conventions used by the shaders and viewport. If triangles appear to be missing, back-face culling and winding order are common things to inspect.

A useful debugging option is temporarily changing culling to:

```zig
.cullMode = vk.VK_CULL_MODE_NONE,
```

That can reveal whether the problem is winding rather than shader or swap-chain setup.

### Multisampling

Multisampling can improve the appearance of polygon edges by evaluating coverage at multiple sample locations.

This first pipeline uses one sample:

```zig
.rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT,
```

That means multisampling is disabled for now. Enabling four or eight samples later requires checking physical-device limits and usually adding a multisampled render target.

The important distinction is:

- the shader still runs normally,
- the rasterizer decides how fragments cover samples,
- multisampling affects how those samples are resolved into an image.

### Color blending

Color blending combines a fragment shader's output with the existing destination pixel.

For opaque rendering, blending is disabled:

```zig
.blendEnable = vk.VK_FALSE,
```

The fragment color directly replaces the destination color, subject to the color write mask.

For transparent materials, a common blend configuration is:

```text
new RGB = source alpha * new RGB
         + (1 - source alpha) * old RGB

new alpha = new alpha
```

The corresponding Vulkan state uses:

```zig
.srcColorBlendFactor = vk.VK_BLEND_FACTOR_SRC_ALPHA,
.dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
```

This lesson keeps blending enabled in the code so the state is ready for ordinary alpha-based transparency. If the initial triangle should be strictly opaque, set `.blendEnable = vk.VK_FALSE`.

### Why a pipeline layout is required

The pipeline layout describes resources that shaders may access, including:

- descriptor sets,
- push constants.

The current shaders use neither, so the layout can be empty:

```zig
.setLayoutCount = 0,
.pSetLayouts = null,
.pushConstantRangeCount = 0,
.pPushConstantRanges = null,
```

An empty layout is still a real Vulkan object. Future material and camera systems will add descriptor-set layouts or push-constant ranges.

The graphics pipeline refers to this layout, so the layout must be created before the pipeline.

### The render pass is a pipeline dependency

A graphics pipeline must specify which render pass it is compatible with:

```zig
.renderPass = self.render_pass,
.subpass = 0,
```

This lesson assumes the preceding render-pass lesson already added and initialized:

```zig
render_pass: vk.VkRenderPass = null,
```

The render pass must be created before `createGraphicsPipeline()` runs. If the render pass is missing or incompatible with the swap-chain image format, pipeline creation fails.

The dependency now becomes:

```text
swap-chain image views
        |
        v
render pass
        |
        v
pipeline layout
        |
        v
graphics pipeline
```

---

## Code Translation Sections

### Add pipeline fields to `HelloTriangleApplication`

Add these fields to the existing `HelloTriangleApplication` struct.

The render pass is assumed to come from the preceding render-pass lesson:

```zig
render_pass: vk.VkRenderPass = null,

pipeline_layout: vk.VkPipelineLayout = null,
graphics_pipeline: vk.VkPipeline = null,
```

Place them near the other rendering fields:

```zig
swap_chain: vk.VkSwapchainKHR = null,
swap_chain_images: []vk.VkImage = &.{},
swap_chain_surface_format: vk.VkSurfaceFormatKHR = undefined,
swap_chain_extent: vk.VkExtent2D = undefined,
swap_chain_image_views: []vk.VkImageView = &.{},

shader_module: vk.VkShaderModule = null,

render_pass: vk.VkRenderPass = null,
pipeline_layout: vk.VkPipelineLayout = null,
graphics_pipeline: vk.VkPipeline = null,
```

A nullable Vulkan handle follows the project's ownership convention:

- `null` means the object has not been created,
- a non-null handle means Koba owns the object,
- cleanup returns the field to `null`.

### Extend `initVulkan`

The pipeline must be created after the shader module and render pass exist:

```zig
fn initVulkan(self: *HelloTriangleApplication) !void {
    try self.createInstance();
    try self.setupDebugMessenger();
    try self.createSurface();
    try self.pickPhysicalDevice();
    try self.createLogicalDevice();
    try self.createSwapChain();
    try self.createImageViews();
    try self.createShaderModules();
    try self.createRenderPass();
    try self.createGraphicsPipeline();
}
```

If the existing project already calls `createRenderPass()` elsewhere, keep only one call and place `createGraphicsPipeline()` immediately after it.

The ordering matters because `createGraphicsPipeline()` needs:

- `self.device`,
- `self.shader_module`,
- `self.render_pass`,
- the selected swap-chain format.

### Create the dynamic-state description

The C++ source uses:

```cpp
std::vector<vk::DynamicState> dynamicStates = {
    vk::DynamicState::eViewport,
    vk::DynamicState::eScissor
};

vk::PipelineDynamicStateCreateInfo dynamicState{
    .dynamicStateCount = static_cast<uint32_t>(dynamicStates.size()),
    .pDynamicStates = dynamicStates.data()
};
```

The raw C-binding translation uses a fixed array because there are exactly two states:

```zig
const dynamic_states = [_]vk.VkDynamicState{
    vk.VK_DYNAMIC_STATE_VIEWPORT,
    vk.VK_DYNAMIC_STATE_SCISSOR,
};

const dynamic_state = vk.VkPipelineDynamicStateCreateInfo{
    .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    .pNext = null,
    .flags = 0,
    .dynamicStateCount = @intCast(dynamic_states.len),
    .pDynamicStates = &dynamic_states,
};
```

The array must remain alive while `vk.vkCreateGraphicsPipelines()` reads it. Keeping it in the same function as the pipeline creation call satisfies that lifetime requirement.

### Configure vertex input

The shader obtains vertex data through `SV_VertexID`, so no buffer descriptions are needed:

```zig
const vertex_input = vk.VkPipelineVertexInputStateCreateInfo{
    .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    .pNext = null,
    .flags = 0,
    .vertexBindingDescriptionCount = 0,
    .pVertexBindingDescriptions = null,
    .vertexAttributeDescriptionCount = 0,
    .pVertexAttributeDescriptions = null,
};
```

This does not mean Vulkan cannot use vertex buffers. It only means this particular shader does not currently require them.

### Configure input assembly

```zig
const input_assembly = vk.VkPipelineInputAssemblyStateCreateInfo{
    .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    .pNext = null,
    .flags = 0,
    .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
    .primitiveRestartEnable = vk.VK_FALSE,
};
```

`primitiveRestartEnable` is not needed for a triangle list, so it is disabled.

### Configure dynamic viewport and scissor state

Because viewport and scissor are dynamic, the pipeline declares that one of each will be supplied during command-buffer recording:

```zig
const viewport_state = vk.VkPipelineViewportStateCreateInfo{
    .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    .pNext = null,
    .flags = 0,
    .viewportCount = 1,
    .pViewports = null,
    .scissorCount = 1,
    .pScissors = null,
};
```

The pointers are `null` intentionally. The values will be supplied later with `vk.vkCmdSetViewport` and `vk.vkCmdSetScissor`.

A common confusion is that `viewportCount` and `scissorCount` still need to be set even though the pointer fields are null. The counts tell Vulkan how many dynamic values the pipeline expects.

### Static viewport and scissor alternative

If dynamic state is not used, the structures would instead contain actual values:

```zig
const viewport = vk.VkViewport{
    .x = 0.0,
    .y = 0.0,
    .width = @floatFromInt(self.swap_chain_extent.width),
    .height = @floatFromInt(self.swap_chain_extent.height),
    .minDepth = 0.0,
    .maxDepth = 1.0,
};

const scissor = vk.VkRect2D{
    .offset = .{
        .x = 0,
        .y = 0,
    },
    .extent = self.swap_chain_extent,
};

const viewport_state = vk.VkPipelineViewportStateCreateInfo{
    .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    .pNext = null,
    .flags = 0,
    .viewportCount = 1,
    .pViewports = &viewport,
    .scissorCount = 1,
    .pScissors = &scissor,
};
```

Do not use both approaches at the same time. This lesson chooses dynamic state so resizing can update the viewport without recreating the pipeline.

### Configure rasterization

```zig
const rasterizer = vk.VkPipelineRasterizationStateCreateInfo{
    .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    .pNext = null,
    .flags = 0,
    .depthClampEnable = vk.VK_FALSE,
    .rasterizerDiscardEnable = vk.VK_FALSE,
    .polygonMode = vk.VK_POLYGON_MODE_FILL,
    .cullMode = vk.VK_CULL_MODE_BACK_BIT,
    .frontFace = vk.VK_FRONT_FACE_CLOCKWISE,
    .depthBiasEnable = vk.VK_FALSE,
    .depthBiasConstantFactor = 0.0,
    .depthBiasClamp = 0.0,
    .depthBiasSlopeFactor = 0.0,
    .lineWidth = 1.0,
};
```

The extra depth-bias fields must still be initialized even though depth bias is disabled.

If the triangle is unexpectedly invisible, temporarily use:

```zig
.cullMode = vk.VK_CULL_MODE_NONE,
```

This helps determine whether the configured winding order disagrees with the shader's coordinate system.

### Configure multisampling

The first renderer uses one sample:

```zig
const multisampling = vk.VkPipelineMultisampleStateCreateInfo{
    .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    .pNext = null,
    .flags = 0,
    .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT,
    .sampleShadingEnable = vk.VK_FALSE,
    .minSampleShading = 1.0,
    .pSampleMask = null,
    .alphaToCoverageEnable = vk.VK_FALSE,
    .alphaToOneEnable = vk.VK_FALSE,
};
```

This is equivalent to disabling multisampling for now. Later, the physical-device limits must be queried before selecting a higher sample count.

### Configure color blending

The C++ source uses alpha blending:

```cpp
vk::PipelineColorBlendAttachmentState colorBlendAttachment{
    .blendEnable         = vk::True,
    .srcColorBlendFactor = vk::BlendFactor::eSrcAlpha,
    .dstColorBlendFactor = vk::BlendFactor::eOneMinusSrcAlpha,
    .colorBlendOp        = vk::BlendOp::eAdd,
    .srcAlphaBlendFactor = vk::BlendFactor::eOne,
    .dstAlphaBlendFactor = vk::BlendFactor::eZero,
    .alphaBlendOp        = vk::BlendOp::eAdd,
    .colorWriteMask      = vk::ColorComponentFlagBits::eR |
                           vk::ColorComponentFlagBits::eG |
                           vk::ColorComponentFlagBits::eB |
                           vk::ColorComponentFlagBits::eA
};
```

The raw C-binding version is:

```zig
const color_blend_attachment = vk.VkPipelineColorBlendAttachmentState{
    .blendEnable = vk.VK_TRUE,
    .srcColorBlendFactor = vk.VK_BLEND_FACTOR_SRC_ALPHA,
    .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
    .colorBlendOp = vk.VK_BLEND_OP_ADD,
    .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
    .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
    .alphaBlendOp = vk.VK_BLEND_OP_ADD,
    .colorWriteMask =
        vk.VK_COLOR_COMPONENT_R_BIT |
        vk.VK_COLOR_COMPONENT_G_BIT |
        vk.VK_COLOR_COMPONENT_B_BIT |
        vk.VK_COLOR_COMPONENT_A_BIT,
};
```

The color-blend state refers to the attachment description:

```zig
const color_blending = vk.VkPipelineColorBlendStateCreateInfo{
    .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    .pNext = null,
    .flags = 0,
    .logicOpEnable = vk.VK_FALSE,
    .logicOp = vk.VK_LOGIC_OP_COPY,
    .attachmentCount = 1,
    .pAttachments = &color_blend_attachment,
    .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
};
```

If the first triangle should be opaque, use this simpler attachment configuration:

```zig
const color_blend_attachment = vk.VkPipelineColorBlendAttachmentState{
    .blendEnable = vk.VK_FALSE,
    .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE,
    .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
    .colorBlendOp = vk.VK_BLEND_OP_ADD,
    .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
    .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
    .alphaBlendOp = vk.VK_BLEND_OP_ADD,
    .colorWriteMask =
        vk.VK_COLOR_COMPONENT_R_BIT |
        vk.VK_COLOR_COMPONENT_G_BIT |
        vk.VK_COLOR_COMPONENT_B_BIT |
        vk.VK_COLOR_COMPONENT_A_BIT,
};
```

Blending is not automatically transparency. The fragment shader must output a meaningful alpha value, and the render order of transparent objects will matter later.

### Create the pipeline layout

The current shaders do not use descriptors or push constants, so the layout is empty:

```zig
fn createPipelineLayout(self: *HelloTriangleApplication) !void {
    const pipeline_layout_info = vk.VkPipelineLayoutCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = 0,
        .pSetLayouts = null,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = null,
    };

    const result = vk.vkCreatePipelineLayout(
        self.device,
        &pipeline_layout_info,
        null,
        &self.pipeline_layout,
    );

    if (result != vk.VK_SUCCESS) {
        std.log.err("Failed to create Vulkan pipeline layout", .{});
        return error.FailedToCreatePipelineLayout;
    }
}
```

The pipeline layout is created separately so that its lifetime is explicit. The graphics pipeline stores a reference to it, so the layout must remain alive until the pipeline is destroyed.

### Create the graphics pipeline

The following method combines the shader stages from the shader-module lesson with the fixed-function structures from this lesson.

It assumes the existing application already provides:

```zig
fn createShaderStages(
    self: *HelloTriangleApplication,
) ![2]vk.VkPipelineShaderStageCreateInfo
```

and already stores a valid:

```zig
render_pass: vk.VkRenderPass
```

```zig
fn createGraphicsPipeline(self: *HelloTriangleApplication) !void {
    if (self.shader_module == null) {
        return error.ShaderModuleNotCreated;
    }

    if (self.render_pass == null) {
        return error.RenderPassNotCreated;
    }

    try self.createPipelineLayout();

    errdefer {
        if (self.pipeline_layout != null) {
            vk.vkDestroyPipelineLayout(
                self.device,
                self.pipeline_layout,
                null,
            );
            self.pipeline_layout = null;
        }
    }

    const shader_stages = try self.createShaderStages();

    const dynamic_states = [_]vk.VkDynamicState{
        vk.VK_DYNAMIC_STATE_VIEWPORT,
        vk.VK_DYNAMIC_STATE_SCISSOR,
    };

    const dynamic_state = vk.VkPipelineDynamicStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .dynamicStateCount = @intCast(dynamic_states.len),
        .pDynamicStates = &dynamic_states,
    };

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
        .cullMode = vk.VK_CULL_MODE_BACK_BIT,
        .frontFace = vk.VK_FRONT_FACE_CLOCKWISE,
        .depthBiasEnable = vk.VK_FALSE,
        .depthBiasConstantFactor = 0.0,
        .depthBiasClamp = 0.0,
        .depthBiasSlopeFactor = 0.0,
        .lineWidth = 1.0,
    };

    const multisampling = vk.VkPipelineMultisampleStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT,
        .sampleShadingEnable = vk.VK_FALSE,
        .minSampleShading = 1.0,
        .pSampleMask = null,
        .alphaToCoverageEnable = vk.VK_FALSE,
        .alphaToOneEnable = vk.VK_FALSE,
    };

    const color_blend_attachment =
        vk.VkPipelineColorBlendAttachmentState{
            .blendEnable = vk.VK_TRUE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_SRC_ALPHA,
            .dstColorBlendFactor =
                vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = vk.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = vk.VK_BLEND_OP_ADD,
            .colorWriteMask =
                vk.VK_COLOR_COMPONENT_R_BIT |
                vk.VK_COLOR_COMPONENT_G_BIT |
                vk.VK_COLOR_COMPONENT_B_BIT |
                vk.VK_COLOR_COMPONENT_A_BIT,
        };

    const color_blending = vk.VkPipelineColorBlendStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .logicOpEnable = vk.VK_FALSE,
        .logicOp = vk.VK_LOGIC_OP_COPY,
        .attachmentCount = 1,
        .pAttachments = &color_blend_attachment,
        .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
    };

    const pipeline_info = vk.VkGraphicsPipelineCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stageCount = @intCast(shader_stages.len),
        .pStages = &shader_stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &input_assembly,
        .pTessellationState = null,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterizer,
        .pMultisampleState = &multisampling,
        .pDepthStencilState = null,
        .pColorBlendState = &color_blending,
        .pDynamicState = &dynamic_state,
        .layout = self.pipeline_layout,
        .renderPass = self.render_pass,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };

    const result = vk.vkCreateGraphicsPipelines(
        self.device,
        null,
        1,
        &pipeline_info,
        null,
        &self.graphics_pipeline,
    );

    if (result != vk.VK_SUCCESS) {
        std.log.err("Failed to create Vulkan graphics pipeline", .{});
        return error.FailedToCreateGraphicsPipeline;
    }

    std.log.debug("Created Vulkan graphics pipeline", .{});
}
```

All temporary structures remain alive until `vk.vkCreateGraphicsPipelines()` returns. That is sufficient because Vulkan reads the structures during the call and does not retain pointers to the application's local variables.

### Destroy pipeline objects during cleanup

The graphics pipeline depends on the pipeline layout, so destroy the pipeline first:

```zig
fn destroyGraphicsPipeline(self: *HelloTriangleApplication) void {
    if (self.graphics_pipeline != null) {
        vk.vkDestroyPipeline(
            self.device,
            self.graphics_pipeline,
            null,
        );
        self.graphics_pipeline = null;
    }

    if (self.pipeline_layout != null) {
        vk.vkDestroyPipelineLayout(
            self.device,
            self.pipeline_layout,
            null,
        );
        self.pipeline_layout = null;
    }
}
```

Call this before destroying the shader module, image views, swap chain, or logical device:

```zig
fn cleanup(self: *HelloTriangleApplication) void {
    self.destroyGraphicsPipeline();

    if (self.shader_module != null) {
        vk.vkDestroyShaderModule(
            self.device,
            self.shader_module,
            null,
        );
        self.shader_module = null;
    }

    self.destroyImageViews();

    if (self.swap_chain != null) {
        vk.vkDestroySwapchainKHR(
            self.device,
            self.swap_chain,
            null,
        );
        self.swap_chain = null;
    }

    if (self.device != null) {
        vk.vkDestroyDevice(self.device, null);
        self.device = null;
    }

    if (self.surface != null) {
        vk.vkDestroySurfaceKHR(
            self.instance,
            self.surface,
            null,
        );
        self.surface = null;
    }

    if (self.debug_messenger != null) {
        // Keep the existing raw debug-messenger destruction code here.
    }

    if (self.instance != null) {
        vk.vkDestroyInstance(self.instance, null);
        self.instance = null;
    }

    if (self.window) |window| {
        sdl.SDL_DestroyWindow(window);
        self.window = null;
    }

    sdl.SDL_Quit();
}
```

The complete relevant dependency order is:

```text
graphics pipeline
pipeline layout
shader module
image views
swap chain
logical device
surface
debug messenger
instance
SDL window
SDL
```

If the render pass is owned by `HelloTriangleApplication`, destroy it after the graphics pipeline and before the device. A pipeline must never outlive the render pass it references.

### Future command-buffer state

Because viewport and scissor were declared dynamic, future draw-command recording must include calls similar to:

```zig
var viewport = vk.VkViewport{
    .x = 0.0,
    .y = 0.0,
    .width = @floatFromInt(self.swap_chain_extent.width),
    .height = @floatFromInt(self.swap_chain_extent.height),
    .minDepth = 0.0,
    .maxDepth = 1.0,
};

var scissor = vk.VkRect2D{
    .offset = .{
        .x = 0,
        .y = 0,
    },
    .extent = self.swap_chain_extent,
};

vk.vkCmdSetViewport(command_buffer, 0, 1, &viewport);
vk.vkCmdSetScissor(command_buffer, 0, 1, &scissor);
```

These calls belong after command-buffer recording begins, not inside graphics-pipeline creation.

The dynamic state connects this lesson to swap-chain resizing: the pipeline can remain unchanged while the command buffer supplies a new extent.

---

## Recap & What's Next

This lesson translated the fixed-function graphics-pipeline state from C++ to Zig 0.16.0.

The important translations were:

```cpp
vk::PipelineInputAssemblyStateCreateInfo
```

to:

```zig
vk.VkPipelineInputAssemblyStateCreateInfo
```

and:

```cpp
pipelineLayout = vk::raii::PipelineLayout(device, pipelineLayoutInfo);
```

to:

```zig
const result = vk.vkCreatePipelineLayout(
    self.device,
    &pipeline_layout_info,
    null,
    &self.pipeline_layout,
);
```

The graphics pipeline is created with the raw Vulkan function:

```zig
const result = vk.vkCreateGraphicsPipelines(
    self.device,
    null,
    1,
    &pipeline_info,
    null,
    &self.graphics_pipeline,
);
```

Important points:

- Vulkan pipeline state is explicit and mostly immutable.
- The vertex input state is empty because the shader uses `SV_VertexID`.
- Triangle-list assembly produces independent groups of three vertices.
- Viewport and scissor are dynamic, so they must be set during command recording.
- Rasterization controls polygon filling, face culling, and winding.
- Multisampling is currently disabled with one sample.
- Color blending determines how fragment output combines with the existing pixel.
- The pipeline layout is empty now but will later hold descriptors and push constants.
- The render pass must exist before pipeline creation.
- Every Vulkan result is checked explicitly against `vk.VK_SUCCESS`.
- Pipeline objects are destroyed before their dependencies.

Koba now has the pieces needed to create a complete graphics pipeline:

```text
SPIR-V shader module
        +
shader-stage descriptions
        +
fixed-function state
        +
pipeline layout
        +
render pass
        |
        v
graphics pipeline
```

Next, the engine can create framebuffers and command buffers. Framebuffers will connect each swap-chain image view to the render pass, while command buffers will bind the graphics pipeline, set dynamic state, and issue the first draw command.