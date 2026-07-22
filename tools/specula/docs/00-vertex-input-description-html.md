# Vertex Input Description

## Overview

In previous steps, our graphics pipeline relied on a vertex shader that
hardcoded geometric data inside the shader binary itself. While that approach
allowed us to set up initial Vulkan rendering infrastructure without worrying
about memory transfers, modern game engine development requires dynamically
passing vertex streams from host memory to GPU resources.

This lesson transitions our pipeline from hardcoded vertex constants to a
flexible, data-driven vertex layout. We will define a `Vertex` struct in
standard CPU memory and configure Vulkan's graphics pipeline state to interpret
these vertex structures. Specifically, we will construct:

1. **Vertex Binding Descriptions (`VkVertexInputBindingDescription`)**:
   Instructs Vulkan on how data is fed from memory buffers (the stride in bytes
   between consecutive elements and whether data is step-indexed per vertex or
   per instance).
2. **Vertex Attribute Descriptions (`VkVertexInputAttributeDescription`)**:
   Details the byte layout inside a single vertex structure, mapping struct
   fields to shader input locations, data formats, and memory offsets.

By completing this translation, our pipeline state will be configured to accept
vertex attributes directly, laying the foundation for allocating GPU vertex
buffers in subsequent engine iterations.

---

## Concepts & Explanations

### Connecting Vertex CPU Layouts to GPU Pipelines

In C++ graphics applications, libraries like GLM provide vector primitives
(`glm::vec2`, `glm::vec3`) to match shader data types. In Zig, we represent
vector attributes using extern structs containing fixed-size array floats
(`[2]f32`, `[3]f32`).

To tell Vulkan how to consume our custom CPU struct, we configure two distinct
Vulkan descriptor structures during pipeline creation:

#### 1. Vertex Input Binding Description (`VkVertexInputBindingDescription`)

Vulkan supports streaming vertex data from multiple memory buffers
simultaneously (e.g., streaming positions from one buffer and colors or UVs from
another). A binding description binds a single vertex buffer slot (index) to an
input stream:

- **`binding`**: The binding slot index in the command buffer (typically index
  `0`).
- **`stride`**: The total byte distance from one vertex record to the next
  (`@sizeOf(Vertex)`).
- **`inputRate`**: Specifies how Vulkan advances through the buffer. For
  standard geometry, this is `VK_VERTEX_INPUT_RATE_VERTEX`. For instanced
  rendering, this would be `VK_VERTEX_INPUT_RATE_INSTANCE`.

#### 2. Vertex Input Attribute Descriptions (`VkVertexInputAttributeDescription`)

While the binding description describes the container stride, attribute
descriptions map individual fields inside the struct to the shader input
attributes (`location = N` in Slang/HLSL/GLSL):

- **`location`**: The shader layout location index (`0` for position, `1` for
  color).
- **`binding`**: Which vertex buffer binding slot this attribute originates from
  (matches the binding index above).
- **`format`**: The format of the data. Notice that Vulkan uses image formats to
  describe vertex attribute numerical types!
  - `VK_FORMAT_R32G32_SFLOAT` maps to 2-component 32-bit floats (2D position,
    `[2]f32`).
  - `VK_FORMAT_R32G32B32_SFLOAT` maps to 3-component 32-bit floats (3D color,
    `[3]f32`).
- **`offset`**: The byte offset of the specific field from the start of the
  `Vertex` struct (`@offsetOf(Vertex, "pos")`).

### Shader Interface Alignment

In Slang (or HLSL/GLSL), inputs defined at the vertex shader entry point
correspond directly to our attribute descriptions:

```slang
struct VSInput {
    float2 inPosition; // location 0 -> VK_FORMAT_R32G32_SFLOAT
    float3 inColor;    // location 1 -> VK_FORMAT_R32G32B32_SFLOAT
};
```

If the locations, formats, or offsets declared in C/Zig fail to match the shader
signatures exactly, Vulkan's validation layers will flag layout mismatches, or
the GPU will misinterpret memory addresses during rasterization.

### Trade-offs and Edge Cases

- **Struct Layout & Padding**: In C++, `offsetof(Vertex, member)` calculates
  field offsets. In Zig, `@offsetOf(Vertex, "field")` accomplishes the same.
  Defining the vertex struct as `extern struct` guarantees predictable
  C-compatible ABI alignment and layout across compiler targets.
- **Format Component Names**: Vulkan format names describe vector channel counts
  using color channels (`R`, `G`, `B`, `A`), regardless of whether the attribute
  holds spatial coordinates, normals, or colors. For example,
  `VK_FORMAT_R32G32_SFLOAT` is used for 2D position vectors (`x`, `y`).

---

## Code Translation Sections

### 1. Vertex CPU Data Structure

We represent modern engine vertex data with an `extern struct`.

#### Source C++

```c++
struct Vertex
{
    glm::vec2 pos;
    glm::vec3 color;
};

const std::vector<Vertex> vertices = {
    {{0.0f, -0.5f}, {1.0f, 0.0f, 0.0f}},
    {{0.5f, 0.5f}, {0.0f, 1.0f, 0.0f}},
    {{-0.5f, 0.5f}, {0.0f, 0.0f, 1.0f}}
};
```

#### Translated Zig

```zig
pub const Vertex = extern struct {
    pos: [2]f32,
    color: [3]f32,

    pub fn get_binding_description() vulkan.VkVertexInputBindingDescription {
        return vulkan.VkVertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(Vertex),
            .inputRate = vulkan.VK_VERTEX_INPUT_RATE_VERTEX,
        };
    }

    pub fn get_attribute_descriptions() [2]vulkan.VkVertexInputAttributeDescription {
        return [_]vulkan.VkVertexInputAttributeDescription{
            vulkan.VkVertexInputAttributeDescription{
                .location = 0,
                .binding = 0,
                .format = vulkan.VK_FORMAT_R32G32_SFLOAT,
                .offset = @offsetOf(Vertex, "pos"),
            },
            vulkan.VkVertexInputAttributeDescription{
                .location = 1,
                .binding = 0,
                .format = vulkan.VK_FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex, "color"),
            },
        };
    }
};

const vertices = [_]Vertex{
    .{ .pos = .{ 0.0, -0.5 }, .color = .{ 1.0, 0.0, 0.0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0.0, 1.0, 0.0 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 0.0, 0.0, 1.0 } },
};
```

---

### 2. Pipeline Vertex Input State Integration

Next, we replace the empty vertex input state in
`initialize_vulkan_create_graphics_pipeline` with our newly defined binding and
attribute descriptions.

#### Source C++

```c++
auto bindingDescription = Vertex::getBindingDescription();
auto attributeDescriptions = Vertex::getAttributeDescriptions();

vk::PipelineVertexInputStateCreateInfo vertexInputInfo{
    .vertexBindingDescriptionCount = 1,
    .pVertexBindingDescriptions = &bindingDescription,
    .vertexAttributeDescriptionCount = static_cast<uint32_t>(attributeDescriptions.size()),
    .pVertexAttributeDescriptions = attributeDescriptions.data()
};
```

#### Translated Zig

```zig
const binding_description = Vertex.get_binding_description();
const attribute_descriptions = Vertex.get_attribute_descriptions();

const vertex_input_state = vulkan.VkPipelineVertexInputStateCreateInfo{
    .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    .vertexBindingDescriptionCount = 1,
    .pVertexBindingDescriptions = &binding_description,
    .vertexAttributeDescriptionCount = @intCast(attribute_descriptions.len),
    .pVertexAttributeDescriptions = &attribute_descriptions,
};
```

---

### 3. Integrated Source File (`src/main.zig`)

Here is the complete source file updated to configure pipeline vertex input
metadata.

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

pub const Vertex = extern struct {
    pos: [2]f32,
    color: [3]f32,

    pub fn get_binding_description() vulkan.VkVertexInputBindingDescription {
        return vulkan.VkVertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(Vertex),
            .inputRate = vulkan.VK_VERTEX_INPUT_RATE_VERTEX,
        };
    }

    pub fn get_attribute_descriptions() [2]vulkan.VkVertexInputAttributeDescription {
        return [_]vulkan.VkVertexInputAttributeDescription{
            vulkan.VkVertexInputAttributeDescription{
                .location = 0,
                .binding = 0,
                .format = vulkan.VK_FORMAT_R32G32_SFLOAT,
                .offset = @offsetOf(Vertex, "pos"),
            },
            vulkan.VkVertexInputAttributeDescription{
                .location = 1,
                .binding = 0,
                .format = vulkan.VK_FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex, "color"),
            },
        };
    }
};

const vertices = [_]Vertex{
    .{ .pos = .{ 0.0, -0.5 }, .color = .{ 1.0, 0.0, 0.0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0.0, 1.0, 0.0 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 0.0, 0.0, 1.0 } },
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
            vulkan.vkDestroyCommandPool(
                self.device,
                self.command_pool,
                null,
            );
            self.command_pool = null;
        }

        self.cleanup_destroy_graphics_pipeline();
        self.cleanup_destroy_pipeline_layout();
        self.destroyShaderModule();

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

        try vulkan_check(vulkan.vkCreateInstance(&create_information, null, &self.instance), error.InstanceCreationFailed);

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
            return error.DebugMessengerNotAvailable;
        };

        try vulkan_check(
            function(self.instance, &create_information, null, &self.debug_messenger),
            error.DebugMessengerCreationFailed,
        );

        std.log.debug("Debug messenger initialized successfully", .{});
    }

    fn destroy_debug_messenger(self: *Application) void {
        if (!enable_validation_layers or self.debug_messenger == null) return;

        const destroy_fn: vulkan.PFN_vkDestroyDebugUtilsMessengerEXT = @ptrCast(
            vulkan.vkGetInstanceProcAddr(self.instance, "vkDestroyDebugUtilsMessengerEXT"),
        );

        if (destroy_fn) |function| {
            function(self.instance, self.debug_messenger, null);
            self.debug_messenger = null;
            std.log.debug("Debug messenger destroyed", .{});
        }
    }

    // +-------------------+
    // |  Surface & Device |
    // +-------------------+

    fn initialize_vulkan_create_surface(self: *Application) !void {
        std.debug.assert(self.window != null);
        std.debug.assert(self.instance != null);
        std.debug.assert(self.surface == null);

        if (!sdl.SDL_Vulkan_CreateSurface(self.window, self.instance, null, &self.surface)) {
            std.log.err("Failed to create window surface: {s}", .{sdl.SDL_GetError()});
            return error.SurfaceCreationFailed;
        }

        std.log.debug("Window surface created successfully", .{});
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
            std.log.err("Failed to find GPUs with Vulkan support!", .{});
            return error.NoVulkanGPUsFound;
        }

        std.log.debug("Found {d} physical device(s)", .{physical_devices.len});

        for (physical_devices) |p_device| {
            if (try self.is_device_suitable(p_device)) {
                self.physical_device = p_device;
                break;
            }
        }

        if (self.physical_device == null) {
            std.log.err("Failed to find a suitable GPU!", .{});
            return error.NoSuitableGPUFound;
        }

        var properties: vulkan.VkPhysicalDeviceProperties = undefined;
        vulkan.vkGetPhysicalDeviceProperties(self.physical_device, &properties);
        const device_name = std.mem.sliceTo(&properties.deviceName, 0);

        std.log.info("Selected physical device: {s}", .{device_name});
    }

    fn is_device_suitable(self: *Application, p_device: vulkan.VkPhysicalDevice) !bool {
        const family_index = try find_graphics_queue_family(self, p_device);
        if (family_index == null) return false;

        const extensions_supported = try check_device_extension_support(self, p_device);
        if (!extensions_supported) return false;

        var swap_chain_adequate = false;
        if (extensions_supported) {
            const surface_formats = try vulkan_enumerate(
                self.allocator,
                vulkan.VkSurfaceFormatKHR,
                vulkan.vkGetPhysicalDeviceSurfaceFormatsKHR,
                .{ p_device, self.surface },
                error.SurfaceFormatsEnumerationFailed,
            );
            defer self.allocator.free(surface_formats);

            const present_modes = try vulkan_enumerate(
                self.allocator,
                vulkan.VkPresentModeKHR,
                vulkan.vkGetPhysicalDeviceSurfacePresentModesKHR,
                .{ p_device, self.surface },
                error.PresentModesEnumerationFailed,
            );
            defer self.allocator.free(present_modes);

            swap_chain_adequate = surface_formats.len > 0 and present_modes.len > 0;
        }

        return swap_chain_adequate;
    }

    fn initialize_vulkan_create_logical_device(self: *Application) !void {
        std.debug.assert(self.physical_device != null);
        std.debug.assert(self.device == null);

        const family_index = (try find_graphics_queue_family(self, self.physical_device)) orelse {
            return error.NoGraphicsQueueFamilyFound;
        };

        self.graphics_family = family_index;

        const queue_priority: f32 = 1.0;
        const queue_create_info = vulkan.VkDeviceQueueCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = family_index,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };

        const device_features = vulkan.VkPhysicalDeviceFeatures{};

        var create_info = vulkan.VkDeviceCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_create_info,
            .pEnabledFeatures = &device_features,
            .enabledExtensionCount = @intCast(required_device_extensions.len),
            .ppEnabledExtensionNames = &required_device_extensions,
        };

        if (enable_validation_layers) {
            create_info.enabledLayerCount = @intCast(validation_layers.len);
            create_info.ppEnabledLayerNames = &validation_layers;
        } else {
            create_info.enabledLayerCount = 0;
        }

        try vulkan_check(
            vulkan.vkCreateDevice(self.physical_device, &create_info, null, &self.device),
            error.DeviceCreationFailed,
        );

        vulkan.vkGetDeviceQueue(self.device, self.graphics_family, 0, &self.graphics_queue);

        std.log.debug("Logical device and graphics queue created", .{});
    }

    // +------------------+
    // | Swapchain Setup  |
    // +------------------+

    fn create_swap_chain(self: *Application) !void {
        var capabilities: vulkan.VkSurfaceCapabilitiesKHR = undefined;
        try vulkan_check(
            vulkan.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface, &capabilities),
            error.SurfaceCapabilitiesFailed,
        );

        const surface_formats = try vulkan_enumerate(
            self.allocator,
            vulkan.VkSurfaceFormatKHR,
            vulkan.vkGetPhysicalDeviceSurfaceFormatsKHR,
            .{ self.physical_device, self.surface },
            error.SurfaceFormatsEnumerationFailed,
        );
        defer self.allocator.free(surface_formats);

        const present_modes = try vulkan_enumerate(
            self.allocator,
            vulkan.VkPresentModeKHR,
            vulkan.vkGetPhysicalDeviceSurfacePresentModesKHR,
            .{ self.physical_device, self.surface },
            error.PresentModesEnumerationFailed,
        );
        defer self.allocator.free(present_modes);

        const surface_format = choose_swap_surface_format(surface_formats);
        const present_mode = choose_swap_present_mode(present_modes);
        const extent = self.choose_swap_extent(capabilities);

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
        create_info.imageSharingMode = vulkan.VK_SHARING_MODE_EXCLUSIVE;
        create_info.queueFamilyIndexCount = 1;
        create_info.pQueueFamilyIndices = &queue_family_indices;

        try vulkan_check(
            vulkan.vkCreateSwapchainKHR(self.device, &create_info, null, &self.swap_chain),
            error.SwapChainCreationFailed,
        );

        var actual_image_count: u32 = 0;
        try vulkan_check(
            vulkan.vkGetSwapchainImagesKHR(self.device, self.swap_chain, &actual_image_count, null),
            error.SwapchainImagesEnumerationFailed,
        );
        std.debug.assert(actual_image_count <= swap_chain_images_max);

        try vulkan_check(
            vulkan.vkGetSwapchainImagesKHR(self.device, self.swap_chain, &actual_image_count, &self.swap_chain_images),
            error.SwapchainImagesEnumerationFailed,
        );

        self.swap_chain_images_count = actual_image_count;
        self.swap_chain_surface_format = surface_format;
        self.swap_chain_extent = extent;

        std.log.info("Swapchain created successfully ({d} images, {d}x{d})", .{
            actual_image_count,
            extent.width,
            extent.height,
        });
    }

    fn choose_swap_extent(self: *Application, capabilities: vulkan.VkSurfaceCapabilitiesKHR) vulkan.VkExtent2D {
        if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
            return capabilities.currentExtent;
        } else {
            var width: i32 = 0;
            var height: i32 = 0;
            _ = sdl.SDL_GetWindowSizeInPixels(self.window, &width, &height);

            var actual_extent = vulkan.VkExtent2D{
                .width = @intCast(width),
                .height = @intCast(height),
            };

            actual_extent.width = std.math.clamp(
                actual_extent.width,
                capabilities.minImageExtent.width,
                capabilities.maxImageExtent.width,
            );
            actual_extent.height = std.math.clamp(
                actual_extent.height,
                capabilities.minImageExtent.height,
                capabilities.maxImageExtent.height,
            );

            return actual_extent;
        }
    }

    fn create_image_views(self: *Application) !void {
        std.debug.assert(self.swap_chain_images_count > 0);

        for (0..self.swap_chain_images_count) |i| {
            const create_info = vulkan.VkImageViewCreateInfo{
                .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = self.swap_chain_images[i],
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
                vulkan.vkCreateImageView(self.device, &create_info, null, &self.swap_chain_image_views[i]),
                error.ImageViewCreationFailed,
            );
        }

        std.log.debug("Created {d} image views", .{self.swap_chain_images_count});
    }

    fn cleanup_swap_chain(self: *Application) void {
        std.log.debug("Cleaning up swapchain resources...", .{});

        for (0..self.swap_chain_images_count) |i| {
            if (self.swap_chain_image_views[i] != null) {
                vulkan.vkDestroyImageView(self.device, self.swap_chain_image_views[i], null);
                self.swap_chain_image_views[i] = null;
            }
        }

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

    // +--------------------+
    // | Shader & Pipeline  |
    // +--------------------+

    fn initialize_vulkan_create_graphics_pipeline_create_shader_modules(self: *Application) !void {
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

        std.log.debug("Shader module successfully created", .{});
    }

    fn destroyShaderModule(self: *Application) void {
        if (self.shader_module != null) {
            std.log.debug("Destroying shader module", .{});
            vulkan.vkDestroyShaderModule(self.device, self.shader_module, null);
            self.shader_module = null;
        }
    }

    fn initialize_vulkan_create_pipeline_layout(self: *Application) !void {
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

        std.log.debug("Pipeline layout created successfully", .{});
    }

    fn cleanup_destroy_pipeline_layout(self: *Application) void {
        if (self.pipeline_layout != null) {
            std.log.debug("Destroying pipeline layout", .{});
            vulkan.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
            self.pipeline_layout = null;
        }
    }

    fn initialize_vulkan_create_graphics_pipeline(self: *Application) !void {
        std.debug.assert(self.shader_module != null);
        std.debug.assert(self.pipeline_layout != null);
        std.debug.assert(self.graphics_pipeline == null);

        const vert_stage_info = vulkan.VkPipelineShaderStageCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vulkan.VK_SHADER_STAGE_VERTEX_BIT,
            .module = self.shader_module,
            .pName = "vertMain",
        };

        const frag_stage_info = vulkan.VkPipelineShaderStageCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vulkan.VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = self.shader_module,
            .pName = "fragMain",
        };

        const shader_stages = [_]vulkan.VkPipelineShaderStageCreateInfo{
            vert_stage_info,
            frag_stage_info,
        };

        const binding_description = Vertex.get_binding_description();
        const attribute_descriptions = Vertex.get_attribute_descriptions();

        const vertex_input_info = vulkan.VkPipelineVertexInputStateCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .vertexBindingDescriptionCount = 1,
            .pVertexBindingDescriptions = &binding_description,
            .vertexAttributeDescriptionCount = @intCast(attribute_descriptions.len),
            .pVertexAttributeDescriptions = &attribute_descriptions,
        };

        const input_assembly = vulkan.VkPipelineInputAssemblyStateCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .topology = vulkan.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = vulkan.VK_FALSE,
        };

        const dynamic_states = [_]vulkan.VkDynamicState{
            vulkan.VK_DYNAMIC_STATE_VIEWPORT,
            vulkan.VK_DYNAMIC_STATE_SCISSOR,
        };

        const dynamic_state_info = vulkan.VkPipelineDynamicStateCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = @intCast(dynamic_states.len),
            .pDynamicStates = &dynamic_states,
        };

        const viewport_state = vulkan.VkPipelineViewportStateCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1,
            .scissorCount = 1,
        };

        const rasterizer = vulkan.VkPipelineRasterizationStateCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .depthClampEnable = vulkan.VK_FALSE,
            .rasterizerDiscardEnable = vulkan.VK_FALSE,
            .polygonMode = vulkan.VK_POLYGON_MODE_FILL,
            .lineWidth = 1.0,
            .cullMode = vulkan.VK_CULL_MODE_BACK_BIT,
            .frontFace = vulkan.VK_FRONT_FACE_CLOCKWISE,
            .depthBiasEnable = vulkan.VK_FALSE,
        };

        const multisampling = vulkan.VkPipelineMultisampleStateCreateInfo{
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

        const color_blending = vulkan.VkPipelineColorBlendStateCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .logicOpEnable = vulkan.VK_FALSE,
            .logicOp = vulkan.VK_LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment,
            .blendConstants = [_]f32{ 0.0, 0.0, 0.0, 0.0 },
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
            .stageCount = 2,
            .pStages = &shader_stages,
            .pVertexInputState = &vertex_input_info,
            .pInputAssemblyState = &input_assembly,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pDepthStencilState = null,
            .pColorBlendState = &color_blending,
            .pDynamicState = &dynamic_state_info,
            .layout = self.pipeline_layout,
            .renderPass = null,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
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

        std.log.info("Graphics pipeline successfully created", .{});
    }

    fn cleanup_destroy_graphics_pipeline(self: *Application) void {
        if (self.graphics_pipeline != null) {
            std.log.debug("Destroying graphics pipeline", .{});
            vulkan.vkDestroyPipeline(self.device, self.graphics_pipeline, null);
            self.graphics_pipeline = null;
        }
    }

    // +--------------------+
    // |  Command Recording |
    // +--------------------+

    fn initialize_vulkan_create_command_pool(self: *Application) !void {
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

        std.log.debug("Command pool created successfully", .{});
    }

    fn initialize_vulkan_create_command_buffers(self: *Application) !void {
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

        std.log.debug("Allocated {d} command buffers", .{frames_in_flight_max});
    }

    fn cleanup_destroy_command_buffers(self: *Application) void {
        if (self.command_pool != null and self.device != null) {
            std.log.debug("Freeing command buffers", .{});
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
            error.CommandBufferBeginFailed,
        );

        const image_barrier = vulkan.VkImageMemoryBarrier2{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .srcStageMask = vulkan.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstStageMask = vulkan.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstAccessMask = vulkan.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .oldLayout = vulkan.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .srcQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
            .image = self.swap_chain_images[image_index],
            .subresourceRange = .{
                .aspectMask = vulkan.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        const dependency_info = vulkan.VkDependencyInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .imageMemoryBarrierCount = 1,
            .pImageMemoryBarriers = &image_barrier,
        };

        vulkan.vkCmdPipelineBarrier2(command_buffer, &dependency_info);

        const clear_value = vulkan.VkClearValue{
            .color = .{ .float32 = [_]f32{ 0.0, 0.0, 0.0, 1.0 } },
        };

        const color_attachment = vulkan.VkRenderingAttachmentInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = self.swap_chain_image_views[image_index],
            .imageLayout = vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .loadOp = vulkan.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vulkan.VK_ATTACHMENT_STORE_OP_STORE,
            .clearValue = clear_value,
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

        vulkan.vkCmdBindPipeline(
            command_buffer,
            vulkan.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.graphics_pipeline,
        );

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

        const present_barrier = vulkan.VkImageMemoryBarrier2{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .srcStageMask = vulkan.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = vulkan.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .dstStageMask = vulkan.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT,
            .dstAccessMask = 0,
            .oldLayout = vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .newLayout = vulkan.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            .srcQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
            .image = self.swap_chain_images[image_index],
            .subresourceRange = .{
                .aspectMask = vulkan.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        const present_dependency_info = vulkan.VkDependencyInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .imageMemoryBarrierCount = 1,
            .pImageMemoryBarriers = &present_barrier,
        };

        vulkan.vkCmdPipelineBarrier2(command_buffer, &present_dependency_info);

        try vulkan_check(
            vulkan.vkEndCommandBuffer(command_buffer),
            error.CommandBufferEndFailed,
        );
    }

    // +--------------------+
    // | Synchronization    |
    // +--------------------+

    fn initialize_vulkan_create_synchronization_objects(self: *Application) !void {
        const semaphore_info = vulkan.VkSemaphoreCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        };

        const fence_info = vulkan.VkFenceCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = vulkan.VK_FENCE_CREATE_SIGNALED_BIT,
        };

        for (0..frames_in_flight_max) |i| {
            try vulkan_check(
                vulkan.vkCreateSemaphore(self.device, &semaphore_info, null, &self.present_complete_semaphores[i]),
                error.SemaphoreCreationFailed,
            );
            try vulkan_check(
                vulkan.vkCreateFence(self.device, &fence_info, null, &self.in_flight_fences[i]),
                error.FenceCreationFailed,
            );
        }

        for (0..swap_chain_images_max) |i| {
            try vulkan_check(
                vulkan.vkCreateSemaphore(self.device, &semaphore_info, null, &self.render_finished_semaphores[i]),
                error.SemaphoreCreationFailed,
            );
        }

        std.log.debug("Created synchronization primitives", .{});
    }

    fn cleanup_destroy_synchronization_objects(self: *Application) void {
        std.log.debug("Destroying synchronization objects...", .{});

        for (0..frames_in_flight_max) |i| {
            if (self.present_complete_semaphores[i] != null) {
                vulkan.vkDestroySemaphore(self.device, self.present_complete_semaphores[i], null);
                self.present_complete_semaphores[i] = null;
            }
            if (self.in_flight_fences[i] != null) {
                vulkan.vkDestroyFence(self.device, self.in_flight_fences[i], null);
                self.in_flight_fences[i] = null;
            }
        }

        for (0..swap_chain_images_max) |i| {
            if (self.render_finished_semaphores[i] != null) {
                vulkan.vkDestroySemaphore(self.device, self.render_finished_semaphores[i], null);
                self.render_finished_semaphores[i] = null;
            }
        }
    }

    // +--------------------+
    // | Main Render Loop   |
    // +--------------------+

    fn draw_frame(self: *Application) !void {
        _ = try vulkan.vkWaitForFences(
            self.device,
            1,
            &self.in_flight_fences[self.frame_index],
            vulkan.VK_TRUE,
            std.math.maxInt(u64),
        );

        var image_index: u32 = 0;
        const acquire_result = vulkan.vkAcquireNextImageKHR(
            self.device,
            self.swap_chain,
            std.math.maxInt(u64),
            self.present_complete_semaphores[self.frame_index],
            null,
            &image_index,
        );

        if (acquire_result == vulkan.VK_ERROR_OUT_OF_DATE_KHR) {
            try self.recreate_swap_chain();
            return;
        } else if (acquire_result != vulkan.VK_SUCCESS and acquire_result != vulkan.VK_SUBOPTIMAL_KHR) {
            return error.ImageAcquisitionFailed;
        }

        try vulkan_check(
            vulkan.vkResetFences(self.device, 1, &self.in_flight_fences[self.frame_index]),
            error.FenceResetFailed,
        );

        const current_cmd_buffer = self.command_buffers[self.frame_index];
        try vulkan_check(
            vulkan.vkResetCommandBuffer(current_cmd_buffer, 0),
            error.CommandBufferResetFailed,
        );

        try self.record_command_buffer(current_cmd_buffer, image_index);

        const wait_semaphores = [_]vulkan.VkSemaphore{self.present_complete_semaphores[self.frame_index]};
        const wait_stages = [_]vulkan.VkPipelineStageFlags{vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const signal_semaphores = [_]vulkan.VkSemaphore{self.render_finished_semaphores[image_index]};

        const submit_info = vulkan.VkSubmitInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &wait_semaphores,
            .pWaitDstStageMask = &wait_stages,
            .commandBufferCount = 1,
            .pCommandBuffers = &current_cmd_buffer,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &signal_semaphores,
        };

        try vulkan_check(
            vulkan.vkQueueSubmit(self.graphics_queue, 1, &submit_info, self.in_flight_fences[self.frame_index]),
            error.QueueSubmitFailed,
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

        const present_result = vulkan.vkQueuePresentKHR(self.graphics_queue, &present_info);

        if (present_result == vulkan.VK_ERROR_OUT_OF_DATE_KHR or present_result == vulkan.VK_SUBOPTIMAL_KHR or self.framebuffer_resized) {
            self.framebuffer_resized = false;
            try self.recreate_swap_chain();
        } else if (present_result != vulkan.VK_SUCCESS) {
            return error.QueuePresentFailed;
        }

        self.frame_index = (self.frame_index + 1) % frames_in_flight_max;
    }
};

// +--------------------+
// | Vulkan Helpers     |
// +--------------------+

fn vulkan_check(result: vulkan.VkResult, err: anytype) !void {
    if (result != vulkan.VK_SUCCESS) {
        std.log.err("Vulkan operation failed with error code {d}", .{result});
        return err;
    }
}

fn vulkan_enumerate(
    allocator: std.mem.Allocator,
    comptime T: type,
    comptime enumerate_fn: anytype,
    args: anytype,
    err: anytype,
) ![]T {
    var count: u32 = 0;

    const count_args = args ++ .{ &count, null };
    try vulkan_check(@call(.auto, enumerate_fn, count_args), err);

    if (count == 0) return &[_]T{};

    const items = try allocator.alloc(T, count);
    errdefer allocator.free(items);

    const fill_args = args ++ .{ &count, items.ptr };
    try vulkan_check(@call(.auto, enumerate_fn, fill_args), err);

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
        const message = std.mem.span(callback_data.pMessage);
        if (message_severity >= vulkan.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) {
            std.log.err("Vulkan Validation Error: {s}", .{message});
        } else if (message_severity >= vulkan.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) {
            std.log.warn("Vulkan Validation Warning: {s}", .{message});
        } else {
            std.log.debug("Vulkan Validation Info: {s}", .{message});
        }
    }

    return vulkan.VK_FALSE;
}

fn find_graphics_queue_family(
    app: *Application,
    p_device: vulkan.VkPhysicalDevice,
) !?u32 {
    const queue_families = try vulkan_enumerate(
        app.allocator,
        vulkan.VkQueueFamilyProperties,
        vulkan.vkGetPhysicalDeviceQueueFamilyProperties,
        .{p_device},
        error.QueueFamilyPropertiesEnumerationFailed,
    );
    defer app.allocator.free(queue_families);

    for (queue_families, 0..) |family, i| {
        const family_index: u32 = @intCast(i);

        const graphics_support = (family.queueFlags & vulkan.VK_QUEUE_GRAPHICS_BIT) != 0;

        var present_support: vulkan.VkBool32 = vulkan.VK_FALSE;
        try vulkan_check(
            vulkan.vkGetPhysicalDeviceSurfaceSupportKHR(p_device, family_index, app.surface, &present_support),
            error.SurfaceSupportCheckFailed,
        );

        if (graphics_support and present_support == vulkan.VK_TRUE) {
            return family_index;
        }
    }

    return null;
}

fn check_device_extension_support(
    app: *Application,
    p_device: vulkan.VkPhysicalDevice,
) !bool {
    const available_extensions = try vulkan_enumerate(
        app.allocator,
        vulkan.VkExtensionProperties,
        vulkan.vkEnumerateDeviceExtensionProperties,
        .{ p_device, null },
        error.DeviceExtensionsEnumerationFailed,
    );
    defer app.allocator.free(available_extensions);

    for (required_device_extensions) |required_ext| {
        var ext_found = false;

        for (available_extensions) |*available_ext| {
            const len = std.mem.indexOfScalar(u8, &available_ext.extensionName, 0) orelse available_ext.extensionName.len;
            const available_name = available_ext.extensionName[0..len];
            const requested_name = std.mem.span(required_ext);

            if (std.mem.eql(u8, available_name, requested_name)) {
                ext_found = true;
                break;
            }
        }

        if (!ext_found) return false;
    }

    return true;
}

fn choose_swap_surface_format(formats: []const vulkan.VkSurfaceFormatKHR) vulkan.VkSurfaceFormatKHR {
    for (formats) |format| {
        if (format.format == vulkan.VK_FORMAT_B8G8R8A8_SRGB and
            format.colorSpace == vulkan.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
        {
            return format;
        }
    }
    return formats[0];
}

fn choose_swap_present_mode(modes: []const vulkan.VkPresentModeKHR) vulkan.VkPresentModeKHR {
    for (modes) |mode| {
        if (mode == vulkan.VK_PRESENT_MODE_MAILBOX_KHR) {
            return mode;
        }
    }
    return vulkan.VK_PRESENT_MODE_FIFO_KHR;
}

fn choose_swap_min_image_count(capabilities: vulkan.VkSurfaceCapabilitiesKHR) u32 {
    var count = capabilities.minImageCount + 1;
    if (capabilities.maxImageCount > 0 and count > capabilities.maxImageCount) {
        count = capabilities.maxImageCount;
    }
    return count;
}

const FPSCounter = struct {
    timer: std.time.Timer,
    frame_count: u32 = 0,

    pub fn init() FPSCounter {
        return .{
            .timer = std.time.Timer.start() catch unreachable,
        };
    }

    pub fn tick(self: *FPSCounter, window: ?*sdl.SDL_Window) void {
        self.frame_count += 1;
        const elapsed = self.timer.read();
        if (elapsed >= std.time.ns_per_s) {
            const fps = @as(f64, @floatFromInt(self.frame_count)) / (@as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
            const ms = 1000.0 / fps;

            var title_buf: [128]u8 = undefined;
            const title = std.fmt.bufPrintZ(&title_buf, "SDL3 + Vulkan - FPS: {d:.1} ({d:.2} ms)", .{ fps, ms }) catch "SDL3 + Vulkan";
            _ = sdl.SDL_SetWindowTitle(window, title);

            self.frame_count = 0;
            self.timer.reset();
        }
    }
};
```

---

## Recap & What's Next

In this lesson, we established the CPU-to-GPU data formatting interface:

- **Defined a standard `Vertex` layout** using a Zig `extern struct` containing
  2D position and 3D color channels.
- **Constructed binding descriptions (`VkVertexInputBindingDescription`)** to
  inform Vulkan how many bytes step between elements in memory.
- **Constructed attribute descriptions (`VkVertexInputAttributeDescription`)**
  using `@offsetOf` to map shader locations directly to structure offsets.
- **Reconfigured the graphics pipeline state** to accept input data based on
  these descriptions.

**Next Steps**: Currently, our vertex layout is configured in the pipeline, but
no vertex buffers exist in GPU memory yet. In the next tutorial step, we will
create dedicated GPU memory resources (`VkBuffer` and `VkDeviceMemory`),
allocate host-visible memory, copy our CPU `vertices` array into GPU memory, and
execute `vkCmdBindVertexBuffers` during rendering.
