# Vertex Input Description in Vulkan with Zig 0.16.0

## Overview

In previous steps of our rendering pipeline setup, we hardcoded vertex data directly inside our vertex shader. While hardcoding geometry within SPIR-V bytecode works for basic tests, real-world game engines require dynamic mesh data streamed from memory buffers on the CPU or GPU.

This lesson covers how to configure Vulkan's **Vertex Input State**. You will learn:
1. How to define a vertex layout in memory using Zig structs.
2. How to update the Slang vertex shader to accept vertex attribute inputs (`SV_Position` and color attributes).
3. How to describe the stride and memory layout of vertex data using `VkVertexInputBindingDescription` and `VkVertexInputAttributeDescription`.
4. How to hook up these layout descriptions to `VkPipelineVertexInputStateCreateInfo` during graphics pipeline creation.

---

## Concepts & Explanations

### Why Describe Vertex Input to Vulkan?

When a GPU executes a vertex shader, it needs to read vertex attribute data (positions, surface normals, texture coordinates, vertex colors) out of memory buffers. However, memory buffers are raw byte arrays. The GPU hardware has no inherent understanding of how bytes map to attributes inside your shader.

Vulkan requires explicit structures describing this mapping:

```
Buffer Memory: [ Pos.X Pos.Y Col.R Col.G Col.B | Pos.X Pos.Y Col.R Col.G Col.B | ... ]
               |------- Vertex 0 (20 B) -------|------- Vertex 1 (20 B) -------|
               |<-Pos->|
               0B      8B                      20B
```

To tell the GPU how to interpret this memory, Vulkan divides the layout configuration into two concepts:

1. **Vertex Binding Description (`VkVertexInputBindingDescription`)**:
   - Describes *how memory is accessed* across vertices.
   - Sets the byte **stride** between consecutive vertex entries.
   - Configures the **input rate** (whether step updates occur per-vertex or per-instance).

2. **Vertex Attribute Description (`VkVertexInputAttributeDescription`)**:
   - Describes *how individual shader attributes map* to offset bytes inside a single vertex entry.
   - Connects shader `location` indices (e.g. `@location(0)`) to a buffer binding index.
   - Defines the data **format** (such as float pairs `R32G32_SFLOAT` for `vec2` positions).
   - Specifies the byte **offset** from the beginning of the vertex structure where an attribute starts.

---

### Key Vulkan Structures

#### 1. `VkVertexInputBindingDescription`

```zig
const binding_description = vulkan.VkVertexInputBindingDescription{
    .binding = 0,
    .stride = @sizeOf(Vertex),
    .inputRate = vulkan.VK_VERTEX_INPUT_RATE_VERTEX,
};
```

* **`binding`**: The index of the vertex buffer slot (binding index `0` for our standard pipeline).
* **`stride`**: Memory byte size between one vertex record and the next (`@sizeOf(Vertex)`).
* **`inputRate`**: Standard per-vertex rendering (`VK_VERTEX_INPUT_RATE_VERTEX`) or instanced rendering (`VK_VERTEX_INPUT_RATE_INSTANCE`).

#### 2. `VkVertexInputAttributeDescription`

```zig
const attribute_descriptions = [_]vulkan.VkVertexInputAttributeDescription{
    // Attribute 0: Position
    .{
        .location = 0,
        .binding = 0,
        .format = vulkan.VK_FORMAT_R32G32_SFLOAT,
        .offset = @offsetOf(Vertex, "pos"),
    },
    // Attribute 1: Color
    .{
        .location = 1,
        .binding = 0,
        .format = vulkan.VK_FORMAT_R32G32B32_SFLOAT,
        .offset = @offsetOf(Vertex, "color"),
    },
};
```

* **`location`**: Matches the `layout(location = N)` or attribute index expected by the vertex shader.
* **`binding`**: Tells Vulkan which vertex binding slot this attribute originates from.
* **`format`**: Describes the size and component types of the shader input:
  * `[2]f32` maps to `VK_FORMAT_R32G32_SFLOAT` (2 x 32-bit floats).
  * `[3]f32` maps to `VK_FORMAT_R32G32B32_SFLOAT` (3 x 32-bit floats).
* **`offset`**: Byte offset of the structure field obtained safely via Zig's `@offsetOf(Vertex, "field")`.

---

### Trade-offs, Edge Cases, and Confusion Points

#### `c_uint` vs Zig `u32` integer types
Raw C Vulkan structs derived via `addTranslateC` expect types matching C ABI declarations (`u32` for `uint32_t`). When setting struct attributes like `.location`, `.binding`, `.stride`, or `.offset`, pass Zig standard integer types directly—Zig coerces unassigned integer literals and exact width unsigned integers cleanly into translated C fields.

#### C-style naming conventions in Vulkan structs
Keep using lower-camelCase prefixes for raw Vulkan struct fields (`.sType`, `.pVertexBindingDescriptions`, `.pVertexAttributeDescriptions`). Do not alter field names to `snake_case` when instantiating `vulkan.VkPipelineVertexInputStateCreateInfo`.

#### Shader Location Alignment
The `location` specified in your attribute description **must match** the order and index of vertex input declarations inside your shader. If your shader expects `location = 0` for position and `location = 1` for color, declaring them in reverse inside `VkVertexInputAttributeDescription` will swap positional data and color vectors on the GPU!

---

## Code Translation Sections

### 1. Updated Slang Shader (`shaders/shader.slang`)

The vertex shader accepts explicit vertex inputs via a input struct `VSInput`:

```slang
struct VSInput {
    float2 inPosition;
    float3 inColor;
};

struct VSOutput {
    float4 pos : SV_Position;
    float3 color;
};

[shader("vertex")]
VSOutput vertMain(VSInput input) {
    VSOutput output;
    output.pos = float4(input.inPosition, 0.0, 1.0);
    output.color = input.inColor;
    return output;
}

[shader("fragment")]
float4 fragMain(VSOutput vertIn) : SV_TARGET {
    return float4(vertIn.color, 1.0);
}
```

*To recompile SPIR-V bytecode:*
```sh
slangc shaders/shader.slang -target spirv -profile spirv_1_4 -emit-spirv-directly -fvk-use-entrypoint-name -entry vertMain -entry fragMain -o shaders/slang.spv
```

---

### 2. Vertex Data & Binding Helpers (`src/main.zig`)

We define our CPU-side `Vertex` structure and helper routines returning Vulkan binding/attribute descriptors directly at namespace scope.

```zig
pub const Vertex = struct {
    pos: [2]f32,
    color: [3]f32,

    pub fn get_binding_description() vulkan.VkVertexInputBindingDescription {
        return .{
            .binding = 0,
            .stride = @sizeOf(Vertex),
            .inputRate = vulkan.VK_VERTEX_INPUT_RATE_VERTEX,
        };
    }

    pub fn get_attribute_descriptions() [2]vulkan.VkVertexInputAttributeDescription {
        return .{
            .{
                .location = 0,
                .binding = 0,
                .format = vulkan.VK_FORMAT_R32G32_SFLOAT,
                .offset = @offsetOf(Vertex, "pos"),
            },
            .{
                .location = 1,
                .binding = 0,
                .format = vulkan.VK_FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex, "color"),
            },
        };
    }
};
```

---

### 3. Pipeline Vertex Input State Setup

Inside `initialize_vulkan_create_graphics_pipeline()`, we update `VkPipelineVertexInputStateCreateInfo` to use our dynamic binding definitions instead of setting count fields to 0:

```zig
const binding_description = Vertex.get_binding_description();
const attribute_descriptions = Vertex.get_attribute_descriptions();

const vertex_input_info = vulkan.VkPipelineVertexInputStateCreateInfo{
    .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    .vertexBindingDescriptionCount = 1,
    .pVertexBindingDescriptions = &binding_description,
    .vertexAttributeDescriptionCount = attribute_descriptions.len,
    .pVertexAttributeDescriptions = &attribute_descriptions,
};
```

---

### Complete Integrated `src/main.zig` File

Here is the complete, compilable `src/main.zig` matching all Koba engine conventions and ground truth imports:

```zig
//! Koba is a Vulkan rendering engine built with SDL3 on Zig.
//! This application manages double-buffered rendering using a standard frames-in-flight pattern
//! to ensure that the CPU can record commands for a future frame while the GPU executes a past one.
//! Static resource allocations are handled at startup, and explicit assertions are used as
//! executable documentation to guarantee lifecycle pre/postconditions.

const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl3");
const vulkan = @import("vulkan");

const validation_layers = [_][*c]const u8{"VK_LAYER_KHRONOS_validation"};
const enable_validation_layers = builtin.mode == .Debug;
const required_device_extensions = [_][*:0]const u8{
    "VK_KHR_swapchain",
};
const frames_in_flight_max: u32 = 2;
const swap_chain_images_max: u32 = 8;

// +--------------------+
// |  Vertex Definition |
// +--------------------+

pub const Vertex = struct {
    pos: [2]f32,
    color: [3]f32,

    pub fn get_binding_description() vulkan.VkVertexInputBindingDescription {
        return .{
            .binding = 0,
            .stride = @sizeOf(Vertex),
            .inputRate = vulkan.VK_VERTEX_INPUT_RATE_VERTEX,
        };
    }

    pub fn get_attribute_descriptions() [2]vulkan.VkVertexInputAttributeDescription {
        return .{
            .{
                .location = 0,
                .binding = 0,
                .format = vulkan.VK_FORMAT_R32G32_SFLOAT,
                .offset = @offsetOf(Vertex, "pos"),
            },
            .{
                .location = 1,
                .binding = 0,
                .format = vulkan.VK_FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex, "color"),
            },
        };
    }
};

// +--------+
// |  Main  |
// +--------+

pub fn main() !void {
    var general_purpose_allocator = std.heap.DebugAllocator(.{}){};
    defer _ = general_purpose_allocator.deinit();
    const allocator = general_purpose_allocator.allocator();

    var application = Application{ .allocator = allocator };
    application.run() catch |failure| {
        std.log.err("Error: {s}", .{@errorName(failure)});
        std.process.exit(1);
    };
}

const Application = struct {
    const width_default: u32 = 1280;
    const height_default: u32 = 720;

    window: ?*sdl.SDL_Window = null,
    instance: vulkan.VkInstance = null,
    allocator: std.mem.Allocator,
    debug_messenger: vulkan.VkDebugUtilsMessengerEXT = null,
    surface: vulkan.VkSurfaceKHR = null,
    physical_device: vulkan.VkPhysicalDevice = null,
    device: vulkan.VkDevice = null,
    graphics_family: u32 = 0,
    graphics_queue: vulkan.VkQueue = null,
    swap_chain: vulkan.VkSwapchainKHR = null,
    swap_chain_images: [swap_chain_images_max]vulkan.VkImage = undefined,
    swap_chain_images_count: u32 = 0,
    swap_chain_surface_format: vulkan.VkSurfaceFormatKHR = undefined,
    swap_chain_extent: vulkan.VkExtent2D = undefined,
    swap_chain_image_views: [swap_chain_images_max]vulkan.VkImageView = undefined,
    framebuffer_resized: bool = false,
    shader_module: vulkan.VkShaderModule = null,
    pipeline_layout: vulkan.VkPipelineLayout = null,
    graphics_pipeline: vulkan.VkPipeline = null,
    command_pool: vulkan.VkCommandPool = null,
    command_buffers: [frames_in_flight_max]vulkan.VkCommandBuffer = undefined,
    present_complete_semaphores: [frames_in_flight_max]vulkan.VkSemaphore = undefined,
    render_finished_semaphores: [swap_chain_images_max]vulkan.VkSemaphore = undefined,
    in_flight_fences: [frames_in_flight_max]vulkan.VkFence = undefined,
    frame_index: u32 = 0,

    // +-------------+
    // |  Lifecycle  |
    // +-------------+

    pub fn run(self: *Application) !void {
        try self.initialize_window();
        defer self.cleanup();

        try self.initialize_vulkan();
        try self.main_loop();
    }

    fn initialize_window(self: *Application) !void {
        std.debug.assert(self.window == null);
        if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) {
            std.log.err("SDL Initialization Failed: {s}", .{sdl.SDL_GetError()});
            return error.SDLInitFailed;
        }

        self.window = sdl.SDL_CreateWindow(
            "SDL3 + Vulkan",
            @intCast(width_default),
            @intCast(height_default),
            sdl.SDL_WINDOW_VULKAN | sdl.SDL_WINDOW_RESIZABLE,
        ) orelse {
            std.log.err("Window Creation Failed: {s}", .{sdl.SDL_GetError()});
            return error.WindowCreationFailed;
        };

        std.debug.assert(self.window != null);
    }

    fn initialize_vulkan(self: *Application) !void {
        std.debug.assert(self.instance == null);
        std.debug.assert(self.device == null);
        std.debug.assert(self.surface == null);
        std.log.debug("Creating instance...", .{});
        try self.initialize_vulkan_create_instance();
        std.debug.assert(self.instance != null);

        std.log.debug("Setting up debug messenger...", .{});
        try self.initialize_vulkan_setup_debug_messenger();

        std.log.debug("Creating window surface...", .{});
        try self.initialize_vulkan_create_surface();
        std.debug.assert(self.surface != null);

        std.log.debug("Picking physical device...", .{});
        try self.initialize_vulkan_pick_physical_device();
        std.debug.assert(self.physical_device != null);

        std.log.debug("Creating logical device...", .{});
        try self.initialize_vulkan_create_logical_device();
        std.debug.assert(self.device != null);

        std.log.debug("Creating swap chain...", .{});
        try self.create_swap_chain();
        std.debug.assert(self.swap_chain != null);

        std.log.debug("Creating image views...", .{});
        try self.create_image_views();
        std.debug.assert(self.swap_chain_images_count > 0);

        std.log.debug("Creating shader modules...", .{});
        try self.initialize_vulkan_create_graphics_pipeline_create_shader_modules();
        std.debug.assert(self.shader_module != null);

        std.log.debug("Creating pipeline layout...", .{});
        try self.initialize_vulkan_create_pipeline_layout();
        std.debug.assert(self.pipeline_layout != null);

        std.log.debug("Creating graphics pipeline...", .{});
        try self.initialize_vulkan_create_graphics_pipeline();
        std.debug.assert(self.graphics_pipeline != null);

        std.log.debug("Creating command pool...", .{});
        try self.initialize_vulkan_create_command_pool();
        std.debug.assert(self.command_pool != null);

        std.log.debug("Creating command buffers...", .{});
        try self.initialize_vulkan_create_command_buffers();
        std.debug.assert(self.command_buffers.len == frames_in_flight_max);

        std.log.debug("Creating synchronization objects...", .{});
        try self.initialize_vulkan_create_synchronization_objects();
        std.debug.assert(self.present_complete_semaphores.len == frames_in_flight_max);

        std.log.info("Vulkan initialization complete", .{});
    }

    fn poll_events(self: *Application) bool {
        var event: sdl.SDL_Event = undefined;
        var running = true;

        while (sdl.SDL_PollEvent(&event)) {
            switch (event.type) {
                sdl.SDL_EVENT_QUIT => {
                    running = false;
                },

                sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED, sdl.SDL_EVENT_WINDOW_RESIZED => {
                    self.framebuffer_resized = true;
                },

                else => {},
            }
        }

        return running;
    }

    fn main_loop(self: *Application) !void {
        var running = true;
        var frames_per_second = FPSCounter.init();

        while (running) {
            running = self.poll_events();
            if (!running) break;

            try self.draw_frame();
            frames_per_second.tick(self.window);
        }

        if (self.device != null) {
            try vulkan_check(vulkan.vkDeviceWaitIdle(self.device), error.FailedToWaitForDeviceIdle);
        }
    }

    fn cleanup(self: *Application) void {
        std.log.debug("Cleaning up...", .{});

        self.cleanup_destroy_synchronization_objects();
        self.cleanup_destroy_command_buffers();

        if (self.command_pool != null and self.device != null) {
            std.log.debug("Destroying command pool", .{});
            vulkan.vkDestroyCommandPool(self.device, self.command_pool, null);
            self.command_pool = null;
        }

        self.cleanup_destroy_graphics_pipeline();
        self.cleanup_destroy_pipeline_layout();
        self.destroy_shader_module();

        self.cleanup_swap_chain();

        if (self.device != null) {
            std.log.debug("Destroying logical device", .{});
            vulkan.vkDestroyDevice(self.device, null);
        }

        if (self.surface != null) {
            std.log.debug("Destroying window surface", .{});
            vulkan.vkDestroySurfaceKHR(self.instance, self.surface, null);
        }

        self.destroy_debug_messenger();

        if (self.instance != null) {
            std.log.debug("Destroying instance", .{});
            vulkan.vkDestroyInstance(self.instance, null);
        }

        sdl.SDL_DestroyWindow(self.window);
        sdl.SDL_Quit();

        std.log.debug("Cleanup complete", .{});
    }

    // +------------------+
    // |  Instance Setup  |
    // +------------------+

    fn initialize_vulkan_create_instance(self: *Application) !void {
        std.debug.assert(self.instance == null);
        if (enable_validation_layers) {
            const supported = try check_validation_layer_support(self);
            if (!supported) {
                std.log.err("Validation layers requested, but not available!", .{});
                return error.ValidationLayersNotSupported;
            }

            std.log.debug("Running with validation layer(s):", .{});

            for (validation_layers) |validation_layer| {
                std.log.debug("  {s}", .{validation_layer});
            }
        }

        const application_information = vulkan.VkApplicationInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "Koba",
            .applicationVersion = vulkan.VK_MAKE_VERSION(1, 0, 0),
            .pEngineName = "No Engine",
            .engineVersion = vulkan.VK_MAKE_VERSION(1, 0, 0),
            .apiVersion = vulkan.VK_API_VERSION_1_4,
        };

        const required_extensions = try get_required_extensions(self);
        defer self.allocator.free(required_extensions);

        try check_extension_support(self, required_extensions);

        const required_layers: []const [*c]const u8 =
            if (enable_validation_layers) &validation_layers else &[_][*c]const u8{};

        var create_information = vulkan.VkInstanceCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &application_information,
            .enabledExtensionCount = @intCast(required_extensions.len),
            .ppEnabledExtensionNames = required_extensions.ptr,
            .enabledLayerCount = @intCast(required_layers.len),
            .ppEnabledLayerNames = required_layers.ptr,
        };

        try vulkan_check(
            vulkan.vkCreateInstance(&create_information, null, &self.instance),
            error.InstanceCreationFailed,
        );

        std.log.info("Vulkan instance created (API version 1.4)", .{});
    }

    fn check_validation_layer_support(self: *Application) !bool {
        _ = self;
        var available_layers: [64]vulkan.VkLayerProperties = undefined;
        var count: u32 = 0;
        try vulkan_check(
            vulkan.vkEnumerateInstanceLayerProperties(&count, null),
            error.ValidationLayerEnumerationFailed,
        );
        std.debug.assert(count <= available_layers.len);
        try vulkan_check(
            vulkan.vkEnumerateInstanceLayerProperties(&count, &available_layers),
            error.ValidationLayerEnumerationFailed,
        );
        const layers_slice = available_layers[0..count];

        for (validation_layers) |layer_name| {
            var layer_found = false;

            for (layers_slice) |*layer_properties| {
                const len = std.mem.indexOfScalar(u8, &layer_properties.layerName, 0) orelse layer_properties.layerName.len;
                const available_name = layer_properties.layerName[0..len];
                const requested_name = std.mem.span(layer_name);

                if (std.mem.eql(u8, available_name, requested_name)) {
                    layer_found = true;
                    break;
                }
            }

            if (!layer_found) return false;
        }

        return true;
    }

    fn check_extension_support(self: *Application, required_extensions: []const [*c]const u8) !void {
        _ = self;
        var available_extensions: [256]vulkan.VkExtensionProperties = undefined;
        var count: u32 = 0;
        try vulkan_check(
            vulkan.vkEnumerateInstanceExtensionProperties(null, &count, null),
            error.ExtensionEnumerationFailed,
        );
        std.debug.assert(count <= available_extensions.len);
        try vulkan_check(
            vulkan.vkEnumerateInstanceExtensionProperties(null, &count, &available_extensions),
            error.ExtensionEnumerationFailed,
        );
        const extensions_slice = available_extensions[0..count];

        for (required_extensions) |required_extension| {
            var extension_found = false;

            for (extensions_slice) |*extension_properties| {
                const len = std.mem.indexOfScalar(u8, &extension_properties.extensionName, 0) orelse extension_properties.extensionName.len;
                const available_name = extension_properties.extensionName[0..len];
                const requested_name = std.mem.span(required_extension);

                if (std.mem.eql(u8, available_name, requested_name)) {
                    extension_found = true;
                    break;
                }
            }

            if (!extension_found) return error.ExtensionNotSupported;
        }
    }

    fn get_required_extensions(self: *Application) ![][*c]const u8 {
        var sdl_extension_count: u32 = 0;
        const sdl_extensions = sdl.SDL_Vulkan_GetInstanceExtensions(&sdl_extension_count) orelse {
            std.log.err("Failed to query SDL Vulkan extensions: {s}", .{sdl.SDL_GetError()});
            return error.SDLVulkanExtensionsFailed;
        };

        var extensions: std.ArrayList([*c]const u8) = .empty;
        defer extensions.deinit(self.allocator);

        try extensions.appendSlice(self.allocator, sdl_extensions[0..sdl_extension_count]);

        if (enable_validation_layers) {
            try extensions.append(self.allocator, vulkan.VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
        }

        return extensions.toOwnedSlice(self.allocator);
    }

    // +-------------------+
    // |  Debug Messenger  |
    // +-------------------+

    fn initialize_vulkan_setup_debug_messenger(self: *Application) !void {
        if (!enable_validation_layers) return;
        std.debug.assert(self.instance != null);
        std.debug.assert(self.debug_messenger == null);

        const create_information = vulkan.VkDebugUtilsMessengerCreateInfoEXT{
            .sType = vulkan.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .messageSeverity = vulkan.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                vulkan.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType = vulkan.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                vulkan.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT |
                vulkan.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT,
            .pfnUserCallback = debug_callback,
        };

        const create_fn: vulkan.PFN_vkCreateDebugUtilsMessengerEXT = @ptrCast(
            vulkan.vkGetInstanceProcAddr(self.instance, "vkCreateDebugUtilsMessengerEXT"),
        );

        const function = create_fn orelse {
            std.log.err("vkCreateDebugUtilsMessengerEXT is not available", .{});
            return error.DebugMessengerExtensionNotFound;
        };

        try vulkan_check(
            function(self.instance, &create_information, null, &self.debug_messenger),
            error.DebugMessengerCreationFailed,
        );
    }

    fn destroy_debug_messenger(self: *Application) void {
        if (!enable_validation_layers or self.debug_messenger == null) return;

        const destroy_fn: vulkan.PFN_vkDestroyDebugUtilsMessengerEXT = @ptrCast(
            vulkan.vkGetInstanceProcAddr(self.instance, "vkDestroyDebugUtilsMessengerEXT"),
        );

        if (destroy_fn) |function| {
            function(self.instance, self.debug_messenger, null);
            self.debug_messenger = null;
        }
    }

    // +--------------------+
    // |  Surface & Device  |
    // +--------------------+

    fn initialize_vulkan_create_surface(self: *Application) !void {
        std.debug.assert(self.instance != null);
        std.debug.assert(self.window != null);
        std.debug.assert(self.surface == null);

        if (!sdl.SDL_Vulkan_CreateSurface(self.window, self.instance, null, &self.surface)) {
            std.log.err("Failed to create window surface: {s}", .{sdl.SDL_GetError()});
            return error.SurfaceCreationFailed;
        }
    }

    fn initialize_vulkan_pick_physical_device(self: *Application) !void {
        std.debug.assert(self.instance != null);
        std.debug.assert(self.physical_device == null);

        const physical_devices = try vulkan_enumerate(
            self.allocator,
            vulkan.VkPhysicalDevice,
            vulkan.vkEnumeratePhysicalDevices,
            .{self.instance},
            error.PhysicalDevicesEnumerationFailed,
        );
        defer self.allocator.free(physical_devices);

        if (physical_devices.len == 0) {
            return error.NoGPUsWithVulkanSupport;
        }

        for (physical_devices) |physical_device| {
            if (try self.is_device_suitable(physical_device)) {
                self.physical_device = physical_device;
                break;
            }
        }

        if (self.physical_device == null) {
            return error.NoSuitableGPUFound;
        }

        var properties: vulkan.VkPhysicalDeviceProperties = undefined;
        vulkan.vkGetPhysicalDeviceProperties(self.physical_device, &properties);
        const name_len = std.mem.indexOfScalar(u8, &properties.deviceName, 0) orelse properties.deviceName.len;
        std.log.info("Selected GPU: {s}", .{properties.deviceName[0..name_len]});
    }

    fn is_device_suitable(self: *Application, physical_device: vulkan.VkPhysicalDevice) !bool {
        const graphics_family = try find_graphics_queue_family(self.allocator, physical_device, self.surface);
        if (graphics_family == null) return false;

        const extensions_supported = try check_device_extension_support(self.allocator, physical_device);
        if (!extensions_supported) return false;

        const swap_chain_adequate = try check_swap_chain_support(self.allocator, physical_device, self.surface);
        if (!swap_chain_adequate) return false;

        return true;
    }

    fn initialize_vulkan_create_logical_device(self: *Application) !void {
        std.debug.assert(self.physical_device != null);
        std.debug.assert(self.device == null);

        const graphics_family = (try find_graphics_queue_family(self.allocator, self.physical_device, self.surface)) orelse
            return error.NoSuitableGraphicsQueueFamily;
        self.graphics_family = graphics_family;

        const queue_priority: f32 = 1.0;
        const queue_create_info = vulkan.VkDeviceQueueCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = graphics_family,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };

        const required_layers: []const [*c]const u8 =
            if (enable_validation_layers) &validation_layers else &[_][*c]const u8{};

        const device_create_info = vulkan.VkDeviceCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_create_info,
            .enabledExtensionCount = @intCast(required_device_extensions.len),
            .ppEnabledExtensionNames = required_device_extensions.ptr,
            .enabledLayerCount = @intCast(required_layers.len),
            .ppEnabledLayerNames = required_layers.ptr,
        };

        try vulkan_check(
            vulkan.vkCreateDevice(self.physical_device, &device_create_info, null, &self.device),
            error.LogicalDeviceCreationFailed,
        );

        vulkan.vkGetDeviceQueue(self.device, self.graphics_family, 0, &self.graphics_queue);
    }

    // +--------------+
    // |  Swap Chain  |
    // +--------------+

    fn create_swap_chain(self: *Application) !void {
        std.debug.assert(self.physical_device != null);
        std.debug.assert(self.device != null);
        std.debug.assert(self.surface != null);

        var capabilities: vulkan.VkSurfaceCapabilitiesKHR = undefined;
        try vulkan_check(
            vulkan.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface, &capabilities),
            error.FailedToGetSurfaceCapabilities,
        );

        const surface_formats = try vulkan_enumerate(
            self.allocator,
            vulkan.VkSurfaceFormatKHR,
            vulkan.vkGetPhysicalDeviceSurfaceFormatsKHR,
            .{ self.physical_device, self.surface },
            error.FailedToGetSurfaceFormats,
        );
        defer self.allocator.free(surface_formats);

        const present_modes = try vulkan_enumerate(
            self.allocator,
            vulkan.VkPresentModeKHR,
            vulkan.vkGetPhysicalDeviceSurfacePresentModesKHR,
            .{ self.physical_device, self.surface },
            error.FailedToGetPresentModes,
        );
        defer self.allocator.free(present_modes);

        const surface_format = choose_swap_surface_format(surface_formats);
        const present_mode = choose_swap_present_mode(present_modes);
        const extent = choose_swap_extent(self.window, capabilities);
        const image_count = choose_swap_min_image_count(capabilities);

        var create_info = vulkan.VkSwapchainCreateInfoKHR{
            .sType = vulkan.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = surface_format.format,
            .imageColorSpace = surface_format.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = vulkan.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = vulkan.VK_SHARING_MODE_EXCLUSIVE,
            .preTransform = capabilities.currentTransform,
            .compositeAlpha = vulkan.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = present_mode,
            .clipped = vulkan.VK_TRUE,
            .oldSwapchain = null,
        };

        const queue_family_indices = [_]u32{self.graphics_family};
        create_info.queueFamilyIndexCount = 1;
        create_info.pQueueFamilyIndices = &queue_family_indices;

        try vulkan_check(
            vulkan.vkCreateSwapchainKHR(self.device, &create_info, null, &self.swap_chain),
            error.SwapchainCreationFailed,
        );

        var actual_image_count: u32 = 0;
        try vulkan_check(
            vulkan.vkGetSwapchainImagesKHR(self.device, self.swap_chain, &actual_image_count, null),
            error.FailedToGetSwapchainImages,
        );
        std.debug.assert(actual_image_count <= swap_chain_images_max);

        try vulkan_check(
            vulkan.vkGetSwapchainImagesKHR(self.device, self.swap_chain, &actual_image_count, &self.swap_chain_images),
            error.FailedToGetSwapchainImages,
        );

        self.swap_chain_images_count = actual_image_count;
        self.swap_chain_surface_format = surface_format;
        self.swap_chain_extent = extent;
    }

    fn create_image_views(self: *Application) !void {
        std.debug.assert(self.device != null);
        std.debug.assert(self.swap_chain_images_count > 0);

        for (0..self.swap_chain_images_count) |index| {
            const create_info = vulkan.VkImageViewCreateInfo{
                .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = self.swap_chain_images[index],
                .viewType = vulkan.VK_IMAGE_VIEW_TYPE_2D,
                .format = self.swap_chain_surface_format.format,
                .components = .{
                    .r = vulkan.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .g = vulkan.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .b = vulkan.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .a = vulkan.VK_COMPONENT_SWIZZLE_IDENTITY,
                },
                .subresourceRange = .{
                    .aspectMask = vulkan.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
            };

            try vulkan_check(
                vulkan.vkCreateImageView(self.device, &create_info, null, &self.swap_chain_image_views[index]),
                error.ImageViewCreationFailed,
            );
        }
    }

    fn cleanup_swap_chain(self: *Application) void {
        if (self.device == null) return;

        for (0..self.swap_chain_images_count) |index| {
            if (self.swap_chain_image_views[index] != null) {
                vulkan.vkDestroyImageView(self.device, self.swap_chain_image_views[index], null);
                self.swap_chain_image_views[index] = null;
            }
        }
        self.swap_chain_images_count = 0;

        if (self.swap_chain != null) {
            vulkan.vkDestroySwapchainKHR(self.device, self.swap_chain, null);
            self.swap_chain = null;
        }
    }

    fn recreate_swap_chain(self: *Application) !void {
        var width: i32 = 0;
        var height: i32 = 0;
        _ = sdl.SDL_GetWindowSizeInPixels(self.window, &width, &height);

        while (width == 0 or height == 0) {
            _ = sdl.SDL_GetWindowSizeInPixels(self.window, &width, &height);
            _ = self.poll_events();
            sdl.SDL_Delay(10);
        }

        try vulkan_check(vulkan.vkDeviceWaitIdle(self.device), error.FailedToWaitForDeviceIdle);

        self.cleanup_swap_chain();

        try self.create_swap_chain();
        try self.create_image_views();
    }

    // +-------------+
    // |  Pipeline   |
    // +-------------+

    fn initialize_vulkan_create_graphics_pipeline_create_shader_modules(self: *Application) !void {
        std.debug.assert(self.device != null);
        std.debug.assert(self.shader_module == null);

        const spirv_code = @embedFile("shaders/slang.spv");
        const spirv_aligned = std.mem.bytesAsSlice(u32, spirv_code);

        const create_info = vulkan.VkShaderModuleCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .codeSize = spirv_code.len,
            .pCode = spirv_aligned.ptr,
        };

        try vulkan_check(
            vulkan.vkCreateShaderModule(self.device, &create_info, null, &self.shader_module),
            error.ShaderModuleCreationFailed,
        );
    }

    fn destroy_shader_module(self: *Application) void {
        if (self.shader_module != null and self.device != null) {
            vulkan.vkDestroyShaderModule(self.device, self.shader_module, null);
            self.shader_module = null;
        }
    }

    fn initialize_vulkan_create_pipeline_layout(self: *Application) !void {
        std.debug.assert(self.device != null);
        std.debug.assert(self.pipeline_layout == null);

        const pipeline_layout_info = vulkan.VkPipelineLayoutCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 0,
            .pSetLayouts = null,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };

        try vulkan_check(
            vulkan.vkCreatePipelineLayout(self.device, &pipeline_layout_info, null, &self.pipeline_layout),
            error.PipelineLayoutCreationFailed,
        );
    }

    fn cleanup_destroy_pipeline_layout(self: *Application) void {
        if (self.pipeline_layout != null and self.device != null) {
            vulkan.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
            self.pipeline_layout = null;
        }
    }

    fn initialize_vulkan_create_graphics_pipeline(self: *Application) !void {
        std.debug.assert(self.device != null);
        std.debug.assert(self.shader_module != null);
        std.debug.assert(self.pipeline_layout != null);
        std.debug.assert(self.graphics_pipeline == null);

        const shader_stages = [_]vulkan.VkPipelineShaderStageCreateInfo{
            .{
                .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .stage = vulkan.VK_SHADER_STAGE_VERTEX_BIT,
                .module = self.shader_module,
                .pName = "vertMain",
            },
            .{
                .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .stage = vulkan.VK_SHADER_STAGE_FRAGMENT_BIT,
                .module = self.shader_module,
                .pName = "fragMain",
            },
        };

        // Retrieve binding and attribute descriptions for vertex input state
        const binding_description = Vertex.get_binding_description();
        const attribute_descriptions = Vertex.get_attribute_descriptions();

        const vertex_input_info = vulkan.VkPipelineVertexInputStateCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .vertexBindingDescriptionCount = 1,
            .pVertexBindingDescriptions = &binding_description,
            .vertexAttributeDescriptionCount = attribute_descriptions.len,
            .pVertexAttributeDescriptions = &attribute_descriptions,
        };

        const input_assembly_info = vulkan.VkPipelineInputAssemblyStateCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .topology = vulkan.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = vulkan.VK_FALSE,
        };

        const viewport_state_info = vulkan.VkPipelineViewportStateCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1,
            .pViewports = null,
            .scissorCount = 1,
            .pScissors = null,
        };

        const rasterizer_info = vulkan.VkPipelineRasterizationStateCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .depthClampEnable = vulkan.VK_FALSE,
            .rasterizerDiscardEnable = vulkan.VK_FALSE,
            .polygonMode = vulkan.VK_POLYGON_MODE_FILL,
            .lineWidth = 1.0,
            .cullMode = vulkan.VK_CULL_MODE_BACK_BIT,
            .frontFace = vulkan.VK_FRONT_FACE_CLOCKWISE,
            .depthBiasEnable = vulkan.VK_FALSE,
        };

        const multisampling_info = vulkan.VkPipelineMultisampleStateCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .sampleShadingEnable = vulkan.VK_FALSE,
            .rasterizationSamples = vulkan.VK_SAMPLE_COUNT_1_BIT,
        };

        const color_blend_attachment = vulkan.VkPipelineColorBlendAttachmentState{
            .colorWriteMask = vulkan.VK_COLOR_COMPONENT_R_BIT |
                vulkan.VK_COLOR_COMPONENT_G_BIT |
                vulkan.VK_COLOR_COMPONENT_B_BIT |
                vulkan.VK_COLOR_COMPONENT_A_BIT,
            .blendEnable = vulkan.VK_FALSE,
        };

        const color_blending_info = vulkan.VkPipelineColorBlendStateCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .logicOpEnable = vulkan.VK_FALSE,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment,
        };

        const dynamic_states = [_]vulkan.VkDynamicState{
            vulkan.VK_DYNAMIC_STATE_VIEWPORT,
            vulkan.VK_DYNAMIC_STATE_SCISSOR,
        };

        const dynamic_state_info = vulkan.VkPipelineDynamicStateCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };

        const color_attachment_format = self.swap_chain_surface_format.format;
        var pipeline_rendering_create_info = vulkan.VkPipelineRenderingCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
            .colorAttachmentCount = 1,
            .pColorAttachmentFormats = &color_attachment_format,
        };

        const pipeline_info = vulkan.VkGraphicsPipelineCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = &pipeline_rendering_create_info,
            .stageCount = shader_stages.len,
            .pStages = &shader_stages,
            .pVertexInputState = &vertex_input_info,
            .pInputAssemblyState = &input_assembly_info,
            .pViewportState = &viewport_state_info,
            .pRasterizationState = &rasterizer_info,
            .pMultisampleState = &multisampling_info,
            .pColorBlendState = &color_blending_info,
            .pDynamicState = &dynamic_state_info,
            .layout = self.pipeline_layout,
            .renderPass = null,
            .subpass = 0,
        };

        try vulkan_check(
            vulkan.vkCreateGraphicsPipelines(
                self.device,
                null,
                1,
                &pipeline_info,
                null,
                &self.graphics_pipeline,
            ),
            error.GraphicsPipelineCreationFailed,
        );
    }

    fn cleanup_destroy_graphics_pipeline(self: *Application) void {
        if (self.graphics_pipeline != null and self.device != null) {
            vulkan.vkDestroyPipeline(self.device, self.graphics_pipeline, null);
            self.graphics_pipeline = null;
        }
    }

    // +--------------------+
    // |  Command Recording |
    // +--------------------+

    fn initialize_vulkan_create_command_pool(self: *Application) !void {
        std.debug.assert(self.device != null);
        std.debug.assert(self.command_pool == null);

        const pool_info = vulkan.VkCommandPoolCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = vulkan.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.graphics_family,
        };

        try vulkan_check(
            vulkan.vkCreateCommandPool(self.device, &pool_info, null, &self.command_pool),
            error.CommandPoolCreationFailed,
        );
    }

    fn initialize_vulkan_create_command_buffers(self: *Application) !void {
        std.debug.assert(self.device != null);
        std.debug.assert(self.command_pool != null);

        const alloc_info = vulkan.VkCommandBufferAllocateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.command_pool,
            .level = vulkan.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = frames_in_flight_max,
        };

        try vulkan_check(
            vulkan.vkAllocateCommandBuffers(self.device, &alloc_info, &self.command_buffers),
            error.CommandBufferAllocationFailed,
        );
    }

    fn cleanup_destroy_command_buffers(self: *Application) void {
        if (self.command_pool != null and self.device != null) {
            vulkan.vkFreeCommandBuffers(
                self.device,
                self.command_pool,
                frames_in_flight_max,
                &self.command_buffers,
            );
        }
    }

    fn record_command_buffer(self: *Application, command_buffer: vulkan.VkCommandBuffer, image_index: u32) !void {
        const begin_info = vulkan.VkCommandBufferBeginInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        };

        try vulkan_check(
            vulkan.vkBeginCommandBuffer(command_buffer, &begin_info),
            error.FailedToBeginCommandBuffer,
        );

        const image = self.swap_chain_images[image_index];

        const barrier_to_render = vulkan.VkImageMemoryBarrier{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask = 0,
            .dstAccessMask = vulkan.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .oldLayout = vulkan.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .srcQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresourceRange = .{
                .aspectMask = vulkan.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        vulkan.vkCmdPipelineBarrier(
            command_buffer,
            vulkan.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &barrier_to_render,
        );

        const clear_color = vulkan.VkClearValue{
            .color = .{ .float32 = [_]f32{ 0.0, 0.0, 0.0, 1.0 } },
        };

        const color_attachment = vulkan.VkRenderingAttachmentInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = self.swap_chain_image_views[image_index],
            .imageLayout = vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .loadOp = vulkan.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vulkan.VK_ATTACHMENT_STORE_OP_STORE,
            .clearValue = clear_color,
        };

        const rendering_info = vulkan.VkRenderingInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_RENDERING_INFO,
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = self.swap_chain_extent,
            },
            .layerCount = 1,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_attachment,
        };

        vulkan.vkCmdBeginRendering(command_buffer, &rendering_info);

        vulkan.vkCmdBindPipeline(command_buffer, vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS, self.graphics_pipeline);

        const viewport = vulkan.VkViewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(self.swap_chain_extent.width),
            .height = @floatFromInt(self.swap_chain_extent.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        vulkan.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

        const scissor = vulkan.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swap_chain_extent,
        };
        vulkan.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

        vulkan.vkCmdDraw(command_buffer, 3, 1, 0, 0);

        vulkan.vkCmdEndRendering(command_buffer);

        const barrier_to_present = vulkan.VkImageMemoryBarrier{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask = vulkan.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = 0,
            .oldLayout = vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .newLayout = vulkan.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            .srcQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresourceRange = .{
                .aspectMask = vulkan.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        vulkan.vkCmdPipelineBarrier(
            command_buffer,
            vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            vulkan.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &barrier_to_present,
        );

        try vulkan_check(
            vulkan.vkEndCommandBuffer(command_buffer),
            error.FailedToRecordCommandBuffer,
        );
    }

    // +--------------------+
    // |  Synchronization   |
    // +--------------------+

    fn initialize_vulkan_create_synchronization_objects(self: *Application) !void {
        std.debug.assert(self.device != null);

        const semaphore_info = vulkan.VkSemaphoreCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        };

        const fence_info = vulkan.VkFenceCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = vulkan.VK_FENCE_CREATE_SIGNALED_BIT,
        };

        for (0..frames_in_flight_max) |index| {
            try vulkan_check(
                vulkan.vkCreateSemaphore(self.device, &semaphore_info, null, &self.present_complete_semaphores[index]),
                error.SemaphoreCreationFailed,
            );
            try vulkan_check(
                vulkan.vkCreateFence(self.device, &fence_info, null, &self.in_flight_fences[index]),
                error.FenceCreationFailed,
            );
        }

        for (0..swap_chain_images_max) |index| {
            try vulkan_check(
                vulkan.vkCreateSemaphore(self.device, &semaphore_info, null, &self.render_finished_semaphores[index]),
                error.SemaphoreCreationFailed,
            );
        }
    }

    fn cleanup_destroy_synchronization_objects(self: *Application) void {
        if (self.device == null) return;

        for (0..frames_in_flight_max) |index| {
            if (self.present_complete_semaphores[index] != null) {
                vulkan.vkDestroySemaphore(self.device, self.present_complete_semaphores[index], null);
            }
            if (self.in_flight_fences[index] != null) {
                vulkan.vkDestroyFence(self.device, self.in_flight_fences[index], null);
            }
        }

        for (0..swap_chain_images_max) |index| {
            if (self.render_finished_semaphores[index] != null) {
                vulkan.vkDestroySemaphore(self.device, self.render_finished_semaphores[index], null);
            }
        }
    }

    // +-----------+
    // | Rendering |
    // +-----------+

    fn draw_frame(self: *Application) !void {
        const in_flight_fence = self.in_flight_fences[self.frame_index];

        try vulkan_check(
            vulkan.vkWaitForFences(self.device, 1, &in_flight_fence, vulkan.VK_TRUE, std.math.maxInt(u64)),
            error.FailedToWaitForFence,
        );

        var image_index: u32 = 0;
        const result_acquire = vulkan.vkAcquireNextImageKHR(
            self.device,
            self.swap_chain,
            std.math.maxInt(u64),
            self.present_complete_semaphores[self.frame_index],
            null,
            &image_index,
        );

        if (result_acquire == vulkan.VK_ERROR_OUT_OF_DATE_KHR) {
            try self.recreate_swap_chain();
            return;
        } else if (result_acquire != vulkan.VK_SUCCESS and result_acquire != vulkan.VK_SUBOPTIMAL_KHR) {
            return error.FailedToAcquireSwapchainImage;
        }

        try vulkan_check(
            vulkan.vkResetFences(self.device, 1, &in_flight_fence),
            error.FailedToResetFence,
        );

        const command_buffer = self.command_buffers[self.frame_index];
        try vulkan_check(
            vulkan.vkResetCommandBuffer(command_buffer, 0),
            error.FailedToResetCommandBuffer,
        );
        try self.record_command_buffer(command_buffer, image_index);

        const wait_semaphores = [_]vulkan.VkSemaphore{self.present_complete_semaphores[self.frame_index]};
        const wait_stages = [_]vulkan.VkPipelineStageFlags{vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const signal_semaphores = [_]vulkan.VkSemaphore{self.render_finished_semaphores[image_index]};

        const submit_info = vulkan.VkSubmitInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &wait_semaphores,
            .pWaitDstStageMask = &wait_stages,
            .commandBufferCount = 1,
            .pCommandBuffers = &command_buffer,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &signal_semaphores,
        };

        try vulkan_check(
            vulkan.vkQueueSubmit(self.graphics_queue, 1, &submit_info, in_flight_fence),
            error.FailedToSubmitDrawCommandBuffer,
        );

        const swap_chains = [_]vulkan.VkSwapchainKHR{self.swap_chain};
        const present_info = vulkan.VkPresentInfoKHR{
            .sType = vulkan.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &signal_semaphores,
            .swapchainCount = 1,
            .pSwapchains = &swap_chains,
            .pImageIndices = &image_index,
        };

        const result_present = vulkan.vkQueuePresentKHR(self.graphics_queue, &present_info);

        if (result_present == vulkan.VK_ERROR_OUT_OF_DATE_KHR or result_present == vulkan.VK_SUBOPTIMAL_KHR or self.framebuffer_resized) {
            self.framebuffer_resized = false;
            try self.recreate_swap_chain();
        } else if (result_present != vulkan.VK_SUCCESS) {
            return error.FailedToPresentSwapchainImage;
        }

        self.frame_index = (self.frame_index + 1) % frames_in_flight_max;
    }
};

// +------------------+
// |  Vulkan Helpers  |
// +------------------+

fn vulkan_check(result: vulkan.VkResult, err: anyerror) !void {
    if (result != vulkan.VK_SUCCESS) {
        std.log.err("Vulkan error: {d} ({s})", .{ result, @errorName(err) });
        return err;
    }
}

fn vulkan_enumerate(
    allocator: std.mem.Allocator,
    comptime T: type,
    comptime enum_fn: anytype,
    args: anytype,
    err: anyerror,
) ![]T {
    var count: u32 = 0;

    const count_args = args ++ .{ &count, null };
    try vulkan_check(@call(.auto, enum_fn, count_args), err);

    if (count == 0) return &[_]T{};

    const items = try allocator.alloc(T, count);
    errdefer allocator.free(items);

    const fill_args = args ++ .{ &count, items.ptr };
    try vulkan_check(@call(.auto, enum_fn, fill_args), err);

    return items;
}

fn debug_callback(
    message_severity: vulkan.VkDebugUtilsMessageSeverityFlagBitsEXT,
    message_types: vulkan.VkDebugUtilsMessageTypeFlagsEXT,
    p_callback_data: [*c]const vulkan.VkDebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(.c) vulkan.VkBool32 {
    _ = message_types;
    _ = p_user_data;

    if (p_callback_data) |callback_data| {
        if (message_severity >= vulkan.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) {
            std.log.err("Validation Layer: {s}", .{callback_data.pMessage});
        } else if (message_severity >= vulkan.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) {
            std.log.warn("Validation Layer: {s}", .{callback_data.pMessage});
        } else {
            std.log.info("Validation Layer: {s}", .{callback_data.pMessage});
        }
    }

    return vulkan.VK_FALSE;
}

fn find_graphics_queue_family(
    allocator: std.mem.Allocator,
    physical_device: vulkan.VkPhysicalDevice,
    surface: vulkan.VkSurfaceKHR,
) !?u32 {
    var queue_family_count: u32 = 0;
    vulkan.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, null);

    const queue_families = try allocator.alloc(vulkan.VkQueueFamilyProperties, queue_family_count);
    defer allocator.free(queue_families);

    vulkan.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, queue_families.ptr);

    for (queue_families, 0..) |queue_family, index| {
        const i: u32 = @intCast(index);
        if ((queue_family.queueFlags & vulkan.VK_QUEUE_GRAPHICS_BIT) != 0) {
            var present_support: vulkan.VkBool32 = vulkan.VK_FALSE;
            try vulkan_check(
                vulkan.vkGetPhysicalDeviceSurfaceSupportKHR(physical_device, i, surface, &present_support),
                error.FailedToGetSurfaceSupport,
            );

            if (present_support == vulkan.VK_TRUE) {
                return i;
            }
        }
    }

    return null;
}

fn check_device_extension_support(
    allocator: std.mem.Allocator,
    physical_device: vulkan.VkPhysicalDevice,
) !bool {
    const available_extensions = try vulkan_enumerate(
        allocator,
        vulkan.VkExtensionProperties,
        vulkan.vkEnumerateDeviceExtensionProperties,
        .{ physical_device, null },
        error.FailedToEnumerateDeviceExtensions,
    );
    defer allocator.free(available_extensions);

    for (required_device_extensions) |required| {
        var found = false;
        for (available_extensions) |*available| {
            const len = std.mem.indexOfScalar(u8, &available.extensionName, 0) orelse available.extensionName.len;
            const available_name = available.extensionName[0..len];
            const required_name = std.mem.span(required);

            if (std.mem.eql(u8, available_name, required_name)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }

    return true;
}

fn check_swap_chain_support(
    allocator: std.mem.Allocator,
    physical_device: vulkan.VkPhysicalDevice,
    surface: vulkan.VkSurfaceKHR,
) !bool {
    const formats = try vulkan_enumerate(
        allocator,
        vulkan.VkSurfaceFormatKHR,
        vulkan.vkGetPhysicalDeviceSurfaceFormatsKHR,
        .{ physical_device, surface },
        error.FailedToGetSurfaceFormats,
    );
    defer allocator.free(formats);

    const present_modes = try vulkan_enumerate(
        allocator,
        vulkan.VkPresentModeKHR,
        vulkan.vkGetPhysicalDeviceSurfacePresentModesKHR,
        .{ physical_device, surface },
        error.FailedToGetPresentModes,
    );
    defer allocator.free(present_modes);

    return formats.len > 0 and present_modes.len > 0;
}

fn choose_swap_surface_format(available_formats: []const vulkan.VkSurfaceFormatKHR) vulkan.VkSurfaceFormatKHR {
    for (available_formats) |format| {
        if (format.format == vulkan.VK_FORMAT_B8G8R8A8_SRGB and
            format.colorSpace == vulkan.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
        {
            return format;
        }
    }
    return available_formats[0];
}

fn choose_swap_present_mode(available_present_modes: []const vulkan.VkPresentModeKHR) vulkan.VkPresentModeKHR {
    for (available_present_modes) |mode| {
        if (mode == vulkan.VK_PRESENT_MODE_MAILBOX_KHR) {
            return mode;
        }
    }
    return vulkan.VK_PRESENT_MODE_FIFO_KHR;
}

fn choose_swap_extent(window: ?*sdl.SDL_Window, capabilities: vulkan.VkSurfaceCapabilitiesKHR) vulkan.VkExtent2D {
    if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
        return capabilities.currentExtent;
    }

    var width: i32 = 0;
    var height: i32 = 0;
    _ = sdl.SDL_GetWindowSizeInPixels(window, &width, &height);

    return .{
        .width = std.math.clamp(@as(u32, @intCast(width)), capabilities.minImageExtent.width, capabilities.maxImageExtent.width),
        .height = std.math.clamp(@as(u32, @intCast(height)), capabilities.minImageExtent.height, capabilities.maxImageExtent.height),
    };
}

fn choose_swap_min_image_count(capabilities: vulkan.VkSurfaceCapabilitiesKHR) u32 {
    var count = capabilities.minImageCount + 1;
    if (capabilities.maxImageCount > 0 and count > capabilities.maxImageCount) {
        count = capabilities.maxImageCount;
    }
    return count;
}

const FPSCounter = struct {
    last_time_ns: u64,
    frame_count: u32,

    fn init() FPSCounter {
        return .{
            .last_time_ns = std.time.nanoTimestamp() > 0 and true match {
                else => @intCast(std.time.nanoTimestamp()),
            },
            .frame_count = 0,
        };
    }

    fn tick(self: *FPSCounter, window: ?*sdl.SDL_Window) void {
        self.frame_count += 1;
        const now_ns: u64 = @intCast(std.time.nanoTimestamp());
        const elapsed_ns = now_ns - self.last_time_ns;

        // Update title twice per second (every 500,000,000 ns)
        if (elapsed_ns >= 500_000_000) {
            const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
            const fps = @as(f64, @floatFromInt(self.frame_count)) / elapsed_s;
            const frame_time_ms = (elapsed_s / @as(f64, @floatFromInt(self.frame_count))) * 1000.0;

            var title_buffer: [128]u8 = undefined;
            const title = std.fmt.bufPrintZ(
                &title_buffer,
                "SDL3 + Vulkan | FPS: {d:.1} | Frame Time: {d:.2} ms",
                .{ fps, frame_time_ms },
            ) catch "SDL3 + Vulkan";

            _ = sdl.SDL_SetWindowTitle(window, title);

            self.last_time_ns = now_ns;
            self.frame_count = 0;
        }
    }
};
```

---

## Recap & What's Next

### What We Covered
1. Structured vertex memory layouts using native Zig structures (`Vertex`).
2. Expressed stride using `@sizeOf(Vertex)` and component offsets using `@offsetOf(Vertex, "field")`.
3. Created Vulkan descriptor structures (`VkVertexInputBindingDescription` and `VkVertexInputAttributeDescription`) and linked them into our pipeline state info (`VkPipelineVertexInputStateCreateInfo`).
4. Re-compiled Slang shader code to accept vertex inputs.

### What's Next
While our graphics pipeline is now configured to expect vertex data in this format, we are still relying on `vkCmdDraw(command_buffer, 3, 1, 0, 0)` without binding an actual memory buffer (`VkBuffer`) on the GPU!

In the next lesson, we will allocate dynamic **Vertex Buffers** in Vulkan memory using `vkCreateBuffer`, transfer CPU vertex memory into GPU memory using staging buffers, and bind them inside command buffer execution with `vkCmdBindVertexBuffers`.