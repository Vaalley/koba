const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl3");
const vk = @import("vulkan");

const validation_layers = [_][*c]const u8{"VK_LAYER_KHRONOS_validation"};
const enable_validation_layers = builtin.mode == .Debug;
const required_device_extensions = [_][*:0]const u8{
    "VK_KHR_swapchain",
};

const HelloTriangleApplication = struct {
    const WIDTH: u32 = 1280;
    const HEIGHT: u32 = 720;

    window: ?*sdl.SDL_Window = null,
    instance: vk.VkInstance = null,
    allocator: std.mem.Allocator,
    debug_messenger: vk.VkDebugUtilsMessengerEXT = null,
    surface: vk.VkSurfaceKHR = null,
    physical_device: vk.VkPhysicalDevice = null,
    device: vk.VkDevice = null,
    graphics_family: u32 = 0,
    graphics_queue: vk.VkQueue = null,
    swap_chain: vk.VkSwapchainKHR = null,
    swap_chain_images: []vk.VkImage = &.{},
    swap_chain_surface_format: vk.VkSurfaceFormatKHR = undefined,
    swap_chain_extent: vk.VkExtent2D = undefined,
    swap_chain_image_views: []vk.VkImageView = &.{},
    shader_module: vk.VkShaderModule = null,
    pipeline_layout: vk.VkPipelineLayout = null,
    graphics_pipeline: vk.VkPipeline = null,
    command_pool: vk.VkCommandPool = null,
    command_buffer: vk.VkCommandBuffer = null,

    // +-------------+
    // |  Lifecycle  |
    // +-------------+

    pub fn run(self: *HelloTriangleApplication) !void {
        try self.initWindow();
        defer self.cleanup();

        try self.initVulkan();
        try self.mainLoop();
    }

    fn initWindow(self: *HelloTriangleApplication) !void {
        if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) {
            std.log.err("SDL Initialization Failed: {s}", .{sdl.SDL_GetError()});
            return error.SDLInitFailed;
        }

        self.window = sdl.SDL_CreateWindow(
            "SDL3 + Vulkan",
            @intCast(WIDTH),
            @intCast(HEIGHT),
            sdl.SDL_WINDOW_VULKAN,
        ) orelse {
            std.log.err("Window Creation Failed: {s}", .{sdl.SDL_GetError()});
            return error.WindowCreationFailed;
        };
    }

    fn initVulkan(self: *HelloTriangleApplication) !void {
        std.log.debug("Creating instance...", .{});
        try self.createInstance();

        std.log.debug("Setting up debug messenger...", .{});
        try self.setupDebugMessenger();

        std.log.debug("Creating window surface...", .{});
        try self.createSurface();

        std.log.debug("Picking physical device...", .{});
        try self.pickPhysicalDevice();

        std.log.debug("Creating logical device...", .{});
        try self.createLogicalDevice();

        std.log.debug("Creating swap chain...", .{});
        try self.createSwapChain();

        std.log.debug("Creating image views...", .{});
        try self.createImageViews();

        std.log.debug("Creating shader modules...", .{});
        try self.createShaderModules();

        std.log.debug("Creating pipeline layout...", .{});
        try self.createPipelineLayout();

        std.log.debug("Creating graphics pipeline...", .{});
        try self.createGraphicsPipeline();

        std.log.debug("Creating command pool...", .{});
        try self.createCommandPool();

        std.log.debug("Creating command buffer...", .{});
        try self.createCommandBuffer();

        std.log.info("Vulkan initialization complete", .{});
    }

    fn mainLoop(self: *HelloTriangleApplication) !void {
        var running = true;
        while (running) {
            var event: sdl.SDL_Event = undefined;
            while (sdl.SDL_PollEvent(&event)) {
                if (event.type == sdl.SDL_EVENT_QUIT) {
                    running = false;
                }
            }
        }

        _ = self;
    }

    fn cleanup(self: *HelloTriangleApplication) void {
        std.log.debug("Cleaning up...", .{});

        self.destroyCommandResources();

        self.destroyGraphicsPipeline();
        self.destroyPipelineLayout();
        self.destroyShaderModule();

        self.destroyImageViews();

        if (self.swap_chain_images.len != 0) {
            std.log.debug("Freeing swap chain image slice", .{});
            self.allocator.free(self.swap_chain_images);
            self.swap_chain_images = &.{};
        }

        if (self.swap_chain != null and self.device != null) {
            std.log.debug("Destroying swap chain", .{});
            vk.vkDestroySwapchainKHR(self.device, self.swap_chain, null);
            self.swap_chain = null;
        }

        if (self.device != null) {
            std.log.debug("Destroying logical device", .{});
            vk.vkDestroyDevice(self.device, null);
        }

        if (self.surface != null) {
            std.log.debug("Destroying window surface", .{});
            vk.vkDestroySurfaceKHR(self.instance, self.surface, null);
        }

        self.destroyDebugMessenger();

        if (self.instance != null) {
            std.log.debug("Destroying instance", .{});
            vk.vkDestroyInstance(self.instance, null);
        }

        sdl.SDL_DestroyWindow(self.window);
        sdl.SDL_Quit();

        std.log.debug("Cleanup complete", .{});
    }

    // +------------------+
    // |  Instance Setup  |
    // +------------------+

    fn createInstance(self: *HelloTriangleApplication) !void {
        if (enable_validation_layers) {
            const supported = try checkValidationLayerSupport(self);
            if (!supported) {
                std.log.err("Validation layers requested, but not available!", .{});
                return error.ValidationLayersNotSupported;
            }

            std.log.debug("Running with validation layer(s):", .{});

            for (validation_layers) |validation_layer| {
                std.log.debug("  {s}", .{validation_layer});
            }
        }

        const app_info = vk.VkApplicationInfo{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "Koba",
            .applicationVersion = vk.VK_MAKE_VERSION(1, 0, 0),
            .pEngineName = "No Engine",
            .engineVersion = vk.VK_MAKE_VERSION(1, 0, 0),
            .apiVersion = vk.VK_API_VERSION_1_4,
        };

        const required_extensions = try getRequiredExtensions(self);
        defer self.allocator.free(required_extensions);

        try checkExtensionSupport(self, required_extensions);

        const required_layers: []const [*c]const u8 =
            if (enable_validation_layers) &validation_layers else &[_][*c]const u8{};

        var create_info = vk.VkInstanceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &app_info,
            .enabledExtensionCount = @intCast(required_extensions.len),
            .ppEnabledExtensionNames = required_extensions.ptr,
            .enabledLayerCount = @intCast(required_layers.len),
            .ppEnabledLayerNames = required_layers.ptr,
        };

        const result = vk.vkCreateInstance(&create_info, null, &self.instance);
        if (result != vk.VK_SUCCESS) {
            std.log.err("Failed to create Vulkan instance (VkResult = {d})", .{result});
            return error.InstanceCreationFailed;
        }

        std.log.info("Vulkan instance created (API version 1.4)", .{});
    }

    fn checkValidationLayerSupport(self: *HelloTriangleApplication) !bool {
        var layer_count: u32 = 0;
        {
            const result = vk.vkEnumerateInstanceLayerProperties(&layer_count, null);
            if (result != vk.VK_SUCCESS) {
                std.log.err("vkEnumerateInstanceLayerProperties (count) failed (VkResult = {d})", .{result});
                return error.EnumerationFailed;
            }
        }

        const available_layers = try self.allocator.alloc(vk.VkLayerProperties, layer_count);
        defer self.allocator.free(available_layers);

        {
            const result = vk.vkEnumerateInstanceLayerProperties(&layer_count, available_layers.ptr);
            if (result != vk.VK_SUCCESS) {
                std.log.err("vkEnumerateInstanceLayerProperties (fill) failed (VkResult = {d})", .{result});
                return error.EnumerationFailed;
            }
        }

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

    fn checkExtensionSupport(self: *HelloTriangleApplication, required_extensions: []const [*c]const u8) !void {
        var extension_count: u32 = 0;
        {
            const result = vk.vkEnumerateInstanceExtensionProperties(null, &extension_count, null);
            if (result != vk.VK_SUCCESS) {
                std.log.err("vkEnumerateInstanceExtensionProperties (count) failed (VkResult = {d})", .{result});
                return error.EnumerationFailed;
            }
        }

        const available_extensions = try self.allocator.alloc(vk.VkExtensionProperties, extension_count);
        defer self.allocator.free(available_extensions);

        {
            const result = vk.vkEnumerateInstanceExtensionProperties(null, &extension_count, available_extensions.ptr);
            if (result != vk.VK_SUCCESS) {
                std.log.err("vkEnumerateInstanceExtensionProperties (fill) failed (VkResult = {d})", .{result});
                return error.EnumerationFailed;
            }
        }

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

    fn getRequiredExtensions(self: *HelloTriangleApplication) ![][*c]const u8 {
        var sdl_extension_count: u32 = 0;
        const sdl_extensions = sdl.SDL_Vulkan_GetInstanceExtensions(&sdl_extension_count) orelse {
            std.log.err("Failed to query SDL Vulkan extensions: {s}", .{sdl.SDL_GetError()});
            return error.SDLVulkanExtensionsFailed;
        };

        var extensions: std.ArrayList([*c]const u8) = .empty;
        defer extensions.deinit(self.allocator);

        try extensions.appendSlice(self.allocator, sdl_extensions[0..sdl_extension_count]);

        if (enable_validation_layers) {
            try extensions.append(self.allocator, vk.VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
        }

        return extensions.toOwnedSlice(self.allocator);
    }

    // +-------------------+
    // |  Debug Messenger  |
    // +-------------------+

    fn setupDebugMessenger(self: *HelloTriangleApplication) !void {
        if (!enable_validation_layers) return;

        const create_info = vk.VkDebugUtilsMessengerCreateInfoEXT{
            .sType = vk.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .messageSeverity = vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType = vk.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT,
            .pfnUserCallback = debugCallback,
        };

        const create_fn: vk.PFN_vkCreateDebugUtilsMessengerEXT = @ptrCast(
            vk.vkGetInstanceProcAddr(self.instance, "vkCreateDebugUtilsMessengerEXT"),
        );

        const func = create_fn orelse {
            std.log.err("vkCreateDebugUtilsMessengerEXT is not available", .{});
            return error.ExtensionNotPresent;
        };

        const result = func(self.instance, &create_info, null, &self.debug_messenger);
        if (result != vk.VK_SUCCESS) {
            std.log.err("Failed to set up debug messenger (VkResult = {d})", .{result});
            return error.DebugMessengerCreationFailed;
        }

        std.log.debug("Debug messenger set up", .{});
    }

    fn destroyDebugMessenger(self: *HelloTriangleApplication) void {
        if (self.debug_messenger == null) return;

        const destroy_fn: vk.PFN_vkDestroyDebugUtilsMessengerEXT = @ptrCast(
            vk.vkGetInstanceProcAddr(self.instance, "vkDestroyDebugUtilsMessengerEXT"),
        );

        if (destroy_fn) |func| {
            func(self.instance, self.debug_messenger, null);
        }
    }

    // +------------------+
    // |  Window Surface  |
    // +------------------+

    fn createSurface(self: *HelloTriangleApplication) !void {
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

    fn pickPhysicalDevice(self: *HelloTriangleApplication) !void {
        var device_count: u32 = 0;
        {
            const result = vk.vkEnumeratePhysicalDevices(self.instance, &device_count, null);
            if (result != vk.VK_SUCCESS) {
                std.log.err("vkEnumeratePhysicalDevices (count) failed (VkResult = {d})", .{result});
                return error.EnumerationFailed;
            }
        }

        if (device_count == 0) {
            return error.NoGpuWithVulkanSupport;
        }

        std.log.debug("Found {d} Vulkan-capable GPU(s)", .{device_count});

        const physical_devices = try self.allocator.alloc(vk.VkPhysicalDevice, device_count);
        defer self.allocator.free(physical_devices);

        {
            const result = vk.vkEnumeratePhysicalDevices(self.instance, &device_count, physical_devices.ptr);
            if (result != vk.VK_SUCCESS) {
                std.log.err("vkEnumeratePhysicalDevices (fill) failed (VkResult = {d})", .{result});
                return error.EnumerationFailed;
            }
        }

        for (physical_devices) |candidate| {
            if (try self.isDeviceSuitable(candidate)) {
                self.physical_device = candidate;
                break;
            }
        }

        if (self.physical_device == null) return error.NoSuitableGpu;

        var properties: vk.VkPhysicalDeviceProperties = undefined;
        vk.vkGetPhysicalDeviceProperties(self.physical_device, &properties);
        std.log.info("selected physical device: {s}", .{std.mem.sliceTo(&properties.deviceName, 0)});
    }

    fn isDeviceSuitable(self: *HelloTriangleApplication, physical_device: vk.VkPhysicalDevice) !bool {
        var properties: vk.VkPhysicalDeviceProperties = undefined;
        vk.vkGetPhysicalDeviceProperties(physical_device, &properties);
        var features: vk.VkPhysicalDeviceFeatures = undefined;
        vk.vkGetPhysicalDeviceFeatures(physical_device, &features);

        const device_name = std.mem.sliceTo(&properties.deviceName, 0);

        const supports_vulkan_1_3 = properties.apiVersion >= vk.VK_API_VERSION_1_3;

        var family_count: u32 = 0;
        vk.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, null);

        const families = try self.allocator.alloc(vk.VkQueueFamilyProperties, family_count);
        defer self.allocator.free(families);
        vk.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, families.ptr);

        const supports_graphics = for (families) |family| {
            if ((family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) != 0) break true;
        } else false;

        const supports_all_extensions = try self.checkDeviceExtensionSupport(physical_device);

        const supports_required_features = self.checkRequiredFeatures(physical_device);

        const is_discrete_gpu = properties.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU;
        const has_geometry_shader = features.geometryShader == vk.VK_TRUE;

        const suitable = supports_vulkan_1_3 and
            supports_graphics and
            supports_all_extensions and
            supports_required_features and
            is_discrete_gpu and
            has_geometry_shader;

        if (!suitable) {
            std.log.debug("Rejected '{s}': api_1_3={}, graphics={}, extensions={}, features={}, discrete={}, geometry={}", .{ device_name, supports_vulkan_1_3, supports_graphics, supports_all_extensions, supports_required_features, is_discrete_gpu, has_geometry_shader });
        }

        return suitable;
    }

    fn checkDeviceExtensionSupport(self: *HelloTriangleApplication, physical_device: vk.VkPhysicalDevice) !bool {
        var extension_count: u32 = 0;
        {
            const result = vk.vkEnumerateDeviceExtensionProperties(physical_device, null, &extension_count, null);
            if (result != vk.VK_SUCCESS) {
                std.log.err("vkEnumerateDeviceExtensionProperties (count) failed (VkResult = {d})", .{result});
                return error.EnumerationFailed;
            }
        }

        const available = try self.allocator.alloc(vk.VkExtensionProperties, extension_count);
        defer self.allocator.free(available);
        {
            const result = vk.vkEnumerateDeviceExtensionProperties(physical_device, null, &extension_count, available.ptr);
            if (result != vk.VK_SUCCESS) {
                std.log.err("vkEnumerateDeviceExtensionProperties (fill) failed (VkResult = {d})", .{result});
                return error.EnumerationFailed;
            }
        }

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

    fn checkRequiredFeatures(self: *HelloTriangleApplication, physical_device: vk.VkPhysicalDevice) bool {
        _ = self;

        var extended_dynamic_state: vk.VkPhysicalDeviceExtendedDynamicStateFeaturesEXT = .{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_FEATURES_EXT,
            .pNext = null,
            .extendedDynamicState = vk.VK_FALSE,
        };
        var vulkan_1_3_features: vk.VkPhysicalDeviceVulkan13Features = .{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
            .pNext = &extended_dynamic_state,
            .dynamicRendering = vk.VK_FALSE,
        };
        var vulkan_1_1_features: vk.VkPhysicalDeviceVulkan11Features = .{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
            .pNext = &vulkan_1_3_features,
            .shaderDrawParameters = vk.VK_FALSE,
        };
        var features2: vk.VkPhysicalDeviceFeatures2 = .{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
            .pNext = &vulkan_1_1_features,
            .features = std.mem.zeroes(vk.VkPhysicalDeviceFeatures),
        };

        vk.vkGetPhysicalDeviceFeatures2(physical_device, &features2);

        return vulkan_1_1_features.shaderDrawParameters == vk.VK_TRUE and
            vulkan_1_3_features.dynamicRendering == vk.VK_TRUE and
            extended_dynamic_state.extendedDynamicState == vk.VK_TRUE;
    }

    // +----------------------------+
    // |  Logical Device Selection  |
    // +----------------------------+

    fn createLogicalDevice(self: *HelloTriangleApplication) !void {
        var family_count: u32 = 0;
        vk.vkGetPhysicalDeviceQueueFamilyProperties(self.physical_device, &family_count, null);

        const families = try self.allocator.alloc(vk.VkQueueFamilyProperties, family_count);
        defer self.allocator.free(families);
        vk.vkGetPhysicalDeviceQueueFamilyProperties(self.physical_device, &family_count, families.ptr);
        std.log.debug("Device has {d} queue family(ies)", .{family_count});

        self.graphics_family = for (families, 0..) |family, i| {
            if ((family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) == 0) continue;

            var supports_present: vk.VkBool32 = vk.VK_FALSE;
            {
                const result = vk.vkGetPhysicalDeviceSurfaceSupportKHR(
                    self.physical_device,
                    @intCast(i),
                    self.surface,
                    &supports_present,
                );
                if (result != vk.VK_SUCCESS) {
                    std.log.err("vkGetPhysicalDeviceSurfaceSupportKHR failed (VkResult = {d})", .{result});
                    return error.SurfaceSupportQueryFailed;
                }
            }

            if (supports_present == vk.VK_TRUE) break @intCast(i);
        } else return error.NoGraphicsPresentQueueFamily;

        std.log.debug("Graphics queue family index: {d}", .{self.graphics_family});

        const queue_priorities = [_]f32{0.5};
        const device_queue_create_info = vk.VkDeviceQueueCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = self.graphics_family,
            .queueCount = 1,
            .pQueuePriorities = &queue_priorities,
        };

        var extended_dynamic_state_features: vk.VkPhysicalDeviceExtendedDynamicStateFeaturesEXT = .{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_FEATURES_EXT,
            .pNext = null,
            .extendedDynamicState = vk.VK_TRUE,
        };
        var vulkan_1_3_features: vk.VkPhysicalDeviceVulkan13Features = .{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
            .pNext = &extended_dynamic_state_features,
            .dynamicRendering = vk.VK_TRUE,
        };
        var vulkan_1_1_features: vk.VkPhysicalDeviceVulkan11Features = .{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
            .pNext = &vulkan_1_3_features,
            .shaderDrawParameters = vk.VK_TRUE,
        };
        var features2: vk.VkPhysicalDeviceFeatures2 = .{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
            .pNext = &vulkan_1_1_features,
            .features = std.mem.zeroes(vk.VkPhysicalDeviceFeatures),
        };

        const device_create_info = vk.VkDeviceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = @ptrCast(&features2),
            .flags = 0,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &[_]vk.VkDeviceQueueCreateInfo{device_queue_create_info},
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = @intCast(required_device_extensions.len),
            .ppEnabledExtensionNames = &required_device_extensions,
            .pEnabledFeatures = null,
        };

        {
            const result = vk.vkCreateDevice(self.physical_device, &device_create_info, null, &self.device);
            if (result != vk.VK_SUCCESS) {
                std.log.err("vkCreateDevice failed (VkResult = {d})", .{result});
                return error.DeviceCreationFailed;
            }
        }

        vk.vkGetDeviceQueue(self.device, self.graphics_family, 0, &self.graphics_queue);
        std.log.info("Logical device created successfully", .{});
    }

    // +--------------+
    // |  Swap Chain  |
    // +--------------+

    fn querySurfaceCapabilities(self: *HelloTriangleApplication) !vk.VkSurfaceCapabilitiesKHR {
        var capabilities: vk.VkSurfaceCapabilitiesKHR = undefined;

        const result = vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
            self.physical_device,
            self.surface,
            &capabilities,
        );
        if (result != vk.VK_SUCCESS) {
            return error.FailedToQuerySurfaceCapabilities;
        }

        return capabilities;
    }

    fn querySurfaceFormats(self: *HelloTriangleApplication) ![]vk.VkSurfaceFormatKHR {
        var format_count: u32 = 0;

        var result = vk.vkGetPhysicalDeviceSurfaceFormatsKHR(
            self.physical_device,
            self.surface,
            &format_count,
            null,
        );
        if (result != vk.VK_SUCCESS) {
            return error.FailedToQuerySurfaceFormats;
        }

        if (format_count == 0) {
            return error.NoSurfaceFormats;
        }

        const formats = try self.allocator.alloc(
            vk.VkSurfaceFormatKHR,
            format_count,
        );
        errdefer self.allocator.free(formats);

        result = vk.vkGetPhysicalDeviceSurfaceFormatsKHR(
            self.physical_device,
            self.surface,
            &format_count,
            formats.ptr,
        );
        if (result != vk.VK_SUCCESS) {
            return error.FailedToQuerySurfaceFormats;
        }

        return formats;
    }

    fn queryPresentModes(self: *HelloTriangleApplication) ![]vk.VkPresentModeKHR {
        var mode_count: u32 = 0;

        var result = vk.vkGetPhysicalDeviceSurfacePresentModesKHR(
            self.physical_device,
            self.surface,
            &mode_count,
            null,
        );
        if (result != vk.VK_SUCCESS) {
            return error.FailedToQueryPresentModes;
        }

        if (mode_count == 0) {
            return error.NoPresentModes;
        }

        const modes = try self.allocator.alloc(
            vk.VkPresentModeKHR,
            mode_count,
        );
        errdefer self.allocator.free(modes);

        result = vk.vkGetPhysicalDeviceSurfacePresentModesKHR(
            self.physical_device,
            self.surface,
            &mode_count,
            modes.ptr,
        );
        if (result != vk.VK_SUCCESS) {
            return error.FailedToQueryPresentModes;
        }

        return modes;
    }

    fn chooseSwapExtent(self: *HelloTriangleApplication, capabilities: vk.VkSurfaceCapabilitiesKHR) !vk.VkExtent2D {
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

    fn createSwapChain(self: *HelloTriangleApplication) !void {
        const capabilities = try self.querySurfaceCapabilities();

        const formats = try self.querySurfaceFormats();
        defer self.allocator.free(formats);

        const present_modes = try self.queryPresentModes();
        defer self.allocator.free(present_modes);

        self.swap_chain_surface_format = chooseSwapSurfaceFormat(formats);

        const present_mode = try chooseSwapPresentMode(present_modes);
        self.swap_chain_extent = try self.chooseSwapExtent(capabilities);

        const image_count = chooseSwapMinImageCount(capabilities);

        const create_info = vk.VkSwapchainCreateInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = self.swap_chain_surface_format.format,
            .imageColorSpace = self.swap_chain_surface_format.colorSpace,
            .imageExtent = self.swap_chain_extent,
            .imageArrayLayers = 1,
            .imageUsage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .preTransform = capabilities.currentTransform,
            .compositeAlpha = vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = present_mode,
            .clipped = vk.VK_TRUE,
            .oldSwapchain = null,
        };

        var result = vk.vkCreateSwapchainKHR(
            self.device,
            &create_info,
            null,
            &self.swap_chain,
        );
        if (result != vk.VK_SUCCESS) {
            return error.FailedToCreateSwapchain;
        }

        errdefer {
            vk.vkDestroySwapchainKHR(self.device, self.swap_chain, null);
            self.swap_chain = null;
        }

        var actual_image_count: u32 = 0;

        result = vk.vkGetSwapchainImagesKHR(
            self.device,
            self.swap_chain,
            &actual_image_count,
            null,
        );
        if (result != vk.VK_SUCCESS) {
            return error.FailedToGetSwapchainImages;
        }

        if (actual_image_count == 0) {
            return error.NoSwapchainImages;
        }

        self.swap_chain_images = try self.allocator.alloc(
            vk.VkImage,
            actual_image_count,
        );

        errdefer {
            self.allocator.free(self.swap_chain_images);
            self.swap_chain_images = &.{};
        }

        result = vk.vkGetSwapchainImagesKHR(
            self.device,
            self.swap_chain,
            &actual_image_count,
            self.swap_chain_images.ptr,
        );
        if (result != vk.VK_SUCCESS) {
            return error.FailedToGetSwapchainImages;
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

    fn createImageViews(self: *HelloTriangleApplication) !void {
        if (self.swap_chain_images.len == 0) {
            return error.NoSwapChainImages;
        }

        if (self.swap_chain_image_views.len != 0) {
            return error.ImageViewsAlreadyCreated;
        }

        const image_views = try self.allocator.alloc(
            vk.VkImageView,
            self.swap_chain_images.len,
        );

        var created_count: usize = 0;

        errdefer {
            for (image_views[0..created_count]) |image_view| {
                vk.vkDestroyImageView(self.device, image_view, null);
            }

            self.allocator.free(image_views);
        }

        var image_view_create_info = vk.VkImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = null,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = self.swap_chain_surface_format.format,
            .components = .{
                .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        for (self.swap_chain_images, 0..) |image, index| {
            image_view_create_info.image = image;

            const result = vk.vkCreateImageView(
                self.device,
                &image_view_create_info,
                null,
                &image_views[index],
            );

            if (result != vk.VK_SUCCESS) {
                std.log.err("Failed to create image view for swap-chain image {d}", .{
                    index,
                });
                return error.FailedToCreateImageView;
            }

            created_count += 1;
        }

        self.swap_chain_image_views = image_views;

        std.log.debug("Created {d} swap-chain image views", .{
            self.swap_chain_image_views.len,
        });
    }

    fn destroyImageViews(self: *HelloTriangleApplication) void {
        for (self.swap_chain_image_views) |image_view| {
            vk.vkDestroyImageView(self.device, image_view, null);
        }

        if (self.swap_chain_image_views.len != 0) {
            self.allocator.free(self.swap_chain_image_views);
        }

        self.swap_chain_image_views = &.{};
    }

    // +---------------------+
    // |  Graphics Pipeline  |
    // +---------------------+

    fn createPipelineLayout(self: *HelloTriangleApplication) !void {
        if (self.device == null) {
            return error.DeviceNotCreated;
        }

        if (self.pipeline_layout != null) {
            return error.PipelineLayoutAlreadyCreated;
        }

        const create_info = vk.VkPipelineLayoutCreateInfo{
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
            &create_info,
            null,
            &self.pipeline_layout,
        );

        if (result != vk.VK_SUCCESS) {
            std.log.err("Failed to create Vulkan pipeline layout", .{});
            return error.FailedToCreatePipelineLayout;
        }

        std.log.debug("Created Vulkan pipeline layout", .{});
    }

    fn createGraphicsPipeline(self: *HelloTriangleApplication) !void {
        if (self.device == null) {
            return error.DeviceNotCreated;
        }

        if (self.shader_module == null) {
            return error.ShaderModuleNotCreated;
        }

        if (self.pipeline_layout == null) {
            return error.PipelineLayoutNotCreated;
        }

        if (self.graphics_pipeline != null) {
            return error.GraphicsPipelineAlreadyCreated;
        }

        const shader_stages = [_]vk.VkPipelineShaderStageCreateInfo{
            .{
                .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .module = self.shader_module,
                .pName = "vertMain",
                .pSpecializationInfo = null,
            },
            .{
                .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
                .module = self.shader_module,
                .pName = "fragMain",
                .pSpecializationInfo = null,
            },
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

        const rasterizer = vk.VkPipelineRasterizationStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthClampEnable = vk.VK_FALSE,
            .rasterizerDiscardEnable = vk.VK_FALSE,
            .polygonMode = vk.VK_POLYGON_MODE_FILL,
            .cullMode = vk.VK_CULL_MODE_BACK_BIT,
            .frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE,
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

        const color_blend_attachment = vk.VkPipelineColorBlendAttachmentState{
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

        var color_format = self.swap_chain_surface_format.format;

        const rendering_info = vk.VkPipelineRenderingCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
            .pNext = null,
            .viewMask = 0,
            .colorAttachmentCount = 1,
            .pColorAttachmentFormats = &color_format,
            .depthAttachmentFormat = vk.VK_FORMAT_UNDEFINED,
            .stencilAttachmentFormat = vk.VK_FORMAT_UNDEFINED,
        };

        const pipeline_create_info = vk.VkGraphicsPipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = &rendering_info,
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
            std.log.err("Failed to create Vulkan graphics pipeline", .{});
            return error.FailedToCreateGraphicsPipeline;
        }

        std.log.info("Created Vulkan graphics pipeline", .{});
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

    fn destroyPipelineLayout(self: *HelloTriangleApplication) void {
        if (self.pipeline_layout != null) {
            vk.vkDestroyPipelineLayout(
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

    fn readShaderCode(
        self: *HelloTriangleApplication,
        path: []const u8,
    ) ![]u32 {
        const io = std.Io.Threaded.global_single_threaded.io();

        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        const file_stat = try file.stat(io);
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
        const bytes_read = try file.readPositionalAll(io, bytes, 0);

        if (bytes_read != byte_count) {
            return error.ShaderFileTruncated;
        }

        return words;
    }

    fn createShaderModule(self: *HelloTriangleApplication, code: []const u32) !vk.VkShaderModule {
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

    fn createShaderModules(self: *HelloTriangleApplication) !void {
        const shader_code = try self.readShaderCode("shaders/slang.spv");
        defer self.allocator.free(shader_code);

        self.shader_module = try self.createShaderModule(shader_code);

        std.log.debug("Created Vulkan shader module", .{});
    }

    fn makeVertexShaderStage(self: *HelloTriangleApplication) !vk.VkPipelineShaderStageCreateInfo {
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

    fn makeFragmentShaderStage(self: *HelloTriangleApplication) !vk.VkPipelineShaderStageCreateInfo {
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

    fn createShaderStages(self: *HelloTriangleApplication) ![2]vk.VkPipelineShaderStageCreateInfo {
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

    // +------------------+
    // |  Command Buffer  |
    // +------------------+

    fn createCommandPool(self: *HelloTriangleApplication) !void {
        if (self.device == null) {
            return error.DeviceNotCreated;
        }

        if (self.command_pool != null) {
            return error.CommandPoolAlreadyCreated;
        }

        const pool_info = vk.VkCommandPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.graphics_family,
        };

        const result = vk.vkCreateCommandPool(
            self.device,
            &pool_info,
            null,
            &self.command_pool,
        );

        if (result != vk.VK_SUCCESS) {
            std.log.err("Failed to create command pool", .{});
            return error.FailedToCreateCommandPool;
        }

        std.log.debug("Created Vulkan command pool", .{});
    }

    fn createCommandBuffer(self: *HelloTriangleApplication) !void {
        if (self.device == null) {
            return error.DeviceNotCreated;
        }

        if (self.command_pool == null) {
            return error.CommandPoolNotCreated;
        }

        if (self.command_buffer != null) {
            return error.CommandBufferAlreadyCreated;
        }

        const alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };

        const result = vk.vkAllocateCommandBuffers(
            self.device,
            &alloc_info,
            &self.command_buffer,
        );

        if (result != vk.VK_SUCCESS) {
            std.log.err("Failed to allocate command buffer", .{});
            return error.FailedToAllocateCommandBuffer;
        }

        std.log.debug("Allocated primary command buffer", .{});
    }

    fn transitionImageLayout(
        self: *HelloTriangleApplication,
        image_index: u32,
        old_layout: vk.VkImageLayout,
        new_layout: vk.VkImageLayout,
        src_access_mask: vk.VkAccessFlags2,
        dst_access_mask: vk.VkAccessFlags2,
        src_stage_mask: vk.VkPipelineStageFlags2,
        dst_stage_mask: vk.VkPipelineStageFlags2,
    ) !void {
        if (self.command_buffer == null) {
            return error.CommandBufferNotCreated;
        }

        const index: usize = @intCast(image_index);

        if (index >= self.swap_chain_images.len) {
            return error.SwapChainImageIndexOutOfRange;
        }

        const barrier = vk.VkImageMemoryBarrier2{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .pNext = null,
            .srcStageMask = src_stage_mask,
            .srcAccessMask = src_access_mask,
            .dstStageMask = dst_stage_mask,
            .dstAccessMask = dst_access_mask,
            .oldLayout = old_layout,
            .newLayout = new_layout,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.swap_chain_images[index],
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        const dependency_info = vk.VkDependencyInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .pNext = null,
            .dependencyFlags = 0,
            .memoryBarrierCount = 0,
            .pMemoryBarriers = null,
            .bufferMemoryBarrierCount = 0,
            .pBufferMemoryBarriers = null,
            .imageMemoryBarrierCount = 1,
            .pImageMemoryBarriers = &barrier,
        };

        vk.vkCmdPipelineBarrier2(
            self.command_buffer,
            &dependency_info,
        );
    }

    fn recordCommandBuffer(self: *HelloTriangleApplication, image_index: u32) !void {
        if (self.command_buffer == null) {
            return error.CommandBufferNotCreated;
        }

        if (self.graphics_pipeline == null) {
            return error.GraphicsPipelineNotCreated;
        }

        const index: usize = @intCast(image_index);

        if (index >= self.swap_chain_images.len) {
            return error.SwapChainImageIndexOutOfRange;
        }

        if (index >= self.swap_chain_image_views.len) {
            return error.SwapChainImageViewIndexOutOfRange;
        }

        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = 0,
            .pInheritanceInfo = null,
        };

        var result = vk.vkBeginCommandBuffer(
            self.command_buffer,
            &begin_info,
        );

        if (result != vk.VK_SUCCESS) {
            std.log.err("Failed to begin command-buffer recording", .{});
            return error.FailedToBeginCommandBuffer;
        }

        errdefer {
            _ = vk.vkEndCommandBuffer(self.command_buffer);
        }

        try self.transitionImageLayout(
            image_index,
            vk.VK_IMAGE_LAYOUT_UNDEFINED,
            vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            0,
            vk.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            0,
            vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        );

        const clear_value = vk.VkClearValue{
            .color = .{
                .float32 = .{ 0.0, 0.0, 0.0, 1.0 },
            },
        };

        const attachment_info = vk.VkRenderingAttachmentInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .pNext = null,
            .imageView = self.swap_chain_image_views[index],
            .imageLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .resolveMode = vk.VK_RESOLVE_MODE_NONE,
            .resolveImageView = null,
            .resolveImageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
            .clearValue = clear_value,
        };

        const rendering_info = vk.VkRenderingInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDERING_INFO,
            .pNext = null,
            .flags = 0,
            .renderArea = .{
                .offset = .{
                    .x = 0,
                    .y = 0,
                },
                .extent = self.swap_chain_extent,
            },
            .layerCount = 1,
            .viewMask = 0,
            .colorAttachmentCount = 1,
            .pColorAttachments = &attachment_info,
            .pDepthAttachment = null,
            .pStencilAttachment = null,
        };

        vk.vkCmdBeginRendering(
            self.command_buffer,
            &rendering_info,
        );

        vk.vkCmdBindPipeline(
            self.command_buffer,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.graphics_pipeline,
        );

        const viewport = vk.VkViewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(self.swap_chain_extent.width),
            .height = @floatFromInt(self.swap_chain_extent.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };

        vk.vkCmdSetViewport(
            self.command_buffer,
            0,
            1,
            &viewport,
        );

        const scissor = vk.VkRect2D{
            .offset = .{
                .x = 0,
                .y = 0,
            },
            .extent = self.swap_chain_extent,
        };

        vk.vkCmdSetScissor(
            self.command_buffer,
            0,
            1,
            &scissor,
        );

        vk.vkCmdDraw(
            self.command_buffer,
            3,
            1,
            0,
            0,
        );

        vk.vkCmdEndRendering(self.command_buffer);

        try self.transitionImageLayout(
            image_index,
            vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            vk.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            0,
            vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            vk.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT,
        );

        result = vk.vkEndCommandBuffer(self.command_buffer);

        if (result != vk.VK_SUCCESS) {
            std.log.err("Failed to finish command-buffer recording", .{});
            return error.FailedToEndCommandBuffer;
        }

        std.log.debug("Recorded command buffer for swap-chain image {d}", .{
            image_index,
        });
    }

    fn destroyCommandResources(self: *HelloTriangleApplication) void {
        if (self.command_buffer != null) {
            if (self.device != null and self.command_pool != null) {
                vk.vkFreeCommandBuffers(
                    self.device,
                    self.command_pool,
                    1,
                    &self.command_buffer,
                );
            }

            self.command_buffer = null;
        }

        if (self.command_pool != null and self.device != null) {
            vk.vkDestroyCommandPool(
                self.device,
                self.command_pool,
                null,
            );

            self.command_pool = null;
        }
    }
};

// +--------+
// |  Main  |
// +--------+

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = HelloTriangleApplication{ .allocator = allocator };
    app.run() catch |err| {
        std.log.err("Error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

// +----------------+
// | Free Functions |
// +----------------+

fn debugCallback(
    message_severity: vk.VkDebugUtilsMessageSeverityFlagBitsEXT,
    message_type: vk.VkDebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const vk.VkDebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(.c) vk.VkBool32 {
    _ = message_severity;
    _ = message_type;
    _ = user_data;

    if (callback_data) |data| {
        std.log.warn("validation layer: {s}", .{data.pMessage});
    }

    return vk.VK_FALSE;
}

fn chooseSwapSurfaceFormat(available_formats: []const vk.VkSurfaceFormatKHR) vk.VkSurfaceFormatKHR {
    for (available_formats) |format| {
        if (format.format == vk.VK_FORMAT_B8G8R8A8_SRGB and
            format.colorSpace == vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
        {
            return format;
        }
    }

    return available_formats[0];
}

fn chooseSwapPresentMode(available_modes: []const vk.VkPresentModeKHR) !vk.VkPresentModeKHR {
    var has_fifo = false;

    for (available_modes) |mode| {
        if (mode == vk.VK_PRESENT_MODE_MAILBOX_KHR) {
            return vk.VK_PRESENT_MODE_MAILBOX_KHR;
        }

        if (mode == vk.VK_PRESENT_MODE_FIFO_KHR) {
            has_fifo = true;
        }
    }

    if (has_fifo) {
        return vk.VK_PRESENT_MODE_FIFO_KHR;
    }

    return error.NoFifoPresentMode;
}

fn chooseSwapMinImageCount(capabilities: vk.VkSurfaceCapabilitiesKHR) u32 {
    var image_count = @max(3, capabilities.minImageCount);

    if (capabilities.maxImageCount != 0 and
        image_count > capabilities.maxImageCount)
    {
        image_count = capabilities.maxImageCount;
    }

    return image_count;
}
