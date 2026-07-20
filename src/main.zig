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
    swap_chain_images: []vulkan.VkImage = &.{},
    swap_chain_surface_format: vulkan.VkSurfaceFormatKHR = undefined,
    swap_chain_extent: vulkan.VkExtent2D = undefined,
    swap_chain_image_views: []vulkan.VkImageView = &.{},
    framebuffer_resized: bool = false,
    shader_module: vulkan.VkShaderModule = null,
    pipeline_layout: vulkan.VkPipelineLayout = null,
    graphics_pipeline: vulkan.VkPipeline = null,
    command_pool: vulkan.VkCommandPool = null,
    command_buffers: []vulkan.VkCommandBuffer = &.{},
    present_complete_semaphores: []vulkan.VkSemaphore = &.{},
    render_finished_semaphores: []vulkan.VkSemaphore = &.{},
    in_flight_fences: []vulkan.VkFence = &.{},
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
        std.debug.assert(self.swap_chain_image_views.len > 0);

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
            // Wait for the GPU to completely finish all execution before starting cleanup.
            // This is required to prevent destroying active queues or buffers currently in use.
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
        const available_layers = try vulkan_enumerate(
            self.allocator,
            vulkan.VkLayerProperties,
            vulkan.vkEnumerateInstanceLayerProperties,
            .{},
            error.EnumerationFailed,
        );
        defer self.allocator.free(available_layers);

        for (validation_layers) |layer_name| {
            const required_name = std.mem.sliceTo(layer_name, 0);
            const found = for (available_layers) |layer_properties| {
                const name = std.mem.sliceTo(&layer_properties.layerName, 0);
                if (std.mem.eql(u8, name, required_name)) break true;
            } else false;

            if (!found) return false;
        }

        return true;
    }

    fn check_extension_support(self: *Application, required_extensions: []const [*c]const u8) !void {
        const available_extensions = try vulkan_enumerate(
            self.allocator,
            vulkan.VkExtensionProperties,
            vulkan.vkEnumerateInstanceExtensionProperties,
            .{null},
            error.EnumerationFailed,
        );
        defer self.allocator.free(available_extensions);

        std.log.debug("Available extensions:", .{});
        for (available_extensions) |extension| {
            std.log.debug("\t{s}", .{std.mem.sliceTo(&extension.extensionName, 0)});
        }

        for (required_extensions) |required_extension| {
            const required_name = std.mem.sliceTo(required_extension, 0);

            const found = for (available_extensions) |extension| {
                const name = std.mem.sliceTo(&extension.extensionName, 0);
                if (std.mem.eql(u8, name, required_name)) break true;
            } else false;

            if (!found) {
                std.log.err("Required extension not supported: {s}", .{required_name});
                return error.RequiredExtensionNotSupported;
            }
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
        if (!enable_validation_layers) return;

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
            return error.ExtensionNotPresent;
        };

        try vulkan_check(
            function(self.instance, &create_information, null, &self.debug_messenger),
            error.DebugMessengerCreationFailed,
        );

        std.log.debug("Debug messenger set up", .{});
    }

    fn destroy_debug_messenger(self: *Application) void {
        if (self.debug_messenger == null) return;

        const destroy_fn: vulkan.PFN_vkDestroyDebugUtilsMessengerEXT = @ptrCast(
            vulkan.vkGetInstanceProcAddr(self.instance, "vkDestroyDebugUtilsMessengerEXT"),
        );

        if (destroy_fn) |function| {
            function(self.instance, self.debug_messenger, null);
        }
    }

    // +------------------+
    // |  Window Surface  |
    // +------------------+

    fn initialize_vulkan_create_surface(self: *Application) !void {
        std.debug.assert(self.instance != null);
        std.debug.assert(self.window != null);
        std.debug.assert(self.surface == null);
        if (!sdl.SDL_Vulkan_CreateSurface(
            self.window,
            @ptrCast(self.instance),
            null,
            @ptrCast(&self.surface),
        )) {
            std.log.err("Failed to create window surface: {s}", .{sdl.SDL_GetError()});
            return error.SurfaceCreationFailed;
        }

        std.log.info("Window surface created", .{});
    }

    // +-----------------------------+
    // |  Physical Device Selection  |
    // +-----------------------------+

    fn initialize_vulkan_pick_physical_device(self: *Application) !void {
        std.debug.assert(self.instance != null);
        std.debug.assert(self.physical_device == null);
        const physical_devices = try vulkan_enumerate(
            self.allocator,
            vulkan.VkPhysicalDevice,
            vulkan.vkEnumeratePhysicalDevices,
            .{self.instance},
            error.EnumerationFailed,
        );
        defer self.allocator.free(physical_devices);

        if (physical_devices.len == 0) {
            return error.NoGpuWithVulkanSupport;
        }

        std.log.debug("Found {d} Vulkan-capable GPU(s)", .{physical_devices.len});

        for (physical_devices) |candidate| {
            if (try self.is_device_suitable(candidate)) {
                self.physical_device = candidate;
                break;
            }
        }

        if (self.physical_device == null) return error.NoSuitableGpu;

        var properties: vulkan.VkPhysicalDeviceProperties = undefined;
        vulkan.vkGetPhysicalDeviceProperties(self.physical_device, &properties);
        std.log.info("selected physical device: {s}", .{std.mem.sliceTo(&properties.deviceName, 0)});
    }

    fn is_device_suitable(self: *Application, physical_device: vulkan.VkPhysicalDevice) !bool {
        std.debug.assert(physical_device != null);
        var properties: vulkan.VkPhysicalDeviceProperties = undefined;
        vulkan.vkGetPhysicalDeviceProperties(physical_device, &properties);
        var features: vulkan.VkPhysicalDeviceFeatures = undefined;
        vulkan.vkGetPhysicalDeviceFeatures(physical_device, &features);

        const device_name = std.mem.sliceTo(&properties.deviceName, 0);

        const supports_vulkan_1_3 = properties.apiVersion >= vulkan.VK_API_VERSION_1_3;

        const families = try vulkan_enumerate(
            self.allocator,
            vulkan.VkQueueFamilyProperties,
            vulkan.vkGetPhysicalDeviceQueueFamilyProperties,
            .{physical_device},
            error.EnumerationFailed,
        );
        defer self.allocator.free(families);

        const supports_graphics = for (families) |family| {
            if ((family.queueFlags & vulkan.VK_QUEUE_GRAPHICS_BIT) != 0) break true;
        } else false;

        const supports_all_extensions = try self.check_device_extension_support(physical_device);

        const supports_required_features = check_required_features(physical_device);

        // Const is_discrete_gpu = properties.deviceType == vulkan.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU;.
        const has_geometry_shader = features.geometryShader == vulkan.VK_TRUE;

        const suitable = supports_vulkan_1_3 and
            supports_graphics and
            supports_all_extensions and
            supports_required_features and
            // Is_discrete_gpu and.
            has_geometry_shader;

        if (!suitable) {
            std.log.debug("Rejected '{s}': api_1_3={}, graphics={}, extensions={}, features={}, geometry={}", .{ device_name, supports_vulkan_1_3, supports_graphics, supports_all_extensions, supports_required_features, has_geometry_shader });
        }

        return suitable;
    }

    fn check_device_extension_support(self: *Application, physical_device: vulkan.VkPhysicalDevice) !bool {
        std.debug.assert(physical_device != null);
        const available = try vulkan_enumerate(
            self.allocator,
            vulkan.VkExtensionProperties,
            vulkan.vkEnumerateDeviceExtensionProperties,
            .{ physical_device, null },
            error.EnumerationFailed,
        );
        defer self.allocator.free(available);

        for (required_device_extensions) |required| {
            const required_name = std.mem.sliceTo(required, 0);

            const found = for (available) |extension| {
                const available_name = std.mem.sliceTo(&extension.extensionName, 0);
                if (std.mem.eql(u8, available_name, required_name)) break true;
            } else false;

            if (!found) return false;
        }

        return true;
    }

    // +----------------------------+
    // |  Logical Device Selection  |
    // +----------------------------+

    fn initialize_vulkan_create_logical_device_features(
        extended_dynamic_state_features: *vulkan.VkPhysicalDeviceExtendedDynamicStateFeaturesEXT,
        vulkan_1_3_features: *vulkan.VkPhysicalDeviceVulkan13Features,
        vulkan_1_1_features: *vulkan.VkPhysicalDeviceVulkan11Features,
    ) vulkan.VkPhysicalDeviceFeatures2 {
        extended_dynamic_state_features.* = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_FEATURES_EXT,
            .pNext = null,
            .extendedDynamicState = vulkan.VK_TRUE,
        };
        vulkan_1_3_features.* = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
            .pNext = extended_dynamic_state_features,
            .dynamicRendering = vulkan.VK_TRUE,
            .synchronization2 = vulkan.VK_TRUE,
        };
        vulkan_1_1_features.* = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
            .pNext = vulkan_1_3_features,
            .shaderDrawParameters = vulkan.VK_TRUE,
        };
        return .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
            .pNext = vulkan_1_1_features,
            .features = std.mem.zeroes(vulkan.VkPhysicalDeviceFeatures),
        };
    }

    fn initialize_vulkan_create_logical_device_find_queue_family(
        self: *Application,
        families: []const vulkan.VkQueueFamilyProperties,
    ) !u32 {
        return for (families, 0..) |family, i| {
            if ((family.queueFlags & vulkan.VK_QUEUE_GRAPHICS_BIT) == 0) continue;

            var supports_present: vulkan.VkBool32 = vulkan.VK_FALSE;
            try vulkan_check(
                vulkan.vkGetPhysicalDeviceSurfaceSupportKHR(
                    self.physical_device,
                    @intCast(i),
                    self.surface,
                    &supports_present,
                ),
                error.SurfaceSupportQueryFailed,
            );

            if (supports_present == vulkan.VK_TRUE) break @intCast(i);
        } else error.NoGraphicsPresentQueueFamily;
    }

    fn initialize_vulkan_create_logical_device(self: *Application) !void {
        std.debug.assert(self.physical_device != null);
        std.debug.assert(self.device == null);
        const families = try vulkan_enumerate(
            self.allocator,
            vulkan.VkQueueFamilyProperties,
            vulkan.vkGetPhysicalDeviceQueueFamilyProperties,
            .{self.physical_device},
            error.EnumerationFailed,
        );
        defer self.allocator.free(families);
        std.log.debug("Device has {d} queue family(ies)", .{families.len});

        self.graphics_family = try self.initialize_vulkan_create_logical_device_find_queue_family(families);
        std.log.debug("Graphics queue family index: {d}", .{self.graphics_family});

        const queue_priorities = [_]f32{0.5};
        const device_queue_create_information = vulkan.VkDeviceQueueCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = self.graphics_family,
            .queueCount = 1,
            .pQueuePriorities = &queue_priorities,
        };

        var extended_dynamic_state_features: vulkan.VkPhysicalDeviceExtendedDynamicStateFeaturesEXT = undefined;
        var vulkan_1_3_features: vulkan.VkPhysicalDeviceVulkan13Features = undefined;
        var vulkan_1_1_features: vulkan.VkPhysicalDeviceVulkan11Features = undefined;
        var features2 = initialize_vulkan_create_logical_device_features(
            &extended_dynamic_state_features,
            &vulkan_1_3_features,
            &vulkan_1_1_features,
        );

        const device_create_information = vulkan.VkDeviceCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = @ptrCast(&features2),
            .flags = 0,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &[_]vulkan.VkDeviceQueueCreateInfo{device_queue_create_information},
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = @intCast(required_device_extensions.len),
            .ppEnabledExtensionNames = &required_device_extensions,
            .pEnabledFeatures = null,
        };

        try vulkan_check(
            vulkan.vkCreateDevice(self.physical_device, &device_create_information, null, &self.device),
            error.DeviceCreationFailed,
        );

        vulkan.vkGetDeviceQueue(self.device, self.graphics_family, 0, &self.graphics_queue);
        std.log.info("Logical device created successfully", .{});
    }

    fn query_surface_capabilities(self: *Application) !vulkan.VkSurfaceCapabilitiesKHR {
        var capabilities: vulkan.VkSurfaceCapabilitiesKHR = undefined;

        try vulkan_check(
            vulkan.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
                self.physical_device,
                self.surface,
                &capabilities,
            ),
            error.FailedToQuerySurfaceCapabilities,
        );

        return capabilities;
    }

    fn query_surface_formats(self: *Application) ![]vulkan.VkSurfaceFormatKHR {
        const formats = try vulkan_enumerate(
            self.allocator,
            vulkan.VkSurfaceFormatKHR,
            vulkan.vkGetPhysicalDeviceSurfaceFormatsKHR,
            .{ self.physical_device, self.surface },
            error.FailedToQuerySurfaceFormats,
        );
        errdefer self.allocator.free(formats);

        if (formats.len == 0) {
            return error.NoSurfaceFormats;
        }

        return formats;
    }

    fn query_present_modes(self: *Application) ![]vulkan.VkPresentModeKHR {
        const modes = try vulkan_enumerate(
            self.allocator,
            vulkan.VkPresentModeKHR,
            vulkan.vkGetPhysicalDeviceSurfacePresentModesKHR,
            .{ self.physical_device, self.surface },
            error.FailedToQueryPresentModes,
        );
        errdefer self.allocator.free(modes);

        if (modes.len == 0) {
            return error.NoPresentModes;
        }

        return modes;
    }

    fn choose_swap_extent(self: *Application, capabilities: vulkan.VkSurfaceCapabilitiesKHR) !vulkan.VkExtent2D {
        if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
            return capabilities.currentExtent;
        }

        const window = self.window orelse return error.WindowNotCreated;

        var width: c_int = 0;
        var height: c_int = 0;

        if (!sdl.SDL_GetWindowSizeInPixels(window, &width, &height)) {
            std.log.err("SDL_GetWindowSizeInPixels failed: {s}", .{
                sdl.SDL_GetError(),
            });
            return error.FailedToGetDrawableSize;
        }

        if (width <= 0 or height <= 0) {
            return error.WindowHasNoDrawableSize;
        }

        const pixel_width: u32 = @intCast(width);
        const pixel_height: u32 = @intCast(height);

        return .{
            .width = std.math.clamp(
                pixel_width,
                capabilities.minImageExtent.width,
                capabilities.maxImageExtent.width,
            ),
            .height = std.math.clamp(
                pixel_height,
                capabilities.minImageExtent.height,
                capabilities.maxImageExtent.height,
            ),
        };
    }

    fn create_swap_chain_create_information(
        self: *Application,
        surface_extent: vulkan.VkExtent2D,
        present_mode: vulkan.VkPresentModeKHR,
        image_count: u32,
        capabilities: vulkan.VkSurfaceCapabilitiesKHR,
    ) vulkan.VkSwapchainCreateInfoKHR {
        return .{
            .sType = vulkan.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = self.swap_chain_surface_format.format,
            .imageColorSpace = self.swap_chain_surface_format.colorSpace,
            .imageExtent = surface_extent,
            .imageArrayLayers = 1,
            .imageUsage = vulkan.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = vulkan.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .preTransform = capabilities.currentTransform,
            .compositeAlpha = vulkan.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = present_mode,
            .clipped = vulkan.VK_TRUE,
            .oldSwapchain = null,
        };
    }

    fn create_swap_chain(self: *Application) !void {
        std.debug.assert(self.device != null);
        std.debug.assert(self.surface != null);
        std.debug.assert(self.swap_chain == null);
        const capabilities = try self.query_surface_capabilities();

        const formats = try self.query_surface_formats();
        defer self.allocator.free(formats);

        const present_modes = try self.query_present_modes();
        defer self.allocator.free(present_modes);

        self.swap_chain_surface_format = choose_swap_surface_format(formats);

        const present_mode = try choose_swap_present_mode(present_modes);
        self.swap_chain_extent = try self.choose_swap_extent(capabilities);

        const image_count = choose_swap_minimum_image_count(capabilities);

        const create_information = self.create_swap_chain_create_information(
            self.swap_chain_extent,
            present_mode,
            image_count,
            capabilities,
        );

        try vulkan_check(vulkan.vkCreateSwapchainKHR(self.device, &create_information, null, &self.swap_chain), error.FailedToCreateSwapchain);

        errdefer {
            vulkan.vkDestroySwapchainKHR(self.device, self.swap_chain, null);
            self.swap_chain = null;
        }

        self.swap_chain_images = try vulkan_enumerate(
            self.allocator,
            vulkan.VkImage,
            vulkan.vkGetSwapchainImagesKHR,
            .{ self.device, self.swap_chain },
            error.FailedToGetSwapchainImages,
        );

        errdefer {
            self.allocator.free(self.swap_chain_images);
            self.swap_chain_images = &.{};
        }

        if (self.swap_chain_images.len == 0) {
            return error.NoSwapchainImages;
        }

        std.log.info(
            "Created swap chain with {d} images at {d}x{d}",
            .{
                self.swap_chain_images.len,
                self.swap_chain_extent.width,
                self.swap_chain_extent.height,
            },
        );
    }

    fn create_image_views(self: *Application) !void {
        std.debug.assert(self.device != null);
        std.debug.assert(self.swap_chain_images.len > 0);
        std.debug.assert(self.swap_chain_image_views.len == 0);
        if (self.swap_chain_images.len == 0) {
            return error.NoSwapChainImages;
        }

        if (self.swap_chain_image_views.len != 0) {
            return error.ImageViewsAlreadyCreated;
        }

        const image_views = try self.allocator.alloc(
            vulkan.VkImageView,
            self.swap_chain_images.len,
        );

        var created_count: u32 = 0;

        errdefer {
            for (image_views[0..created_count]) |image_view| {
                vulkan.vkDestroyImageView(self.device, image_view, null);
            }

            self.allocator.free(image_views);
        }

        var image_view_create_information = vulkan.VkImageViewCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = null,
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

        for (self.swap_chain_images, 0..) |image, index| {
            image_view_create_information.image = image;

            try vulkan_check(
                vulkan.vkCreateImageView(self.device, &image_view_create_information, null, &image_views[index]),
                error.FailedToCreateImageView,
            );

            created_count += 1;
        }

        self.swap_chain_image_views = image_views;

        std.log.debug("Created {d} swap-chain image views", .{
            self.swap_chain_image_views.len,
        });
    }

    fn cleanup_swap_chain_destroy_image_views(self: *Application) void {
        std.debug.assert(self.device != null);
        for (self.swap_chain_image_views) |image_view| {
            vulkan.vkDestroyImageView(self.device, image_view, null);
        }

        if (self.swap_chain_image_views.len != 0) {
            self.allocator.free(self.swap_chain_image_views);
        }

        self.swap_chain_image_views = &.{};
    }

    fn cleanup_swap_chain(self: *Application) void {
        if (self.device != null) {
            for (self.swap_chain_image_views) |image_view| {
                if (image_view != null) {
                    vulkan.vkDestroyImageView(
                        self.device,
                        image_view,
                        null,
                    );
                }
            }
        }

        if (self.swap_chain_image_views.len != 0) {
            self.allocator.free(self.swap_chain_image_views);
            self.swap_chain_image_views = &.{};
        }

        if (self.swap_chain != null) {
            vulkan.vkDestroySwapchainKHR(
                self.device,
                self.swap_chain,
                null,
            );
            self.swap_chain = null;
        }

        if (self.swap_chain_images.len != 0) {
            self.allocator.free(self.swap_chain_images);
            self.swap_chain_images = &.{};
        }
    }

    fn wait_for_drawable_size(self: *Application) !void {
        const window = self.window orelse return error.WindowNotCreated;

        while (true) {
            var width: c_int = 0;
            var height: c_int = 0;

            if (!sdl.SDL_GetWindowSizeInPixels(
                window,
                &width,
                &height,
            )) {
                std.log.err(
                    "SDL_GetWindowSizeInPixels failed: {s}",
                    .{sdl.SDL_GetError()},
                );
                return error.FailedToGetDrawableSize;
            }

            if (width > 0 and height > 0) {
                return;
            }

            var event: sdl.SDL_Event = undefined;
            while (sdl.SDL_PollEvent(&event)) {
                if (event.type == sdl.SDL_EVENT_QUIT) {
                    return error.WindowClosedDuringResize;
                }
            }

            sdl.SDL_Delay(16);
        }
    }

    fn recreate_swap_chain(self: *Application) !void {
        if (self.device == null) {
            return error.DeviceNotCreated;
        }

        try self.wait_for_drawable_size();

        try vulkan_check(vulkan.vkDeviceWaitIdle(self.device), error.FailedToWaitForDeviceIdle);

        self.cleanup_swap_chain();

        try self.create_swap_chain();
        errdefer self.cleanup_swap_chain();

        try self.create_image_views();

        self.framebuffer_resized = false;
    }

    fn acquire_swap_chain_image(self: *Application, present_complete_semaphore: vulkan.VkSemaphore) !?u32 {
        if (self.device == null) {
            return error.DeviceNotCreated;
        }

        if (self.swap_chain == null) {
            return error.SwapChainNotCreated;
        }

        var image_index: u32 = 0;

        const result = vulkan.vkAcquireNextImageKHR(
            self.device,
            self.swap_chain,
            std.math.maxInt(u64),
            present_complete_semaphore,
            null,
            &image_index,
        );

        if (result == vulkan.VK_ERROR_OUT_OF_DATE_KHR) {
            try self.recreate_swap_chain();
            return null;
        }

        if (result != vulkan.VK_SUCCESS and result != vulkan.VK_SUBOPTIMAL_KHR) {
            std.log.err(
                "Failed to acquire a swap-chain image",
                .{},
            );
            return error.FailedToAcquireSwapChainImage;
        }

        if (result == vulkan.VK_SUBOPTIMAL_KHR) {
            self.framebuffer_resized = true;
        }

        return image_index;
    }

    fn present_swap_chain_image(
        self: *Application,
        render_finished_semaphore: vulkan.VkSemaphore,
        image_index: u32,
    ) !void {
        if (self.swap_chain == null) {
            return error.SwapChainNotCreated;
        }

        var present_information = vulkan.VkPresentInfoKHR{
            .sType = vulkan.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &render_finished_semaphore,
            .swapchainCount = 1,
            .pSwapchains = &self.swap_chain,
            .pImageIndices = &image_index,
            .pResults = null,
        };

        const result = vulkan.vkQueuePresentKHR(
            self.graphics_queue,
            &present_information,
        );

        if (result == vulkan.VK_ERROR_OUT_OF_DATE_KHR or
            result == vulkan.VK_SUBOPTIMAL_KHR)
        {
            self.framebuffer_resized = true;
            try self.recreate_swap_chain();
            return;
        }

        if (result != vulkan.VK_SUCCESS) {
            std.log.err(
                "Failed to present the swap-chain image",
                .{},
            );
            return error.FailedToPresentSwapChainImage;
        }

        if (self.framebuffer_resized) {
            try self.recreate_swap_chain();
        }
    }

    // +---------------------+
    // |  Graphics Pipeline  |
    // +---------------------+

    fn initialize_vulkan_create_pipeline_layout(self: *Application) !void {
        std.debug.assert(self.device != null);
        std.debug.assert(self.pipeline_layout == null);
        if (self.device == null) {
            return error.DeviceNotCreated;
        }

        if (self.pipeline_layout != null) {
            return error.PipelineLayoutAlreadyCreated;
        }

        const create_information = vulkan.VkPipelineLayoutCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 0,
            .pSetLayouts = null,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };

        try vulkan_check(vulkan.vkCreatePipelineLayout(self.device, &create_information, null, &self.pipeline_layout), error.FailedToCreatePipelineLayout);

        std.log.debug("Created Vulkan pipeline layout", .{});
    }

    fn initialize_vulkan_create_graphics_pipeline_vertex_input_state() vulkan.VkPipelineVertexInputStateCreateInfo {
        return .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 0,
            .pVertexBindingDescriptions = null,
            .vertexAttributeDescriptionCount = 0,
            .pVertexAttributeDescriptions = null,
        };
    }

    fn initialize_vulkan_create_graphics_pipeline_input_assembly_state() vulkan.VkPipelineInputAssemblyStateCreateInfo {
        return .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .topology = vulkan.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = vulkan.VK_FALSE,
        };
    }

    fn initialize_vulkan_create_graphics_pipeline_viewport_state(
        viewport: *const vulkan.VkViewport,
        scissor: *const vulkan.VkRect2D,
    ) vulkan.VkPipelineViewportStateCreateInfo {
        return .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewportCount = 1,
            .pViewports = viewport,
            .scissorCount = 1,
            .pScissors = scissor,
        };
    }

    fn initialize_vulkan_create_graphics_pipeline_rasterization_state() vulkan.VkPipelineRasterizationStateCreateInfo {
        return .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthClampEnable = vulkan.VK_FALSE,
            .rasterizerDiscardEnable = vulkan.VK_FALSE,
            .polygonMode = vulkan.VK_POLYGON_MODE_FILL,
            .cullMode = vulkan.VK_CULL_MODE_BACK_BIT,
            .frontFace = vulkan.VK_FRONT_FACE_CLOCKWISE,
            .depthBiasEnable = vulkan.VK_FALSE,
            .depthBiasConstantFactor = 0.0,
            .depthBiasClamp = 0.0,
            .depthBiasSlopeFactor = 0.0,
            .lineWidth = 1.0,
        };
    }

    fn initialize_vulkan_create_graphics_pipeline_multisample_state() vulkan.VkPipelineMultisampleStateCreateInfo {
        return .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .rasterizationSamples = vulkan.VK_SAMPLE_COUNT_1_BIT,
            .sampleShadingEnable = vulkan.VK_FALSE,
            .minSampleShading = 1.0,
            .pSampleMask = null,
            .alphaToCoverageEnable = vulkan.VK_FALSE,
            .alphaToOneEnable = vulkan.VK_FALSE,
        };
    }

    fn initialize_vulkan_create_graphics_pipeline_color_blend_attachment() vulkan.VkPipelineColorBlendAttachmentState {
        return .{
            .blendEnable = vulkan.VK_FALSE,
            .srcColorBlendFactor = vulkan.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = vulkan.VK_BLEND_FACTOR_ZERO,
            .colorBlendOp = vulkan.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vulkan.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vulkan.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = vulkan.VK_BLEND_OP_ADD,
            .colorWriteMask = vulkan.VK_COLOR_COMPONENT_R_BIT |
                vulkan.VK_COLOR_COMPONENT_G_BIT |
                vulkan.VK_COLOR_COMPONENT_B_BIT |
                vulkan.VK_COLOR_COMPONENT_A_BIT,
        };
    }

    fn initialize_vulkan_create_graphics_pipeline_color_blend_state(
        attachment: *const vulkan.VkPipelineColorBlendAttachmentState,
    ) vulkan.VkPipelineColorBlendStateCreateInfo {
        return .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = vulkan.VK_FALSE,
            .logicOp = vulkan.VK_LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = attachment,
            .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
        };
    }

    fn initialize_vulkan_create_graphics_pipeline_dynamic_state(
        dynamic_states: []const vulkan.VkDynamicState,
    ) vulkan.VkPipelineDynamicStateCreateInfo {
        return .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .dynamicStateCount = @intCast(dynamic_states.len),
            .pDynamicStates = dynamic_states.ptr,
        };
    }

    fn initialize_vulkan_create_graphics_pipeline_rendering_information(
        color_format: *const vulkan.VkFormat,
    ) vulkan.VkPipelineRenderingCreateInfo {
        return .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
            .pNext = null,
            .viewMask = 0,
            .colorAttachmentCount = 1,
            .pColorAttachmentFormats = color_format,
            .depthAttachmentFormat = vulkan.VK_FORMAT_UNDEFINED,
            .stencilAttachmentFormat = vulkan.VK_FORMAT_UNDEFINED,
        };
    }

    fn initialize_vulkan_create_graphics_pipeline_create_information(
        rendering_information: *const vulkan.VkPipelineRenderingCreateInfo,
        shader_stages: []const vulkan.VkPipelineShaderStageCreateInfo,
        vertex_input: *const vulkan.VkPipelineVertexInputStateCreateInfo,
        input_assembly: *const vulkan.VkPipelineInputAssemblyStateCreateInfo,
        viewport_state: *const vulkan.VkPipelineViewportStateCreateInfo,
        rasterizer: *const vulkan.VkPipelineRasterizationStateCreateInfo,
        multisampling: *const vulkan.VkPipelineMultisampleStateCreateInfo,
        color_blending: *const vulkan.VkPipelineColorBlendStateCreateInfo,
        dynamic_state: *const vulkan.VkPipelineDynamicStateCreateInfo,
        layout: vulkan.VkPipelineLayout,
    ) vulkan.VkGraphicsPipelineCreateInfo {
        return .{
            .sType = vulkan.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = rendering_information,
            .flags = 0,
            .stageCount = @intCast(shader_stages.len),
            .pStages = shader_stages.ptr,
            .pVertexInputState = vertex_input,
            .pInputAssemblyState = input_assembly,
            .pTessellationState = null,
            .pViewportState = viewport_state,
            .pRasterizationState = rasterizer,
            .pMultisampleState = multisampling,
            .pDepthStencilState = null,
            .pColorBlendState = color_blending,
            .pDynamicState = dynamic_state,
            .layout = layout,
            .renderPass = null,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };
    }

    fn initialize_vulkan_create_graphics_pipeline(self: *Application) !void {
        std.debug.assert(self.device != null);
        std.debug.assert(self.shader_module != null);
        std.debug.assert(self.pipeline_layout != null);
        std.debug.assert(self.graphics_pipeline == null);
        if (self.device == null) return error.DeviceNotCreated;
        if (self.shader_module == null) return error.ShaderModuleNotCreated;
        if (self.pipeline_layout == null) return error.PipelineLayoutNotCreated;
        if (self.graphics_pipeline != null) return error.GraphicsPipelineAlreadyCreated;

        const shader_stages = try self.initialize_vulkan_create_graphics_pipeline_create_shader_stages();
        const vertex_input = initialize_vulkan_create_graphics_pipeline_vertex_input_state();
        const input_assembly = initialize_vulkan_create_graphics_pipeline_input_assembly_state();

        const viewport = vulkan.VkViewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(self.swap_chain_extent.width),
            .height = @floatFromInt(self.swap_chain_extent.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        const scissor = vulkan.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swap_chain_extent,
        };

        const viewport_state = initialize_vulkan_create_graphics_pipeline_viewport_state(&viewport, &scissor);
        const rasterizer = initialize_vulkan_create_graphics_pipeline_rasterization_state();
        const multisampling = initialize_vulkan_create_graphics_pipeline_multisample_state();

        const color_blend_attachment = initialize_vulkan_create_graphics_pipeline_color_blend_attachment();
        const color_blending = initialize_vulkan_create_graphics_pipeline_color_blend_state(&color_blend_attachment);

        const dynamic_states = [_]vulkan.VkDynamicState{
            vulkan.VK_DYNAMIC_STATE_VIEWPORT,
            vulkan.VK_DYNAMIC_STATE_SCISSOR,
        };
        const dynamic_state = initialize_vulkan_create_graphics_pipeline_dynamic_state(&dynamic_states);

        var color_format = self.swap_chain_surface_format.format;
        const rendering_information = initialize_vulkan_create_graphics_pipeline_rendering_information(&color_format);

        const pipeline_create_information = initialize_vulkan_create_graphics_pipeline_create_information(
            &rendering_information,
            &shader_stages,
            &vertex_input,
            &input_assembly,
            &viewport_state,
            &rasterizer,
            &multisampling,
            &color_blending,
            &dynamic_state,
            self.pipeline_layout,
        );

        try vulkan_check(
            vulkan.vkCreateGraphicsPipelines(
                self.device,
                null,
                1,
                &pipeline_create_information,
                null,
                &self.graphics_pipeline,
            ),
            error.FailedToCreateGraphicsPipeline,
        );
        std.log.info("Created Vulkan graphics pipeline", .{});
    }

    fn cleanup_destroy_graphics_pipeline(self: *Application) void {
        if (self.graphics_pipeline != null) {
            vulkan.vkDestroyPipeline(
                self.device,
                self.graphics_pipeline,
                null,
            );
            self.graphics_pipeline = null;
        }
    }

    fn cleanup_destroy_pipeline_layout(self: *Application) void {
        if (self.pipeline_layout != null) {
            vulkan.vkDestroyPipelineLayout(
                self.device,
                self.pipeline_layout,
                null,
            );
            self.pipeline_layout = null;
        }
    }

    // +-----------------+
    // |  Shader Module  |
    // +-----------------+

    fn initialize_vulkan_create_graphics_pipeline_create_shader_modules_read_shader_code(
        self: *Application,
        path: []const u8,
    ) ![]u32 {
        const io = std.Io.Threaded.global_single_threaded.io();

        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        const file_stat = try file.stat(io);
        const byte_count: u32 = @intCast(file_stat.size);

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
        const bytes_read = try file.readPositionalAll(io, bytes, 0);

        if (bytes_read != byte_count) {
            return error.ShaderFileTruncated;
        }

        return words;
    }

    fn initialize_vulkan_create_graphics_pipeline_create_shader_modules_create_shader_module(self: *Application, code: []const u32) !vulkan.VkShaderModule {
        if (code.len == 0) {
            return error.EmptyShaderCode;
        }

        var create_information = vulkan.VkShaderModuleCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = code.len * @sizeOf(u32),
            .pCode = code.ptr,
        };

        var shader_module: vulkan.VkShaderModule = null;

        try vulkan_check(vulkan.vkCreateShaderModule(self.device, &create_information, null, &shader_module), error.FailedToCreateShaderModule);

        return shader_module;
    }

    fn initialize_vulkan_create_graphics_pipeline_create_shader_modules(self: *Application) !void {
        const shader_code = try self.initialize_vulkan_create_graphics_pipeline_create_shader_modules_read_shader_code("shaders/slang.spv");
        defer self.allocator.free(shader_code);

        self.shader_module = try self.initialize_vulkan_create_graphics_pipeline_create_shader_modules_create_shader_module(shader_code);

        std.log.debug("Created Vulkan shader module", .{});
    }

    fn initialize_vulkan_create_graphics_pipeline_make_vertex_shader_stage(self: *Application) !vulkan.VkPipelineShaderStageCreateInfo {
        if (self.shader_module == null) {
            return error.ShaderModuleNotCreated;
        }

        return .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = vulkan.VK_SHADER_STAGE_VERTEX_BIT,
            .module = self.shader_module,
            .pName = "vertMain",
            .pSpecializationInfo = null,
        };
    }

    fn initialize_vulkan_create_graphics_pipeline_make_fragment_shader_stage(self: *Application) !vulkan.VkPipelineShaderStageCreateInfo {
        if (self.shader_module == null) {
            return error.ShaderModuleNotCreated;
        }

        return .{
            .sType = vulkan.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = vulkan.VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = self.shader_module,
            .pName = "fragMain",
            .pSpecializationInfo = null,
        };
    }

    fn initialize_vulkan_create_graphics_pipeline_create_shader_stages(self: *Application) ![2]vulkan.VkPipelineShaderStageCreateInfo {
        return .{
            try self.initialize_vulkan_create_graphics_pipeline_make_vertex_shader_stage(),
            try self.initialize_vulkan_create_graphics_pipeline_make_fragment_shader_stage(),
        };
    }

    fn destroyShaderModule(self: *Application) void {
        if (self.shader_module != null) {
            vulkan.vkDestroyShaderModule(
                self.device,
                self.shader_module,
                null,
            );
            self.shader_module = null;
        }
    }

    // +------------------+
    // |  Command Buffer  |
    // +------------------+

    fn initialize_vulkan_create_command_pool(self: *Application) !void {
        std.debug.assert(self.device != null);
        std.debug.assert(self.command_pool == null);
        if (self.device == null) {
            return error.DeviceNotCreated;
        }

        if (self.command_pool != null) {
            return error.CommandPoolAlreadyCreated;
        }

        const pool_information = vulkan.VkCommandPoolCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = vulkan.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.graphics_family,
        };

        try vulkan_check(vulkan.vkCreateCommandPool(self.device, &pool_information, null, &self.command_pool), error.FailedToCreateCommandPool);

        std.log.debug("Created Vulkan command pool", .{});
    }

    fn initialize_vulkan_create_command_buffers(self: *Application) !void {
        std.debug.assert(self.device != null);
        std.debug.assert(self.command_pool != null);
        std.debug.assert(self.command_buffers.len == 0);
        if (self.device == null) {
            return error.DeviceNotCreated;
        }

        if (self.command_pool == null) {
            return error.CommandPoolNotCreated;
        }

        if (self.command_buffers.len != 0) {
            return error.CommandBuffersAlreadyCreated;
        }

        self.command_buffers = try self.allocator.alloc(
            vulkan.VkCommandBuffer,
            frames_in_flight_max,
        );
        errdefer {
            self.allocator.free(self.command_buffers);
            self.command_buffers = &.{};
        }

        const allocation_information = vulkan.VkCommandBufferAllocateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = vulkan.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = @intCast(frames_in_flight_max),
        };

        try vulkan_check(vulkan.vkAllocateCommandBuffers(self.device, &allocation_information, self.command_buffers.ptr), error.FailedToAllocateCommandBuffers);

        std.log.debug(
            "Allocated {d} command buffers for frames in flight",
            .{frames_in_flight_max},
        );
    }

    fn transition_image_layout(
        self: *Application,
        command_buffer: vulkan.VkCommandBuffer,
        image_index: u32,
        old_layout: vulkan.VkImageLayout,
        new_layout: vulkan.VkImageLayout,
        source_access_mask: vulkan.VkAccessFlags2,
        target_access_mask: vulkan.VkAccessFlags2,
        source_stage_mask: vulkan.VkPipelineStageFlags2,
        target_stage_mask: vulkan.VkPipelineStageFlags2,
    ) !void {
        std.debug.assert(command_buffer != null);
        std.debug.assert(image_index < self.swap_chain_images.len);
        const index = image_index;

        if (index >= self.swap_chain_images.len) {
            return error.SwapChainImageIndexOutOfRange;
        }

        const barrier = vulkan.VkImageMemoryBarrier2{
            .sType = vulkan.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .pNext = null,
            .srcStageMask = source_stage_mask,
            .srcAccessMask = source_access_mask,
            .dstStageMask = target_stage_mask,
            .dstAccessMask = target_access_mask,
            .oldLayout = old_layout,
            .newLayout = new_layout,
            .srcQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vulkan.VK_QUEUE_FAMILY_IGNORED,
            .image = self.swap_chain_images[index],
            .subresourceRange = .{
                .aspectMask = vulkan.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        const dependency_information = vulkan.VkDependencyInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .pNext = null,
            .dependencyFlags = 0,
            .memoryBarrierCount = 0,
            .pMemoryBarriers = null,
            .bufferMemoryBarrierCount = 0,
            .pBufferMemoryBarriers = null,
            .imageMemoryBarrierCount = 1,
            .pImageMemoryBarriers = &barrier,
        };

        vulkan.vkCmdPipelineBarrier2(
            command_buffer,
            &dependency_information,
        );
    }

    fn record_command_buffer_draw_commands(
        self: *Application,
        command_buffer: vulkan.VkCommandBuffer,
    ) void {
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

        vulkan.vkCmdSetViewport(
            command_buffer,
            0,
            1,
            &viewport,
        );

        const scissor = vulkan.VkRect2D{
            .offset = .{
                .x = 0,
                .y = 0,
            },
            .extent = self.swap_chain_extent,
        };

        vulkan.vkCmdSetScissor(
            command_buffer,
            0,
            1,
            &scissor,
        );

        vulkan.vkCmdDraw(
            command_buffer,
            3,
            1,
            0,
            0,
        );
    }

    fn record_command_buffer_rendering_information(
        view: vulkan.VkImageView,
        extent: vulkan.VkExtent2D,
        attachment_information: *vulkan.VkRenderingAttachmentInfo,
    ) vulkan.VkRenderingInfo {
        attachment_information.* = .{
            .sType = vulkan.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .pNext = null,
            .imageView = view,
            .imageLayout = vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .resolveMode = vulkan.VK_RESOLVE_MODE_NONE,
            .resolveImageView = null,
            .resolveImageLayout = vulkan.VK_IMAGE_LAYOUT_UNDEFINED,
            .loadOp = vulkan.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vulkan.VK_ATTACHMENT_STORE_OP_STORE,
            .clearValue = .{
                .color = .{
                    .float32 = .{ 0.0, 0.0, 0.0, 1.0 },
                },
            },
        };

        return .{
            .sType = vulkan.VK_STRUCTURE_TYPE_RENDERING_INFO,
            .pNext = null,
            .flags = 0,
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = extent,
            },
            .layerCount = 1,
            .viewMask = 0,
            .colorAttachmentCount = 1,
            .pColorAttachments = attachment_information,
            .pDepthAttachment = null,
            .pStencilAttachment = null,
        };
    }

    fn record_command_buffer(
        self: *Application,
        command_buffer: vulkan.VkCommandBuffer,
        image_index: u32,
    ) !void {
        std.debug.assert(command_buffer != null);
        std.debug.assert(image_index < self.swap_chain_images.len);
        std.debug.assert(image_index < self.swap_chain_image_views.len);
        if (self.graphics_pipeline == null) return error.GraphicsPipelineNotCreated;
        if (image_index >= self.swap_chain_images.len) return error.SwapChainImageIndexOutOfRange;
        if (image_index >= self.swap_chain_image_views.len) return error.SwapChainImageViewIndexOutOfRange;

        const begin_information = vulkan.VkCommandBufferBeginInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = 0,
            .pInheritanceInfo = null,
        };

        try vulkan_check(vulkan.vkBeginCommandBuffer(command_buffer, &begin_information), error.FailedToBeginCommandBuffer);
        errdefer _ = vulkan.vkEndCommandBuffer(command_buffer);

        try self.transition_image_layout(
            command_buffer,
            image_index,
            vulkan.VK_IMAGE_LAYOUT_UNDEFINED,
            vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            0,
            vulkan.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            0,
            vulkan.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        );

        var attachment_information: vulkan.VkRenderingAttachmentInfo = undefined;
        const rendering_information = record_command_buffer_rendering_information(
            self.swap_chain_image_views[image_index],
            self.swap_chain_extent,
            &attachment_information,
        );

        vulkan.vkCmdBeginRendering(command_buffer, &rendering_information);
        self.record_command_buffer_draw_commands(command_buffer);
        vulkan.vkCmdEndRendering(command_buffer);

        try self.transition_image_layout(
            command_buffer,
            @intCast(image_index),
            vulkan.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            vulkan.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            vulkan.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            0,
            vulkan.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            vulkan.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT,
        );

        try vulkan_check(vulkan.vkEndCommandBuffer(command_buffer), error.FailedToEndCommandBuffer);
    }

    fn cleanup_destroy_command_buffers(self: *Application) void {
        if (self.device != null and
            self.command_pool != null and
            self.command_buffers.len != 0)
        {
            vulkan.vkFreeCommandBuffers(
                self.device,
                self.command_pool,
                @intCast(self.command_buffers.len),
                self.command_buffers.ptr,
            );
        }

        if (self.command_buffers.len != 0) {
            self.allocator.free(self.command_buffers);
            self.command_buffers = &.{};
        }
    }

    // +-------------------+
    // |  Synchronization  |
    // +-------------------+

    fn initialize_vulkan_create_synchronization_objects_semaphores(
        self: *Application,
        semaphore_information: *const vulkan.VkSemaphoreCreateInfo,
    ) !void {
        var created_present_complete: u32 = 0;
        errdefer {
            while (created_present_complete > 0) {
                created_present_complete -= 1;
                vulkan.vkDestroySemaphore(
                    self.device,
                    self.present_complete_semaphores[created_present_complete],
                    null,
                );
            }
        }

        var created_render_finished: u32 = 0;
        errdefer {
            while (created_render_finished > 0) {
                created_render_finished -= 1;
                vulkan.vkDestroySemaphore(
                    self.device,
                    self.render_finished_semaphores[created_render_finished],
                    null,
                );
            }
        }

        while (created_present_complete < frames_in_flight_max) : (created_present_complete += 1) {
            try vulkan_check(
                vulkan.vkCreateSemaphore(
                    self.device,
                    semaphore_information,
                    null,
                    &self.present_complete_semaphores[created_present_complete],
                ),
                error.FailedToCreateAcquireSemaphore,
            );
        }

        while (created_render_finished < self.swap_chain_images.len) : (created_render_finished += 1) {
            try vulkan_check(
                vulkan.vkCreateSemaphore(
                    self.device,
                    semaphore_information,
                    null,
                    &self.render_finished_semaphores[created_render_finished],
                ),
                error.FailedToCreateRenderFinishedSemaphore,
            );
        }
    }

    fn initialize_vulkan_create_synchronization_objects_fences(
        self: *Application,
        fence_information: *const vulkan.VkFenceCreateInfo,
    ) !void {
        var created_fences: u32 = 0;
        errdefer {
            while (created_fences > 0) {
                created_fences -= 1;
                vulkan.vkDestroyFence(
                    self.device,
                    self.in_flight_fences[created_fences],
                    null,
                );
            }
        }

        while (created_fences < frames_in_flight_max) : (created_fences += 1) {
            try vulkan_check(
                vulkan.vkCreateFence(
                    self.device,
                    fence_information,
                    null,
                    &self.in_flight_fences[created_fences],
                ),
                error.FailedToCreateInFlightFence,
            );
        }
    }

    fn initialize_vulkan_create_synchronization_objects(self: *Application) !void {
        std.debug.assert(self.device != null);
        std.debug.assert(self.swap_chain_images.len > 0);
        std.debug.assert(self.present_complete_semaphores.len == 0);
        std.debug.assert(self.render_finished_semaphores.len == 0);
        std.debug.assert(self.in_flight_fences.len == 0);
        if (self.device == null) return error.DeviceNotCreated;
        if (self.swap_chain_images.len == 0) return error.NoSwapChainImages;
        if (self.present_complete_semaphores.len != 0 or
            self.render_finished_semaphores.len != 0 or
            self.in_flight_fences.len != 0)
        {
            return error.SyncObjectsAlreadyCreated;
        }

        self.present_complete_semaphores = try self.allocator.alloc(vulkan.VkSemaphore, frames_in_flight_max);
        errdefer {
            self.allocator.free(self.present_complete_semaphores);
            self.present_complete_semaphores = &.{};
        }
        self.render_finished_semaphores = try self.allocator.alloc(vulkan.VkSemaphore, self.swap_chain_images.len);
        errdefer {
            self.allocator.free(self.render_finished_semaphores);
            self.render_finished_semaphores = &.{};
        }
        self.in_flight_fences = try self.allocator.alloc(vulkan.VkFence, frames_in_flight_max);
        errdefer {
            self.allocator.free(self.in_flight_fences);
            self.in_flight_fences = &.{};
        }

        const semaphore_information = vulkan.VkSemaphoreCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };
        const fence_information = vulkan.VkFenceCreateInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = vulkan.VK_FENCE_CREATE_SIGNALED_BIT,
        };

        try self.initialize_vulkan_create_synchronization_objects_semaphores(&semaphore_information);
        try self.initialize_vulkan_create_synchronization_objects_fences(&fence_information);

        std.log.debug(
            "Created synchronization objects for {d} frames and {d} swap-chain images",
            .{
                frames_in_flight_max,
                self.swap_chain_images.len,
            },
        );
    }

    fn draw_frame_check_resources_ready(self: *Application) !void {
        std.debug.assert(self.device != null);
        std.debug.assert(self.graphics_queue != null);
        std.debug.assert(self.swap_chain != null);
        std.debug.assert(self.command_buffers.len == frames_in_flight_max);
        std.debug.assert(self.present_complete_semaphores.len == frames_in_flight_max);
        std.debug.assert(self.in_flight_fences.len == frames_in_flight_max);
        std.debug.assert(self.render_finished_semaphores.len == self.swap_chain_images.len);

        if (self.device == null) return error.DeviceNotCreated;
        if (self.graphics_queue == null) return error.GraphicsQueueNotCreated;
        if (self.swap_chain == null) return error.SwapChainNotCreated;
        if (self.command_buffers.len != frames_in_flight_max) return error.CommandBuffersNotReady;
        if (self.present_complete_semaphores.len != frames_in_flight_max) return error.AcquireSemaphoresNotReady;
        if (self.in_flight_fences.len != frames_in_flight_max) return error.InFlightFencesNotReady;
        if (self.render_finished_semaphores.len != self.swap_chain_images.len) return error.RenderFinishedSemaphoresNotReady;
    }

    fn draw_frame_submit_command_buffer(
        self: *Application,
        frame_index: u32,
        image_index: u32,
    ) !void {
        const wait_stage: vulkan.VkPipelineStageFlags = vulkan.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;

        const submit_information = vulkan.VkSubmitInfo{
            .sType = vulkan.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.present_complete_semaphores[frame_index],
            .pWaitDstStageMask = &wait_stage,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.command_buffers[frame_index],
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &self.render_finished_semaphores[image_index],
        };

        try vulkan_check(
            vulkan.vkQueueSubmit(
                self.graphics_queue,
                1,
                &submit_information,
                self.in_flight_fences[frame_index],
            ),
            error.FailedToSubmitFrame,
        );
    }

    fn draw_frame(self: *Application) !void {
        try self.draw_frame_check_resources_ready();

        const frame_index = self.frame_index;

        // Wait for the fence associated with this frame slot to be signaled by the GPU.
        // This ensures the CPU does not overwrite the command buffer or in-flight resources
        // while the GPU is still executing commands from the previous loop iteration of this slot.
        try vulkan_check(
            vulkan.vkWaitForFences(
                self.device,
                1,
                &self.in_flight_fences[frame_index],
                vulkan.VK_TRUE,
                std.math.maxInt(u64),
            ),
            error.FailedToWaitForInFlightFence,
        );

        // Acquire the next available image index from the Vulkan swapchain.
        // We pass a semaphore that will be signaled when the presentation engine is done
        // reading from the image, indicating it is safe for our queue to write to it.
        const image_index = (try self.acquire_swap_chain_image(
            self.present_complete_semaphores[frame_index],
        )) orelse return;

        if (image_index >= self.swap_chain_images.len) return error.AcquiredImageIndexOutOfBounds;
        if (image_index >= self.render_finished_semaphores.len) return error.RenderFinishedSemaphoreIndexOutOfBounds;

        // Reset the fence before submitting command buffers to the queue.
        // This moves the fence back into an unsignaled state so we can wait on it in the next loop.
        try vulkan_check(vulkan.vkResetFences(self.device, 1, &self.in_flight_fences[frame_index]), error.FailedToResetInFlightFence);

        // Reset the command buffer memory for this frame slot before recording.
        // Resetting is much more efficient than destroying and re-allocating command buffers.
        try vulkan_check(vulkan.vkResetCommandBuffer(self.command_buffers[frame_index], 0), error.FailedToResetCommandBuffer);

        try self.record_command_buffer(self.command_buffers[frame_index], image_index);

        try self.draw_frame_submit_command_buffer(frame_index, image_index);

        // Present the rendered image (may trigger recreation).
        try self.present_swap_chain_image(self.render_finished_semaphores[image_index], image_index);

        // Advance to the next frame slot.
        self.frame_index = (self.frame_index + 1) % frames_in_flight_max;
    }

    fn cleanup_destroy_synchronization_objects(self: *Application) void {
        if (self.device != null) {
            for (self.present_complete_semaphores) |semaphore| {
                if (semaphore != null) {
                    vulkan.vkDestroySemaphore(
                        self.device,
                        semaphore,
                        null,
                    );
                }
            }

            for (self.render_finished_semaphores) |semaphore| {
                if (semaphore != null) {
                    vulkan.vkDestroySemaphore(
                        self.device,
                        semaphore,
                        null,
                    );
                }
            }

            for (self.in_flight_fences) |fence| {
                if (fence != null) {
                    vulkan.vkDestroyFence(
                        self.device,
                        fence,
                        null,
                    );
                }
            }
        }

        if (self.present_complete_semaphores.len != 0) {
            self.allocator.free(self.present_complete_semaphores);
            self.present_complete_semaphores = &.{};
        }

        if (self.render_finished_semaphores.len != 0) {
            self.allocator.free(self.render_finished_semaphores);
            self.render_finished_semaphores = &.{};
        }

        if (self.in_flight_fences.len != 0) {
            self.allocator.free(self.in_flight_fences);
            self.in_flight_fences = &.{};
        }

        self.frame_index = 0;
    }
};

// +---------------+
// |  FPS Counter  |
// +---------------+

const FPSCounter = struct {
    timer: u64,
    frame_count: u32 = 0,

    fn init() FPSCounter {
        return .{ .timer = sdl.SDL_GetTicks() };
    }

    // Updates the window title with FPS/frame-time twice per second.
    fn tick(self: *FPSCounter, window: ?*sdl.SDL_Window) void {
        self.frame_count += 1;

        const now = sdl.SDL_GetTicks();
        const elapsed_ms = now - self.timer;
        if (elapsed_ms < 500) return;

        const frames_per_second = @as(f64, @floatFromInt(self.frame_count)) * 1000.0 /
            @as(f64, @floatFromInt(elapsed_ms));
        const frame_time_ms_average = @as(f64, @floatFromInt(elapsed_ms)) /
            @as(f64, @floatFromInt(self.frame_count));

        var title_buffer: [128]u8 = undefined;
        const title = std.fmt.bufPrintZ(
            &title_buffer,
            "Koba - FPS: {d:.1} | Frame: {d:.2}ms",
            .{ frames_per_second, frame_time_ms_average },
        ) catch "Koba";

        _ = sdl.SDL_SetWindowTitle(window, title.ptr);

        self.timer = now;
        self.frame_count = 0;
    }
};

// +----------------+
// | Free Functions |
// +----------------+

fn debug_callback(
    message_severity: vulkan.VkDebugUtilsMessageSeverityFlagBitsEXT,
    message_type: vulkan.VkDebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const vulkan.VkDebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(.c) vulkan.VkBool32 {
    _ = message_severity;
    _ = message_type;
    _ = user_data;

    if (callback_data) |data| {
        std.log.warn("validation layer: {s}", .{data.pMessage});
    }

    return vulkan.VK_FALSE;
}

fn check_required_features(physical_device: vulkan.VkPhysicalDevice) bool {
    var extended_dynamic_state: vulkan.VkPhysicalDeviceExtendedDynamicStateFeaturesEXT = .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_FEATURES_EXT,
        .pNext = null,
        .extendedDynamicState = vulkan.VK_FALSE,
    };
    var vulkan_1_3_features: vulkan.VkPhysicalDeviceVulkan13Features = .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        .pNext = &extended_dynamic_state,
        .dynamicRendering = vulkan.VK_FALSE,
        .synchronization2 = vulkan.VK_FALSE,
    };
    var vulkan_1_1_features: vulkan.VkPhysicalDeviceVulkan11Features = .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
        .pNext = &vulkan_1_3_features,
        .shaderDrawParameters = vulkan.VK_FALSE,
    };
    var features2: vulkan.VkPhysicalDeviceFeatures2 = .{
        .sType = vulkan.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
        .pNext = &vulkan_1_1_features,
        .features = std.mem.zeroes(vulkan.VkPhysicalDeviceFeatures),
    };

    vulkan.vkGetPhysicalDeviceFeatures2(physical_device, &features2);

    return vulkan_1_1_features.shaderDrawParameters == vulkan.VK_TRUE and
        vulkan_1_3_features.dynamicRendering == vulkan.VK_TRUE and
        vulkan_1_3_features.synchronization2 == vulkan.VK_TRUE and
        extended_dynamic_state.extendedDynamicState == vulkan.VK_TRUE;
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

fn choose_swap_present_mode(available_modes: []const vulkan.VkPresentModeKHR) !vulkan.VkPresentModeKHR {
    var has_fifo = false;

    for (available_modes) |mode| {
        // Uncomment to enable immediate mode (no vsync -> no frames_per_second cap).
        // If (mode == vulkan.VK_PRESENT_MODE_IMMEDIATE_KHR) {.
        // Return vulkan.VK_PRESENT_MODE_IMMEDIATE_KHR;.
        // }

        // Mailbox mode (triple buffering) is preferred as it avoids tearing while maintaining
        // low input latency compared to double-buffered VSync (FIFO).
        if (mode == vulkan.VK_PRESENT_MODE_MAILBOX_KHR) {
            return vulkan.VK_PRESENT_MODE_MAILBOX_KHR;
        }

        if (mode == vulkan.VK_PRESENT_MODE_FIFO_KHR) {
            has_fifo = true;
        }
    }

    if (has_fifo) {
        return vulkan.VK_PRESENT_MODE_FIFO_KHR;
    }

    return error.NoFifoPresentMode;
}

fn choose_swap_minimum_image_count(capabilities: vulkan.VkSurfaceCapabilitiesKHR) u32 {
    var image_count = @max(3, capabilities.minImageCount);

    if (capabilities.maxImageCount != 0 and
        image_count > capabilities.maxImageCount)
    {
        image_count = capabilities.maxImageCount;
    }

    return image_count;
}

// +------------------+
// |  Vulkan Helpers  |
// +------------------+

fn vulkan_check(result: vulkan.VkResult, failure: anytype) @TypeOf(failure)!void {
    if (result == vulkan.VK_SUCCESS) return;

    std.log.err("{s} failed (VkResult = {d})", .{ @errorName(failure), result });
    return failure;
}

fn vulkan_enumerate(
    allocator: std.mem.Allocator,
    comptime ElementType: type,
    function: anytype,
    arguments: anytype,
    failure: anytype,
) (std.mem.Allocator.Error || @TypeOf(failure))![]ElementType {
    var count: u32 = 0;

    const count_result = @call(.auto, function, arguments ++ .{ &count, @as([*c]ElementType, null) });
    if (@TypeOf(count_result) != void) try vulkan_check(count_result, failure);

    const items = try allocator.alloc(ElementType, count);
    errdefer allocator.free(items);

    if (count > 0) {
        const fill_result = @call(.auto, function, arguments ++ .{ &count, items.ptr });
        if (@TypeOf(fill_result) != void) try vulkan_check(fill_result, failure);
    }

    return items;
}
