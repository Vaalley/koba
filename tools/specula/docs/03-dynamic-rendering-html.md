# Dynamic Rendering Pipeline Create Info in Vulkan with Zig 0.16.0

## Overview

The previous lessons prepared the resources needed to begin drawing:

1. Koba creates an SDL3 window.
2. Vulkan creates an instance.
3. SDL3 creates a Vulkan surface.
4. Koba selects a physical device.
5. Koba creates a logical device and graphics queue.
6. Koba creates a swap chain.
7. Koba retrieves swap-chain images.
8. Koba creates image views.
9. Koba loads shader code and creates a shader module.
10. Koba creates a pipeline layout.

This lesson connects those pieces by creating a graphics pipeline that uses
**Vulkan dynamic rendering**.

The C++ source provides two structures:

```cpp
vk::PipelineRenderingCreateInfo pipelineRenderingCreateInfo{
    .colorAttachmentCount = 1,
    .pColorAttachmentFormats = &swapChainSurfaceFormat.format
};
```

and:

```cpp
vk::StructureChain<
    vk::GraphicsPipelineCreateInfo,
    vk::PipelineRenderingCreateInfo
> pipelineCreateInfoChain = {
    {
        .stageCount          = 2,
        .pStages             = shaderStages,
        .pVertexInputState   = &vertexInputInfo,
        .pInputAssemblyState = &inputAssembly,
        .pViewportState      = &viewportState,
        .pRasterizationState = &rasterizer,
        .pMultisampleState   = &multisampling,
        .pColorBlendState    = &colorBlending,
        .pDynamicState       = &dynamicState,
        .layout              = pipelineLayout,
        .renderPass          = nullptr
    },
    {
        .colorAttachmentCount = 1,
        .pColorAttachmentFormats = &swapChainSurfaceFormat.format
    }
};
```

C++ Vulkan-Hpp's `StructureChain` automatically links the structures through
Vulkan's `pNext` mechanism. Raw Vulkan bindings do not provide that helper. In
Zig, Koba creates the two structures directly and assigns the rendering
structure to the graphics pipeline's `.pNext` field.

The resulting relationship is:

```text
VkPipelineRenderingCreateInfo
            |
            | assigned through VkGraphicsPipelineCreateInfo.pNext
            v
VkGraphicsPipelineCreateInfo
            |
            v
vk.vkCreateGraphicsPipelines(...)
```

Dynamic rendering means the graphics pipeline describes its color attachment
formats without referring to a traditional `VkRenderPass`.

---

## Concepts & Explanations

### Why dynamic rendering matters

Older Vulkan renderers usually create a `VkRenderPass` first. The graphics
pipeline then refers to that render pass through:

```zig
.renderPass = render_pass
```

Dynamic rendering removes that requirement. Instead, the pipeline describes the
formats of its attachments through:

```zig
VkPipelineRenderingCreateInfo
```

For Koba's first renderer, the pipeline has one color attachment whose format is
the swap-chain format:

```zig
.colorAttachmentCount = 1
.pColorAttachmentFormats = &self.swap_chain_surface_format.format
```

This is useful for a game engine because rendering code becomes less tightly
coupled to pre-created render-pass objects. Different rendering paths can begin
and end rendering with attachment information supplied at command-recording
time.

The trade-off is that dynamic rendering is still explicit. The format used while
beginning rendering must agree with the format declared during pipeline
creation. If those formats disagree, pipeline use is invalid.

### Dynamic rendering does not remove pipeline state

Dynamic rendering replaces the render-pass relationship; it does not replace the
other graphics-pipeline descriptions.

The pipeline still needs to describe:

- shader stages,
- vertex input,
- primitive assembly,
- viewport and scissor,
- rasterization,
- multisampling,
- color blending,
- pipeline layout.

The pipeline is still a large, mostly immutable description of how drawing
works.

### `pNext` is a linked structure chain

Many Vulkan structures have a `.pNext` field. Vulkan uses this field to attach
optional or extended structures.

In C++ Vulkan-Hpp, this:

```cpp
vk::StructureChain<vk::GraphicsPipelineCreateInfo,
                   vk::PipelineRenderingCreateInfo>
```

conceptually creates:

```text
VkGraphicsPipelineCreateInfo
    .pNext ---> VkPipelineRenderingCreateInfo
```

The raw C-binding equivalent is:

```zig
var rendering_info = vk.VkPipelineRenderingCreateInfo{
    .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
    .pNext = null,
    .viewMask = 0,
    .colorAttachmentCount = 1,
    .pColorAttachmentFormats = &self.swap_chain_surface_format.format,
    .depthAttachmentFormat = vk.VK_FORMAT_UNDEFINED,
    .stencilAttachmentFormat = vk.VK_FORMAT_UNDEFINED,
};

var pipeline_create_info = vk.VkGraphicsPipelineCreateInfo{
    .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
    .pNext = &rendering_info,
    // ...
};
```

The order matters: `rendering_info` must remain alive while Vulkan reads
`pipeline_create_info`.

### Why `renderPass` is `null`

Dynamic rendering and traditional render passes are alternative pipeline models.

For a dynamic-rendering pipeline:

```zig
.renderPass = null,
```

The rendering information comes from the structure attached through `.pNext`.

Do not provide both a traditional render pass and dynamic-rendering information
for the same pipeline description. The pipeline must use the model selected by
the rest of the renderer.

### Vulkan 1.4 and the dynamic-rendering feature

Koba targets Vulkan 1.4, where dynamic rendering is part of the core API.
However, the feature still needs to be enabled for the logical device.

When creating the logical device, the dynamic-rendering feature structure must
be included in the device feature chain:

```zig
var dynamic_rendering_features =
    vk.VkPhysicalDeviceDynamicRenderingFeatures{
        .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES,
        .pNext = null,
        .dynamicRendering = vk.VK_TRUE,
    };
```

Then attach it to `VkDeviceCreateInfo.pNext`:

```zig
device_create_info.pNext = &dynamic_rendering_features;
```

If the existing logical-device creation code already has a `.pNext` chain, add
this structure to that chain rather than overwriting the existing head. A Vulkan
`pNext` chain is a linked list, so each structure can point to the next
structure.

The exact generated binding may expose the feature member as
`.dynamicRendering`, matching the Vulkan C field name.

### The swap-chain format must match

The dynamic-rendering description uses:

```zig
self.swap_chain_surface_format.format
```

This connects the pipeline to the format selected during swap-chain creation.

The important invariant is:

```text
swap-chain image format
        ==
pipeline color attachment format
        ==
dynamic-rendering color attachment format
```

If the swap chain is recreated with a different format, the pipeline may also
need to be recreated.

This is one reason game engines commonly group swap-chain-dependent objects
together. Image views, framebuffers or dynamic-rendering state, and pipelines
may all need to be rebuilt when the window changes.

### Shader stages use the existing shader-module lesson

The previous shader-module lesson already introduced the two shader stages:

```zig
vertMain
fragMain
```

The method below uses the existing `createShaderStages()` helper. That helper
returns:

```zig
[2]vk.VkPipelineShaderStageCreateInfo
```

The same `VkShaderModule` can contain both entry points. The stage structures
select which function executes for each stage.

### The vertex shader needs no vertex buffer yet

The Slang vertex shader uses `SV_VertexID`. Therefore the first triangle does
not need a vertex buffer.

The vertex-input state can be empty:

```zig
.vertexBindingDescriptionCount = 0,
.pVertexBindingDescriptions = null,
.vertexAttributeDescriptionCount = 0,
.pVertexAttributeDescriptions = null,
```

This is a deliberate temporary design. Later, when Koba adds meshes, the
vertex-input state will describe vertex-buffer strides and attribute locations.

### Static versus dynamic viewport state

The example below uses a viewport and scissor built from the current swap-chain
extent. This keeps the first pipeline straightforward:

```zig
.viewportCount = 1,
.pViewports = &viewport,
.scissorCount = 1,
.pScissors = &scissor,
```

A common alternative is to make viewport and scissor dynamic. In that design,
the pipeline stores their count but not their values, and command recording
calls `vkCmdSetViewport` and `vkCmdSetScissor`.

Static state is easier to understand initially. Dynamic state is more flexible
for window resizing and is often useful in a production engine.

### Cleanup must destroy the pipeline before the device

The pipeline is owned by the logical device. It must be destroyed before the
device:

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

The pipeline layout and shader module are also device-owned objects. The exact
order between those objects depends on which objects the pipeline uses, but all
must be destroyed before `vk.vkDestroyDevice`.

---

## Code Translation Sections

### Add graphics-pipeline state

Add the graphics-pipeline handle to the existing `HelloTriangleApplication`
struct:

```zig
graphics_pipeline: vk.VkPipeline = null,
```

It belongs near the other rendering handles:

```zig
swap_chain: vk.VkSwapchainKHR = null,
swap_chain_images: []vk.VkImage = &.{},
swap_chain_surface_format: vk.VkSurfaceFormatKHR = undefined,
swap_chain_extent: vk.VkExtent2D = undefined,
swap_chain_image_views: []vk.VkImageView = &.{},

shader_module: vk.VkShaderModule = null,
pipeline_layout: vk.VkPipelineLayout = null,
graphics_pipeline: vk.VkPipeline = null,
```

A `null` handle means that the pipeline has not been created or has already been
destroyed.

### Enable dynamic rendering while creating the logical device

Add the feature structure to the existing logical-device creation code:

```zig
var dynamic_rendering_features =
    vk.VkPhysicalDeviceDynamicRenderingFeatures{
        .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES,
        .pNext = null,
        .dynamicRendering = vk.VK_TRUE,
    };
```

Then use it in `VkDeviceCreateInfo`:

```zig
var device_create_info = vk.VkDeviceCreateInfo{
    .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
    .pNext = &dynamic_rendering_features,
    .flags = 0,
    .queueCreateInfoCount = 1,
    .pQueueCreateInfos = &queue_create_info,
    .enabledLayerCount = 0,
    .ppEnabledLayerNames = null,
    .enabledExtensionCount = @intCast(required_device_extensions.len),
    .ppEnabledExtensionNames = &required_device_extensions,
    .pEnabledFeatures = null,
};
```

Keep the rest of the existing device-creation code unchanged.

If the existing application already uses a feature chain, link the
dynamic-rendering structure into that chain instead of replacing the current
`.pNext` pointer.

Then check the result as usual:

```zig
const result = vk.vkCreateDevice(
    self.physical_device,
    &device_create_info,
    null,
    &self.device,
);

if (result != vk.VK_SUCCESS) {
    std.log.err("Failed to create logical device", .{});
    return error.FailedToCreateLogicalDevice;
}
```

### Replace the graphics-pipeline placeholder

The earlier lesson added this placeholder:

```zig
fn createGraphicsPipeline(self: *HelloTriangleApplication) !void {
    _ = self;

    std.log.debug(
        "Graphics-pipeline creation is reserved for the next lesson",
        .{},
    );
}
```

Replace it with the following raw Vulkan implementation:

```zig
fn createGraphicsPipeline(self: *HelloTriangleApplication) !void {
    if (self.device == null) {
        return error.DeviceNotCreated;
    }

    if (self.pipeline_layout == null) {
        return error.PipelineLayoutNotCreated;
    }

    if (self.shader_module == null) {
        return error.ShaderModuleNotCreated;
    }

    if (self.graphics_pipeline != null) {
        return error.GraphicsPipelineAlreadyCreated;
    }

    const shader_stages = try self.createShaderStages();

    var vertex_input = vk.VkPipelineVertexInputStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .vertexBindingDescriptionCount = 0,
        .pVertexBindingDescriptions = null,
        .vertexAttributeDescriptionCount = 0,
        .pVertexAttributeDescriptions = null,
    };

    var input_assembly = vk.VkPipelineInputAssemblyStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = vk.VK_FALSE,
    };

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

    var viewport_state = vk.VkPipelineViewportStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .viewportCount = 1,
        .pViewports = &viewport,
        .scissorCount = 1,
        .pScissors = &scissor,
    };

    var rasterizer = vk.VkPipelineRasterizationStateCreateInfo{
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

    var multisampling = vk.VkPipelineMultisampleStateCreateInfo{
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

    var color_blend_attachment = vk.VkPipelineColorBlendAttachmentState{
        .blendEnable = vk.VK_FALSE,
        .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE,
        .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
        .colorBlendOp = vk.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
        .alphaBlendOp = vk.VK_BLEND_OP_ADD,
        .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT |
            vk.VK_COLOR_COMPONENT_G_BIT |
            vk.VK_COLOR_COMPONENT_B_BIT |
            vk.VK_COLOR_COMPONENT_A_BIT,
    };

    var color_blending = vk.VkPipelineColorBlendStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .logicOpEnable = vk.VK_FALSE,
        .logicOp = vk.VK_LOGIC_OP_COPY,
        .attachmentCount = 1,
        .pAttachments = &color_blend_attachment,
        .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
    };

    var rendering_info = vk.VkPipelineRenderingCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
        .pNext = null,
        .viewMask = 0,
        .colorAttachmentCount = 1,
        .pColorAttachmentFormats =
            &self.swap_chain_surface_format.format,
        .depthAttachmentFormat = vk.VK_FORMAT_UNDEFINED,
        .stencilAttachmentFormat = vk.VK_FORMAT_UNDEFINED,
    };

    var pipeline_create_info = vk.VkGraphicsPipelineCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = &rendering_info,
        .flags = 0,
        .stageCount = @intCast(shader_stages.len),
        .pStages = &shader_stages[0],
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &input_assembly,
        .pTessellationState = null,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterizer,
        .pMultisampleState = &multisampling,
        .pDepthStencilState = null,
        .pColorBlendState = &color_blending,
        .pDynamicState = null,
        .layout = self.pipeline_layout,
        .renderPass = null,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };

    const result = vk.vkCreateGraphicsPipelines(
        self.device,
        null,
        1,
        &pipeline_create_info,
        null,
        &self.graphics_pipeline,
    );

    if (result != vk.VK_SUCCESS) {
        self.graphics_pipeline = null;
        std.log.err("Failed to create graphics pipeline", .{});
        return error.FailedToCreateGraphicsPipeline;
    }

    std.log.info("Created dynamic-rendering graphics pipeline", .{});
}
```

This method uses the fields and helper introduced by the previous lessons:

- `self.device`
- `self.pipeline_layout`
- `self.shader_module`
- `self.swap_chain_extent`
- `self.swap_chain_surface_format`
- `self.createShaderStages()`

The method therefore extends the existing `HelloTriangleApplication` rather than
creating a separate renderer type.

### Understand the two important structures

The most important part of the method is the connection between these
structures:

```zig
var rendering_info = vk.VkPipelineRenderingCreateInfo{
    .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
    .pNext = null,
    .viewMask = 0,
    .colorAttachmentCount = 1,
    .pColorAttachmentFormats =
        &self.swap_chain_surface_format.format,
    .depthAttachmentFormat = vk.VK_FORMAT_UNDEFINED,
    .stencilAttachmentFormat = vk.VK_FORMAT_UNDEFINED,
};
```

and:

```zig
var pipeline_create_info = vk.VkGraphicsPipelineCreateInfo{
    .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
    .pNext = &rendering_info,
    // ...
};
```

The C++ `StructureChain` is translated manually by assigning:

```zig
.pNext = &rendering_info
```

The rendering structure must be initialized before the pipeline structure
because the pipeline structure stores a pointer to it.

### Connect the method to initialization

The pipeline must be created after all of its dependencies exist.

The relevant initialization order is:

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
    try self.createPipelineLayout();
    try self.createGraphicsPipeline();
}
```

If the existing project uses a different location for shader-module or
pipeline-layout creation, preserve that project's order. The dependency
requirements are:

```text
logical device
    |
    +--> shader module
    |
    +--> pipeline layout
    |
    +--> graphics pipeline
```

The swap-chain format and extent must also already be available before pipeline
creation.

### Destroy the graphics pipeline

Add a cleanup helper to the existing `HelloTriangleApplication`:

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
}
```

Call it before destroying the pipeline layout, shader module, or logical device:

```zig
fn cleanup(self: *HelloTriangleApplication) void {
    self.destroyGraphicsPipeline();

    if (self.pipeline_layout != null) {
        vk.vkDestroyPipelineLayout(
            self.device,
            self.pipeline_layout,
            null,
        );

        self.pipeline_layout = null;
    }

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
        // Keep the existing debug-messenger destruction code here.
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

Keep any existing cleanup logic that is not shown here. The essential rule is
that the graphics pipeline must be destroyed before the logical device.

### Complete lesson-specific target code

The following is the complete target-language portion introduced by this lesson.
It is intended to be merged into the existing `src/main.zig` and uses the
project's established imports and struct:

```zig
const std = @import("std");
const sdl = @import("sdl3");
const vk = @import("vulkan");

const HelloTriangleApplication = struct {
    allocator: std.mem.Allocator,

    window: ?*sdl.SDL_Window = null,

    instance: vk.VkInstance = null,
    debug_messenger: vk.VkDebugUtilsMessengerEXT = null,
    surface: vk.VkSurfaceKHR = null,

    physical_device: vk.VkPhysicalDevice = null,
    device: vk.VkDevice = null,
    graphics_queue: vk.VkQueue = null,
    graphics_family: u32 = 0,

    swap_chain: vk.VkSwapchainKHR = null,
    swap_chain_images: []vk.VkImage = &.{},
    swap_chain_surface_format: vk.VkSurfaceFormatKHR = undefined,
    swap_chain_extent: vk.VkExtent2D = undefined,
    swap_chain_image_views: []vk.VkImageView = &.{},

    shader_module: vk.VkShaderModule = null,
    pipeline_layout: vk.VkPipelineLayout = null,
    graphics_pipeline: vk.VkPipeline = null,

    fn createGraphicsPipeline(self: *HelloTriangleApplication) !void {
        if (self.device == null) {
            return error.DeviceNotCreated;
        }

        if (self.pipeline_layout == null) {
            return error.PipelineLayoutNotCreated;
        }

        if (self.shader_module == null) {
            return error.ShaderModuleNotCreated;
        }

        if (self.graphics_pipeline != null) {
            return error.GraphicsPipelineAlreadyCreated;
        }

        const shader_stages = try self.createShaderStages();

        var vertex_input = vk.VkPipelineVertexInputStateCreateInfo{
            .sType =
                vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 0,
            .pVertexBindingDescriptions = null,
            .vertexAttributeDescriptionCount = 0,
            .pVertexAttributeDescriptions = null,
        };

        var input_assembly = vk.VkPipelineInputAssemblyStateCreateInfo{
            .sType =
                vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = vk.VK_FALSE,
        };

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

        var viewport_state = vk.VkPipelineViewportStateCreateInfo{
            .sType =
                vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewportCount = 1,
            .pViewports = &viewport,
            .scissorCount = 1,
            .pScissors = &scissor,
        };

        var rasterizer = vk.VkPipelineRasterizationStateCreateInfo{
            .sType =
                vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
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

        var multisampling = vk.VkPipelineMultisampleStateCreateInfo{
            .sType =
                vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT,
            .sampleShadingEnable = vk.VK_FALSE,
            .minSampleShading = 1.0,
            .pSampleMask = null,
            .alphaToCoverageEnable = vk.VK_FALSE,
            .alphaToOneEnable = vk.VK_FALSE,
        };

        var color_blend_attachment =
            vk.VkPipelineColorBlendAttachmentState{
                .blendEnable = vk.VK_FALSE,
                .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE,
                .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
                .colorBlendOp = vk.VK_BLEND_OP_ADD,
                .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
                .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO,
                .alphaBlendOp = vk.VK_BLEND_OP_ADD,
                .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT |
                    vk.VK_COLOR_COMPONENT_G_BIT |
                    vk.VK_COLOR_COMPONENT_B_BIT |
                    vk.VK_COLOR_COMPONENT_A_BIT,
            };

        var color_blending = vk.VkPipelineColorBlendStateCreateInfo{
            .sType =
                vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = vk.VK_FALSE,
            .logicOp = vk.VK_LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment,
            .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        var rendering_info = vk.VkPipelineRenderingCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
            .pNext = null,
            .viewMask = 0,
            .colorAttachmentCount = 1,
            .pColorAttachmentFormats =
                &self.swap_chain_surface_format.format,
            .depthAttachmentFormat = vk.VK_FORMAT_UNDEFINED,
            .stencilAttachmentFormat = vk.VK_FORMAT_UNDEFINED,
        };

        var pipeline_create_info = vk.VkGraphicsPipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = &rendering_info,
            .flags = 0,
            .stageCount = @intCast(shader_stages.len),
            .pStages = &shader_stages[0],
            .pVertexInputState = &vertex_input,
            .pInputAssemblyState = &input_assembly,
            .pTessellationState = null,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pDepthStencilState = null,
            .pColorBlendState = &color_blending,
            .pDynamicState = null,
            .layout = self.pipeline_layout,
            .renderPass = null,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        const result = vk.vkCreateGraphicsPipelines(
            self.device,
            null,
            1,
            &pipeline_create_info,
            null,
            &self.graphics_pipeline,
        );

        if (result != vk.VK_SUCCESS) {
            self.graphics_pipeline = null;
            std.log.err("Failed to create graphics pipeline", .{});
            return error.FailedToCreateGraphicsPipeline;
        }
    }

    fn destroyGraphicsPipeline(self: *HelloTriangleApplication) void {
        if (self.graphics_pipeline != null) {
            vk.vkDestroyPipeline(
                self.device,
                self.graphics_pipeline,
                null,
            );

            self.graphics_pipeline = null;
        }
    }
};
```

The surrounding `HelloTriangleApplication` in the project already provides the
remaining methods, including:

```zig
createShaderStages
createInstance
createLogicalDevice
createSwapChain
createImageViews
cleanup
```

No proxy wrapper, alternate module, or separate renderer architecture is
introduced.

---

## Recap & What's Next

This lesson translated the C++ dynamic-rendering pipeline description into raw
Vulkan Zig code.

The C++ structure chain:

```cpp
vk::StructureChain<
    vk::GraphicsPipelineCreateInfo,
    vk::PipelineRenderingCreateInfo
>
```

became an explicit Zig `pNext` connection:

```zig
var rendering_info = vk.VkPipelineRenderingCreateInfo{
    .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
    .pNext = null,
    .colorAttachmentCount = 1,
    .pColorAttachmentFormats =
        &self.swap_chain_surface_format.format,
    // ...
};

var pipeline_create_info = vk.VkGraphicsPipelineCreateInfo{
    .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
    .pNext = &rendering_info,
    .renderPass = null,
    // ...
};
```

Important points:

- Dynamic rendering describes attachment formats without a traditional render
  pass.
- `VkPipelineRenderingCreateInfo` is attached through
  `VkGraphicsPipelineCreateInfo.pNext`.
- The color attachment format comes from the existing swap-chain format.
- The dynamic-rendering feature must be enabled while creating the logical
  device.
- Raw Vulkan functions require an output handle and explicit `VkResult`
  checking.
- The graphics pipeline must be destroyed before the logical device.
- Static viewport and scissor state are used for this first implementation.
- The pipeline still depends on shader stages, a pipeline layout, and all
  required fixed-function state.

The next step is to create the command infrastructure that uses this pipeline:

1. create command pools and command buffers,
2. acquire a swap-chain image,
3. transition the image for rendering,
4. begin dynamic rendering with `vkCmdBeginRendering`,
5. bind the graphics pipeline,
6. issue a draw command,
7. end dynamic rendering,
8. transition the image for presentation,
9. present it through the graphics queue.
