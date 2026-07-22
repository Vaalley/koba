# Introduction: Preparing the Graphics Pipeline in Vulkan with Zig 0.16.0

## Overview

The previous lessons built the resources that a renderer needs before it can
describe actual drawing:

1. Koba creates an SDL3 window.
2. Vulkan creates an instance.
3. SDL3 creates a Vulkan surface.
4. Koba selects a physical device.
5. Koba creates a logical device and graphics queue.
6. Koba creates a swap chain.
7. Koba retrieves swap-chain images.
8. Koba creates image views for those images.

This lesson adds the next initialization step:

```text
createGraphicsPipeline()
```

At this point, the method is intentionally empty. The purpose of this lesson is
to connect it to the existing Vulkan initialization sequence without pretending
that a graphics pipeline already exists.

A graphics pipeline will eventually describe how Vulkan transforms vertices into
pixels. It will include information such as:

- vertex and fragment shader stages,
- vertex input,
- primitive assembly,
- viewport and scissor behavior,
- rasterization,
- multisampling,
- color blending,
- the render-pass relationship.

The pipeline cannot be created yet because later lessons still need to introduce
shader modules, render passes, and pipeline-layout information. For now, Koba
adds the correct extension point to `HelloTriangleApplication`.

---

## Concepts & Explanations

### Why the graphics pipeline belongs after image views

A graphics pipeline is not an isolated Vulkan object. It describes how rendering
will happen, so it must eventually agree with the render targets and resources
used by the rest of the engine.

The initialization dependency will become:

```text
instance
    ↓
surface
    ↓
physical device
    ↓
logical device
    ↓
swap chain
    ↓
image views
    ↓
render pass
    ↓
pipeline layout
    ↓
graphics pipeline
```

The pipeline is placed after image-view creation in the current tutorial because
image views identify the swap-chain images that will eventually be used by
framebuffers.

A graphics pipeline does not render directly to an SDL window. The eventual
rendering path will look more like:

```text
acquire swap-chain image
    ↓
select framebuffer containing that image's view
    ↓
begin render pass
    ↓
bind graphics pipeline
    ↓
issue draw commands
    ↓
end render pass
    ↓
present swap-chain image
```

This is why the empty method is still useful now: it establishes the correct
place in the resource-creation sequence.

### A pipeline is a large immutable rendering description

Vulkan moves many rendering decisions into an explicitly created pipeline
object. This has an important trade-off.

The benefit is predictability and performance. Once a pipeline exists, Vulkan
does not need to infer or repeatedly validate every rendering choice during each
draw call.

The cost is that changing some rendering behavior may require creating another
pipeline. For example, changing:

- shaders,
- blend state,
- rasterization state,
- primitive topology,
- render-pass compatibility,

can require a different pipeline.

Game engines commonly manage several pipelines for different materials, object
types, or rendering passes.

### Why the method should already return `!void`

The C++ source shows:

```cpp
void createGraphicsPipeline() {

}
```

A literal Zig translation could be:

```zig
fn createGraphicsPipeline(self: *HelloTriangleApplication) void {
    _ = self;
}
```

However, Vulkan pipeline creation will return `VkResult`, and shader-module
creation, pipeline-layout creation, and allocation can also fail.

Using `!void` now means the method already has the correct shape for the next
lessons:

```zig
fn createGraphicsPipeline(self: *HelloTriangleApplication) !void
```

When the implementation becomes real, failures can use explicit error names such
as:

```zig
return error.FailedToCreateShaderModule;
return error.FailedToCreatePipelineLayout;
return error.FailedToCreateGraphicsPipeline;
```

The caller propagates those failures with `try`, matching the error-handling
style already used by instance, device, swap-chain, and image-view creation.

### Raw Vulkan bindings remain the project boundary

When pipeline creation is implemented, Koba must use the raw C Vulkan bindings:

```zig
vk.vkCreateGraphicsPipelines(...)
vk.vkCreatePipelineLayout(...)
vk.vkDestroyPipeline(...)
```

It must not use wrapper-style calls such as:

```zig
self.device.createGraphicsPipelines(...)
vk.DeviceProxy
vk.PipelineProxy
```

The generated bindings use Vulkan's C names and field names, for example:

```zig
vk.VkGraphicsPipelineCreateInfo
vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
.sType
.pNext
.stageCount
.pStages
```

Every result-returning Vulkan function must be checked explicitly against:

```zig
vk.VK_SUCCESS
```

That rule is especially important for pipeline creation because a pipeline may
fail due to invalid shader code, unsupported features, incompatible render-pass
state, or an incorrectly configured pipeline description.

### Pipeline cleanup will be part of the existing cleanup order

The graphics pipeline will depend on the logical device. Therefore it must be
destroyed before the device:

```text
graphics pipeline
pipeline layout
image views
swap chain
logical device
surface
debug messenger
instance
SDL window
SDL
```

The exact order between the pipeline and pipeline layout should follow the
objects' dependencies. In general, destroy objects that use a resource before
destroying that resource.

As with the swap chain and image views, cleanup should be explicit and guarded
by nullable handle state:

```zig
if (self.graphics_pipeline != null) {
    vk.vkDestroyPipeline(self.device, self.graphics_pipeline, null);
    self.graphics_pipeline = null;
}
```

The current source lesson does not create a pipeline yet, so no destruction code
should be added until the corresponding handle is actually stored.

---

## Code Translation Sections

### Extend `initVulkan`

The C++ source extends initialization like this:

```cpp
void initVulkan() {
    createInstance();
    setupDebugMessenger();
    createSurface();
    pickPhysicalDevice();
    createLogicalDevice();
    createSwapChain();
    createImageViews();
    createGraphicsPipeline();
}
```

The corresponding change in the existing `HelloTriangleApplication` is:

```zig
fn initVulkan(self: *HelloTriangleApplication) !void {
    try self.createInstance();
    try self.setupDebugMessenger();
    try self.createSurface();
    try self.pickPhysicalDevice();
    try self.createLogicalDevice();
    try self.createSwapChain();
    try self.createImageViews();
    try self.createGraphicsPipeline();
}
```

The `try` keywords are necessary because each method returns an error union. If
one initialization step fails, Zig immediately returns that error to the caller
instead of continuing with partially initialized Vulkan state.

The ordering is important:

- `createSwapChain` needs the surface, physical device, and logical device.
- `createImageViews` needs the swap-chain images.
- The future graphics pipeline will depend on later rendering objects associated
  with those images.

### Add the graphics-pipeline method

Add this method inside the existing `HelloTriangleApplication` struct:

```zig
fn createGraphicsPipeline(self: *HelloTriangleApplication) !void {
    _ = self;

    std.log.debug(
        "Graphics-pipeline creation is reserved for the next lesson",
        .{},
    );
}
```

This is the direct Zig translation of the empty C++ method, with two
project-specific improvements:

1. It uses `!void` so future Vulkan failures can be propagated.
2. It logs through `std.log.debug`, matching the existing application style.

The `_ = self;` statement makes it explicit that this first placeholder does not
yet use the application state. Without it, Zig may report that the parameter is
unused.

### A shorter placeholder is also valid

If a log message is not wanted at this stage, the method can be written as:

```zig
fn createGraphicsPipeline(self: *HelloTriangleApplication) !void {
    _ = self;
}
```

The logged version is generally more useful during engine development because it
confirms that initialization reached this stage.

### Do not create fake pipeline state yet

Do not add fields such as these until the corresponding Vulkan objects are
actually created:

```zig
graphics_pipeline: vk.VkPipeline = null,
pipeline_layout: vk.VkPipelineLayout = null,
```

Those fields will be needed in a later lesson, but adding them prematurely can
make cleanup misleading. A nullable Vulkan handle should represent an object
that the application may actually own, not an object that is merely planned.

When the pipeline lesson introduces real creation, the fields can be added near
the image-view and swap-chain fields:

```zig
graphics_pipeline: vk.VkPipeline = null,
pipeline_layout: vk.VkPipelineLayout = null,
```

The cleanup method can then destroy them before destroying their dependencies.

### Complete lesson-specific code to merge into `src/main.zig`

The following is the complete code change for this lesson. It assumes that the
earlier lessons already provide the existing `HelloTriangleApplication` methods:

```zig
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

    fn initVulkan(self: *HelloTriangleApplication) !void {
        try self.createInstance();
        try self.setupDebugMessenger();
        try self.createSurface();
        try self.pickPhysicalDevice();
        try self.createLogicalDevice();
        try self.createSwapChain();
        try self.createImageViews();
        try self.createGraphicsPipeline();
    }

    fn createGraphicsPipeline(self: *HelloTriangleApplication) !void {
        _ = self;

        std.log.debug(
            "Graphics-pipeline creation is reserved for the next lesson",
            .{},
        );
    }

    // Existing methods remain here:
    // createInstance
    // setupDebugMessenger
    // createSurface
    // pickPhysicalDevice
    // createLogicalDevice
    // createSwapChain
    // createImageViews
    // cleanup
};
```

The imports remain the project-defined modules:

```zig
const std = @import("std");
const sdl = @import("sdl3");
const vk = @import("vulkan");
```

No new module, proxy wrapper, or alternate application type is introduced.

### Future shape of pipeline creation

The next implementation will eventually follow the raw Vulkan pattern:

```zig
const result = vk.vkCreateGraphicsPipelines(
    self.device,
    null,
    1,
    &pipeline_create_info,
    null,
    &self.graphics_pipeline,
);

if (result != vk.VK_SUCCESS) {
    return error.FailedToCreateGraphicsPipeline;
}
```

This code is intentionally not part of the current placeholder implementation
because `pipeline_create_info` cannot be built correctly until the tutorial
introduces:

- shader modules,
- a pipeline layout,
- a render pass,
- shader-stage configuration,
- vertex-input configuration,
- viewport and scissor state,
- rasterization state,
- multisampling state,
- color-blend state.

Creating a partial pipeline description now would be more confusing than helpful
and would not produce a valid renderer.

---

## Recap & What's Next

This lesson translated the new initialization step from C++ to Zig:

```cpp
createGraphicsPipeline();
```

became:

```zig
try self.createGraphicsPipeline();
```

and the empty method became:

```zig
fn createGraphicsPipeline(self: *HelloTriangleApplication) !void {
    _ = self;
    std.log.debug(
        "Graphics-pipeline creation is reserved for the next lesson",
        .{},
    );
}
```

Important points:

- The method is called after swap-chain image views are created.
- `!void` prepares the method for future Vulkan failures.
- `try` propagates initialization errors through `initVulkan`.
- The implementation uses the existing `HelloTriangleApplication`.
- The code uses raw Vulkan bindings and does not introduce proxy objects.
- Pipeline state and cleanup handles should be added only when actual pipeline
  objects are created.

Next, Koba can begin building the graphics pipeline itself. The first required
piece is usually shader support: loading SPIR-V bytecode and creating Vulkan
shader modules. After that, the engine can define the pipeline layout, render
pass, fixed-function state, and finally call `vk.vkCreateGraphicsPipelines`.
