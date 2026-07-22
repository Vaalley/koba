# Shader Modules :: Vulkan Documentation Project with Zig 0.16.0 and SDL3

## Overview

The previous lessons prepared the resources needed to begin drawing:

1. Koba creates an SDL3 window.
2. Vulkan creates an instance.
3. SDL3 creates a Vulkan surface.
4. Koba selects a physical device.
5. Koba creates a logical device and graphics queue.
6. Koba creates a swap chain.
7. Koba creates image views for the swap-chain images.

This lesson loads compiled Slang shader code and creates a Vulkan **shader
module**.

A shader module is Vulkan's representation of compiled shader instructions. It
is not yet a complete graphics pipeline and it does not draw anything by itself.
Instead, the module is supplied to a pipeline's shader-stage descriptions:

```text
Slang source
    |
    v
SPIR-V binary
    |
    v
VkShaderModule
    |
    v
vertex and fragment pipeline stages
    |
    v
graphics pipeline
```

The source shader contains both entry points:

- `vertMain` for the vertex stage,
- `fragMain` for the fragment stage.

The same Vulkan shader module can contain both entry points. The pipeline later
selects the appropriate entry point by name.

This translation extends the existing `HelloTriangleApplication` in
`src/main.zig`. It uses the project's raw C Vulkan bindings:

```zig
const std = @import("std");
const sdl = @import("sdl3");
const vk = @import("vulkan");
```

There are no Vulkan-Hpp or `vulkan-zig` proxy objects. Shader modules are
created and destroyed with:

```zig
vk.vkCreateShaderModule(...)
vk.vkDestroyShaderModule(...)
```

## Concepts & Explanations

### Why shaders are compiled to SPIR-V

The GPU does not execute Slang source code directly. Slang is compiled into
SPIR-V, a binary intermediate representation understood by Vulkan drivers.

Keeping shader compilation separate from application execution has several
advantages:

- the game does not need a shader compiler at runtime,
- shader syntax errors are found during the asset-build step,
- the renderer loads compact binary data,
- the same compiled shader can be reused by multiple pipeline configurations.

The trade-off is that shader files must be rebuilt whenever their source
changes. During development, a build step or file-watching tool can automate
this process.

### A shader module is not a shader stage

A `VkShaderModule` stores compiled code. It does not say:

- whether the code is a vertex or fragment shader,
- which entry point to call,
- what specialization constants to use.

Those details are supplied by `VkPipelineShaderStageCreateInfo`.

For this lesson, both stages use the same module:

```text
shader_module
    |
    +-- stage = VERTEX,   pName = "vertMain"
    |
    +-- stage = FRAGMENT, pName = "fragMain"
```

The stage description is where `"vertMain"` and `"fragMain"` are connected to
the Vulkan pipeline.

### Why the entry-point names must match

The Slang source declares:

```slang
[shader("vertex")]
VertexOutput vertMain(uint vid : SV_VertexID)
```

and:

```slang
[shader("fragment")]
float4 fragMain(VertexOutput inVert) : SV_Target
```

Therefore the Vulkan stage descriptions must use:

```zig
.pName = "vertMain",
.pName = "fragMain",
```

These names are not arbitrary. If the name does not exist in the SPIR-V module,
pipeline creation fails.

A common confusion is to use the source filename as the entry point. The
filename identifies the module file; `pName` identifies a function inside that
module.

### Why SPIR-V must be read as `u32`

Vulkan's `VkShaderModuleCreateInfo.pCode` points to 32-bit words:

```c
const uint32_t* pCode;
```

A file is naturally read as bytes, but SPIR-V must have a size divisible by four
and must be passed to Vulkan with suitable 32-bit alignment.

The translation therefore:

1. reads the file size,
2. rejects an empty file,
3. rejects a size that is not divisible by four,
4. allocates `u32` storage,
5. reads the file into the byte view of that aligned storage.

This is safer than reading into `[]u8` and blindly casting its pointer to
`[*]const u32`.

### Shader module lifetime

A shader module is needed while creating the graphics pipeline. After pipeline
creation succeeds, Vulkan has copied the necessary shader information into the
pipeline, so the application can destroy the module.

For a first renderer, keeping the module in `HelloTriangleApplication` is
simpler because:

- initialization and cleanup remain explicit,
- the later pipeline lesson can use the handle,
- the lifetime is easy to inspect while learning Vulkan.

The required cleanup order is:

```text
graphics pipeline
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

If the graphics pipeline is not yet present, destroy the shader module before
destroying the device.

### Per-vertex colors and shader interfaces

The vertex shader outputs:

```slang
float3 color;
float4 sv_position : SV_Position;
```

The fragment shader receives the same `VertexOutput` structure:

```slang
float4 fragMain(VertexOutput inVert) : SV_Target
```

The vertex stage therefore produces an interpolated color for each fragment. The
three vertices have red, green, and blue colors, so the rasterizer interpolates
those values across the triangle.

This is an important rendering connection:

```text
vertex data
    |
    v
vertex shader outputs
    |
    v
rasterizer interpolates values
    |
    v
fragment shader receives values
    |
    v
swap-chain image
```

The `SV_Position` and `SV_Target` semantics are translated into the
corresponding SPIR-V built-ins and outputs by Slang.

### Shader compilation is separate from Vulkan code

The Vulkan application should load `slang.spv`; it should not compile Slang
source itself.

For example, place the source in a shader directory:

```text
shaders/
    shader.slang
    slang.spv
```

The runtime path is relative to the process's current working directory. When
running from an IDE, the working directory may differ from the project
directory. If the file cannot be found, log the path and verify the program's
working directory.

## Code Translation Sections

### The combined Slang source

Create `shaders/shader.slang` with the following contents:

```slang
static float2 positions[3] = float2[](
    float2(0.0, -0.5),
    float2(0.5, 0.5),
    float2(-0.5, 0.5)
);

static float3 colors[3] = float3[](
    float3(1.0, 0.0, 0.0),
    float3(0.0, 1.0, 0.0),
    float3(0.0, 0.0, 1.0)
);

struct VertexOutput {
    float3 color;
    float4 sv_position : SV_Position;
};

[shader("vertex")]
VertexOutput vertMain(uint vid : SV_VertexID) {
    VertexOutput output;
    output.sv_position = float4(positions[vid], 0.0, 1.0);
    output.color = colors[vid];
    return output;
}

[shader("fragment")]
float4 fragMain(VertexOutput inVert) : SV_Target {
    return float4(inVert.color, 1.0);
}
```

The vertex shader uses `SV_VertexID`, so no vertex buffer is required yet.
Vulkan supplies the vertex ID when the draw command is issued.

The fragment shader receives the interpolated color and returns it as the final
pixel color.

### Compile the Slang shader

On Windows, use the Slang compiler included with the Vulkan SDK:

```bat
C:/VulkanSDK/1.4.350.0/bin/slangc.exe ^
    shaders/shader.slang ^
    -target spirv ^
    -profile spirv_1_4 ^
    -emit-spirv-directly ^
    -fvk-use-entrypoint-name ^
    -entry vertMain ^
    -entry fragMain ^
    -o shaders/slang.spv
```

On a Unix-like system, the SDK path may look like:

```bash
/home/user/VulkanSDK/x.x.x.x/x86_64/bin/slangc \
    shaders/shader.slang \
    -target spirv \
    -profile spirv_1_4 \
    -emit-spirv-directly \
    -fvk-use-entrypoint-name \
    -entry vertMain \
    -entry fragMain \
    -o shaders/slang.spv
```

The important options are:

- `-target spirv`: generate Vulkan shader code,
- `-profile spirv_1_4`: target SPIR-V 1.4,
- `-emit-spirv-directly`: emit SPIR-V rather than another intermediate format,
- `-fvk-use-entrypoint-name`: preserve the Slang entry-point names,
- `-entry vertMain -entry fragMain`: include both entry points.

The output file is binary. Do not edit it as text.

### Add shader-module state

Add this field to `HelloTriangleApplication` near the swap-chain and rendering
fields:

```zig
shader_module: vk.VkShaderModule = null,
```

For example:

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

    shader_module: vk.VkShaderModule = null,
};
```

A Vulkan handle is nullable in this project. `null` means that creation has not
succeeded or that cleanup has already destroyed the object.

### Load the SPIR-V file

Add this method to `HelloTriangleApplication`:

```zig
fn readShaderCode(
    self: *HelloTriangleApplication,
    path: []const u8,
) ![]u32 {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const file_stat = try file.stat();
    const byte_count: usize = @intCast(file_stat.size);

    if (byte_count == 0) {
        return error.EmptyShaderFile;
    }

    if (byte_count % @sizeOf(u32) != 0) {
        return error.ShaderFileSizeIsNotMultipleOfFour;
    }

    const word_count = byte_count / @sizeOf(u32);

    const words = try self.allocator.alloc(u32, word_count);
    errdefer self.allocator.free(words);

    const bytes = std.mem.sliceAsBytes(words);
    try file.readNoEof(bytes);

    return words;
}
```

The returned slice is owned by the caller. The caller must free it with:

```zig
self.allocator.free(shader_code);
```

The allocation uses `u32`, which gives the data the alignment expected by
`VkShaderModuleCreateInfo.pCode`.

The `readNoEof` call is important. It reports an error if the file ends before
all expected bytes are read instead of silently accepting a truncated shader.

### Create a raw Vulkan shader module

The C++ code uses a RAII constructor:

```cpp
vk::raii::ShaderModule shaderModule{ device, createInfo };
```

The raw C-binding translation must call `vk.vkCreateShaderModule` and provide an
output pointer:

```zig
fn createShaderModule(
    self: *HelloTriangleApplication,
    code: []const u32,
) !vk.VkShaderModule {
    if (code.len == 0) {
        return error.EmptyShaderCode;
    }

    var create_info = vk.VkShaderModuleCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .codeSize = code.len * @sizeOf(u32),
        .pCode = code.ptr,
    };

    var shader_module: vk.VkShaderModule = null;

    const result = vk.vkCreateShaderModule(
        self.device,
        &create_info,
        null,
        &shader_module,
    );

    if (result != vk.VK_SUCCESS) {
        std.log.err("Failed to create Vulkan shader module", .{});
        return error.FailedToCreateShaderModule;
    }

    return shader_module;
}
```

The field names preserve the raw Vulkan C names:

```zig
.sType
.pNext
.codeSize
.pCode
```

Do not translate them into names such as `.s_type` or `.code_size`.

### Load and create the module during Vulkan initialization

Add a method that combines file loading and module creation:

```zig
fn createShaderModules(self: *HelloTriangleApplication) !void {
    const shader_code = try self.readShaderCode("shaders/slang.spv");
    defer self.allocator.free(shader_code);

    self.shader_module = try self.createShaderModule(shader_code);

    std.log.debug("Created Vulkan shader module", .{});
}
```

The bytecode allocation only needs to survive until `vk.vkCreateShaderModule`
returns. The Vulkan shader module owns the created Vulkan-side object; it does
not retain the application's file buffer.

Extend the existing `initVulkan` method after the logical device and swap-chain
resources have been created:

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
}
```

The shader module only requires a logical device, so it can be created after
`createLogicalDevice`. Keeping it after image-view creation follows the
tutorial's resource order and makes the later pipeline step easy to append.

### Describe the vertex shader stage

The C++ stage description is:

```cpp
vk::PipelineShaderStageCreateInfo vertShaderStageInfo{
    .stage = vk::ShaderStageFlagBits::eVertex,
    .module = shaderModule,
    .pName = "vertMain"
};
```

The raw C-binding equivalent is:

```zig
fn makeVertexShaderStage(
    self: *HelloTriangleApplication,
) !vk.VkPipelineShaderStageCreateInfo {
    if (self.shader_module == null) {
        return error.ShaderModuleNotCreated;
    }

    return .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stage = vk.VK_SHADER_STAGE_VERTEX_BIT,
        .module = self.shader_module,
        .pName = "vertMain",
        .pSpecializationInfo = null,
    };
}
```

The `.stage` field tells Vulkan how to execute the entry point. The `.pName`
field selects the vertex function inside the module.

### Describe the fragment shader stage

The fragment stage uses the same module but a different entry point:

```zig
fn makeFragmentShaderStage(
    self: *HelloTriangleApplication,
) !vk.VkPipelineShaderStageCreateInfo {
    if (self.shader_module == null) {
        return error.ShaderModuleNotCreated;
    }

    return .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
        .module = self.shader_module,
        .pName = "fragMain",
        .pSpecializationInfo = null,
    };
}
```

The vertex and fragment stages must agree about the values passed between them.
Here, the vertex shader writes `color`, and the fragment shader reads `color`.

### Build the two-stage array for pipeline creation

The C++ source creates:

```cpp
vk::PipelineShaderStageCreateInfo shaderStages[] = {
    vertShaderStageInfo,
    fragShaderStageInfo
};
```

The Zig version uses a fixed-size array:

```zig
fn createShaderStages(
    self: *HelloTriangleApplication,
) ![2]vk.VkPipelineShaderStageCreateInfo {
    const vertex_stage = try self.makeVertexShaderStage();
    const fragment_stage = try self.makeFragmentShaderStage();

    return .{
        vertex_stage,
        fragment_stage,
    };
}
```

A fixed-size array is appropriate because this renderer always has exactly two
programmable stages. It avoids an allocator and communicates the count at
compile time.

Later, graphics-pipeline creation can use:

```zig
const shader_stages = try self.createShaderStages();

const pipeline_create_info = vk.VkGraphicsPipelineCreateInfo{
    // Other pipeline fields will be added in the next lesson.
    .stageCount = shader_stages.len,
    .pStages = &shader_stages,
    // ...
};
```

The stage array must remain alive while `vk.vkCreateGraphicsPipelines` reads it.
A local array is sufficient when pipeline creation happens in the same function.

### Destroy the shader module during cleanup

Add a helper:

```zig
fn destroyShaderModule(self: *HelloTriangleApplication) void {
    if (self.shader_module != null) {
        vk.vkDestroyShaderModule(
            self.device,
            self.shader_module,
            null,
        );
        self.shader_module = null;
    }
}
```

Call it before image views, the swap chain, and the logical device are
destroyed:

```zig
fn cleanup(self: *HelloTriangleApplication) void {
    self.destroyShaderModule();
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

If the graphics pipeline is added later, insert its destruction before
`destroyShaderModule()`:

```text
destroy graphics pipeline
destroy shader module
destroy image views
destroy swap chain
destroy logical device
```

### Complete shader-specific additions

The following code is the shader-specific portion to merge into the existing
`HelloTriangleApplication`:

```zig
shader_module: vk.VkShaderModule = null,

fn readShaderCode(
    self: *HelloTriangleApplication,
    path: []const u8,
) ![]u32 {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const file_stat = try file.stat();
    const byte_count: usize = @intCast(file_stat.size);

    if (byte_count == 0) {
        return error.EmptyShaderFile;
    }

    if (byte_count % @sizeOf(u32) != 0) {
        return error.ShaderFileSizeIsNotMultipleOfFour;
    }

    const words = try self.allocator.alloc(
        u32,
        byte_count / @sizeOf(u32),
    );
    errdefer self.allocator.free(words);

    try file.readNoEof(std.mem.sliceAsBytes(words));

    return words;
}

fn createShaderModule(
    self: *HelloTriangleApplication,
    code: []const u32,
) !vk.VkShaderModule {
    if (code.len == 0) {
        return error.EmptyShaderCode;
    }

    var create_info = vk.VkShaderModuleCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .codeSize = code.len * @sizeOf(u32),
        .pCode = code.ptr,
    };

    var shader_module: vk.VkShaderModule = null;

    const result = vk.vkCreateShaderModule(
        self.device,
        &create_info,
        null,
        &shader_module,
    );

    if (result != vk.VK_SUCCESS) {
        return error.FailedToCreateShaderModule;
    }

    return shader_module;
}

fn createShaderModules(self: *HelloTriangleApplication) !void {
    const shader_code = try self.readShaderCode(
        "shaders/slang.spv",
    );
    defer self.allocator.free(shader_code);

    self.shader_module = try self.createShaderModule(shader_code);
}

fn makeVertexShaderStage(
    self: *HelloTriangleApplication,
) !vk.VkPipelineShaderStageCreateInfo {
    if (self.shader_module == null) {
        return error.ShaderModuleNotCreated;
    }

    return .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stage = vk.VK_SHADER_STAGE_VERTEX_BIT,
        .module = self.shader_module,
        .pName = "vertMain",
        .pSpecializationInfo = null,
    };
}

fn makeFragmentShaderStage(
    self: *HelloTriangleApplication,
) !vk.VkPipelineShaderStageCreateInfo {
    if (self.shader_module == null) {
        return error.ShaderModuleNotCreated;
    }

    return .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
        .module = self.shader_module,
        .pName = "fragMain",
        .pSpecializationInfo = null,
    };
}

fn createShaderStages(
    self: *HelloTriangleApplication,
) ![2]vk.VkPipelineShaderStageCreateInfo {
    return .{
        try self.makeVertexShaderStage(),
        try self.makeFragmentShaderStage(),
    };
}

fn destroyShaderModule(self: *HelloTriangleApplication) void {
    if (self.shader_module != null) {
        vk.vkDestroyShaderModule(
            self.device,
            self.shader_module,
            null,
        );
        self.shader_module = null;
    }
}
```

The exact generated binding may expose a pointer field as a C pointer type
rather than a Zig many-pointer type. If the compiler reports a pointer-type
mismatch for `.pCode`, preserve the same data and use the pointer conversion
required by that generated declaration; do not change the shader code to a byte
buffer passed directly as an unaligned `u8` pointer.

## Recap & What's Next

This lesson added the first programmable GPU code to Koba:

- Slang source was compiled to SPIR-V.
- The SPIR-V file was loaded as aligned `u32` data.
- `vk.vkCreateShaderModule` created a raw Vulkan shader module.
- One module supplied both the vertex and fragment stages.
- `vertMain` and `fragMain` were selected through `.pName`.
- Shader-module cleanup was added before logical-device destruction.

The important distinction is:

```text
shader module = compiled shader code
shader stage   = module + stage type + entry point
pipeline       = shader stages + fixed-function rendering configuration
```

The next lesson can create the graphics pipeline. It will connect these shader
stages to:

- the swap-chain image format,
- the image views and framebuffers,
- vertex-input configuration,
- input assembly,
- viewport and scissor state,
- rasterization,
- multisampling,
- color blending,
- dynamic rendering or a render pass.

Once the pipeline exists, Koba will have enough information to record a command
buffer that invokes `vertMain` and `fragMain` to render the colored triangle.
