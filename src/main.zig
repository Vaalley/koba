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
