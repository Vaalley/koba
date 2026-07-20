const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl3");
const vk = @import("vulkan");

const validation_layers = [_][*c]const u8{"VK_LAYER_KHRONOS_validation"};
const enable_validation_layers = builtin.mode == .Debug;
const required_device_extensions = [_][*:0]const u8{
    "VK_KHR_swapchain",
};
const max_frames_in_flight: u32 = 2;

const App = struct {
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
    framebuffer_resized: bool = false,
    shader_module: vk.VkShaderModule = null,
    pipeline_layout: vk.VkPipelineLayout = null,
    graphics_pipeline: vk.VkPipeline = null,
    command_pool: vk.VkCommandPool = null,
    command_buffers: []vk.VkCommandBuffer = &.{},
    present_complete_semaphores: []vk.VkSemaphore = &.{},
    render_finished_semaphores: []vk.VkSemaphore = &.{},
    in_flight_fences: []vk.VkFence = &.{},
    frame_index: u32 = 0,

    // +-------------+
    // |  Lifecycle  |
    // +-------------+

    pub fn run(self: *App) !void {
        try self.initWindow();
        defer self.cleanup();

        try self.initVulkan();
        try self.mainLoop();
    }

    fn initWindow(self: *App) !void {
        if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) {
            std.log.err("SDL Initialization Failed: {s}", .{sdl.SDL_GetError()});
            return error.SDLInitFailed;
        }

        self.window = sdl.SDL_CreateWindow(
            "SDL3 + Vulkan",
            @intCast(WIDTH),
            @intCast(HEIGHT),
            sdl.SDL_WINDOW_VULKAN | sdl.SDL_WINDOW_RESIZABLE,
        ) orelse {
            std.log.err("Window Creation Failed: {s}", .{sdl.SDL_GetError()});
            return error.WindowCreationFailed;
        };
    }

    fn initVulkan(self: *App) !void {
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

        std.log.debug("Creating command buffers...", .{});
        try self.createCommandBuffers();

        std.log.debug("Creating synchronization objects...", .{});
        try self.createSyncObjects();

        std.log.info("Vulkan initialization complete", .{});
    }

    fn pollEvents(self: *App) bool {
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

    fn mainLoop(self: *App) !void {
        var running = true;
        var fps = FpsCounter.init();

        while (running) {
            running = self.pollEvents();
            if (!running) break;

            try self.drawFrame();
            fps.tick(self.window);
        }

        if (self.device != null) {
            try vkCheck(vk.vkDeviceWaitIdle(self.device), error.FailedToWaitForDeviceIdle);
        }
    }

    fn cleanup(self: *App) void {
        std.log.debug("Cleaning up...", .{});

        self.destroySyncObjects();
        self.destroyCommandBuffers();

        if (self.command_pool != null and self.device != null) {
            std.log.debug("Destroying command pool", .{});
            vk.vkDestroyCommandPool(
                self.device,
                self.command_pool,
                null,
            );
            self.command_pool = null;
        }

        self.destroyGraphicsPipeline();
        self.destroyPipelineLayout();
        self.destroyShaderModule();

        self.cleanupSwapChain();

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

    fn createInstance(self: *App) !void {
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

        try vkCheck(vk.vkCreateInstance(&create_info, null, &self.instance), error.InstanceCreationFailed);

        std.log.info("Vulkan instance created (API version 1.4)", .{});
    }

    fn checkValidationLayerSupport(self: *App) !bool {
        const available_layers = try vkEnumerate(
            self.allocator,
            vk.VkLayerProperties,
            vk.vkEnumerateInstanceLayerProperties,
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

    fn checkExtensionSupport(self: *App, required_extensions: []const [*c]const u8) !void {
        const available_extensions = try vkEnumerate(
            self.allocator,
            vk.VkExtensionProperties,
            vk.vkEnumerateInstanceExtensionProperties,
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

    fn getRequiredExtensions(self: *App) ![][*c]const u8 {
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

    fn setupDebugMessenger(self: *App) !void {
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

        try vkCheck(
            func(self.instance, &create_info, null, &self.debug_messenger),
            error.DebugMessengerCreationFailed,
        );

        std.log.debug("Debug messenger set up", .{});
    }

    fn destroyDebugMessenger(self: *App) void {
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

    fn createSurface(self: *App) !void {
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

    fn pickPhysicalDevice(self: *App) !void {
        const physical_devices = try vkEnumerate(
            self.allocator,
            vk.VkPhysicalDevice,
            vk.vkEnumeratePhysicalDevices,
            .{self.instance},
            error.EnumerationFailed,
        );
        defer self.allocator.free(physical_devices);

        if (physical_devices.len == 0) {
            return error.NoGpuWithVulkanSupport;
        }

        std.log.debug("Found {d} Vulkan-capable GPU(s)", .{physical_devices.len});

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

    fn isDeviceSuitable(self: *App, physical_device: vk.VkPhysicalDevice) !bool {
        var properties: vk.VkPhysicalDeviceProperties = undefined;
        vk.vkGetPhysicalDeviceProperties(physical_device, &properties);
        var features: vk.VkPhysicalDeviceFeatures = undefined;
        vk.vkGetPhysicalDeviceFeatures(physical_device, &features);

        const device_name = std.mem.sliceTo(&properties.deviceName, 0);

        const supports_vulkan_1_3 = properties.apiVersion >= vk.VK_API_VERSION_1_3;

        const families = try vkEnumerate(
            self.allocator,
            vk.VkQueueFamilyProperties,
            vk.vkGetPhysicalDeviceQueueFamilyProperties,
            .{physical_device},
            error.EnumerationFailed,
        );
        defer self.allocator.free(families);

        const supports_graphics = for (families) |family| {
            if ((family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) != 0) break true;
        } else false;

        const supports_all_extensions = try self.checkDeviceExtensionSupport(physical_device);

        const supports_required_features = checkRequiredFeatures(physical_device);

        // const is_discrete_gpu = properties.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU;
        const has_geometry_shader = features.geometryShader == vk.VK_TRUE;

        const suitable = supports_vulkan_1_3 and
            supports_graphics and
            supports_all_extensions and
            supports_required_features and
            // is_discrete_gpu and
            has_geometry_shader;

        if (!suitable) {
            std.log.debug("Rejected '{s}': api_1_3={}, graphics={}, extensions={}, features={}, geometry={}", .{ device_name, supports_vulkan_1_3, supports_graphics, supports_all_extensions, supports_required_features, has_geometry_shader });
        }

        return suitable;
    }

    fn checkDeviceExtensionSupport(self: *App, physical_device: vk.VkPhysicalDevice) !bool {
        const available = try vkEnumerate(
            self.allocator,
            vk.VkExtensionProperties,
            vk.vkEnumerateDeviceExtensionProperties,
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

    fn createLogicalDevice(self: *App) !void {
        const families = try vkEnumerate(
            self.allocator,
            vk.VkQueueFamilyProperties,
            vk.vkGetPhysicalDeviceQueueFamilyProperties,
            .{self.physical_device},
            error.EnumerationFailed,
        );
        defer self.allocator.free(families);
        std.log.debug("Device has {d} queue family(ies)", .{families.len});

        self.graphics_family = for (families, 0..) |family, i| {
            if ((family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) == 0) continue;

            var supports_present: vk.VkBool32 = vk.VK_FALSE;
            try vkCheck(
                vk.vkGetPhysicalDeviceSurfaceSupportKHR(
                    self.physical_device,
                    @intCast(i),
                    self.surface,
                    &supports_present,
                ),
                error.SurfaceSupportQueryFailed,
            );

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
            .synchronization2 = vk.VK_TRUE,
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

        try vkCheck(
            vk.vkCreateDevice(self.physical_device, &device_create_info, null, &self.device),
            error.DeviceCreationFailed,
        );

        vk.vkGetDeviceQueue(self.device, self.graphics_family, 0, &self.graphics_queue);
        std.log.info("Logical device created successfully", .{});
    }

    // +--------------+
    // |  Swap Chain  |
    // +--------------+

    fn querySurfaceCapabilities(self: *App) !vk.VkSurfaceCapabilitiesKHR {
        var capabilities: vk.VkSurfaceCapabilitiesKHR = undefined;

        try vkCheck(
            vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
                self.physical_device,
                self.surface,
                &capabilities,
            ),
            error.FailedToQuerySurfaceCapabilities,
        );

        return capabilities;
    }

    fn querySurfaceFormats(self: *App) ![]vk.VkSurfaceFormatKHR {
        const formats = try vkEnumerate(
            self.allocator,
            vk.VkSurfaceFormatKHR,
            vk.vkGetPhysicalDeviceSurfaceFormatsKHR,
            .{ self.physical_device, self.surface },
            error.FailedToQuerySurfaceFormats,
        );
        errdefer self.allocator.free(formats);

        if (formats.len == 0) {
            return error.NoSurfaceFormats;
        }

        return formats;
    }

    fn queryPresentModes(self: *App) ![]vk.VkPresentModeKHR {
        const modes = try vkEnumerate(
            self.allocator,
            vk.VkPresentModeKHR,
            vk.vkGetPhysicalDeviceSurfacePresentModesKHR,
            .{ self.physical_device, self.surface },
            error.FailedToQueryPresentModes,
        );
        errdefer self.allocator.free(modes);

        if (modes.len == 0) {
            return error.NoPresentModes;
        }

        return modes;
    }

    fn chooseSwapExtent(self: *App, capabilities: vk.VkSurfaceCapabilitiesKHR) !vk.VkExtent2D {
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

    fn createSwapChain(self: *App) !void {
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

        try vkCheck(vk.vkCreateSwapchainKHR(self.device, &create_info, null, &self.swap_chain), error.FailedToCreateSwapchain);

        errdefer {
            vk.vkDestroySwapchainKHR(self.device, self.swap_chain, null);
            self.swap_chain = null;
        }

        self.swap_chain_images = try vkEnumerate(
            self.allocator,
            vk.VkImage,
            vk.vkGetSwapchainImagesKHR,
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

    fn createImageViews(self: *App) !void {
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

        var created_count: u32 = 0;

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

            try vkCheck(
                vk.vkCreateImageView(self.device, &image_view_create_info, null, &image_views[index]),
                error.FailedToCreateImageView,
            );

            created_count += 1;
        }

        self.swap_chain_image_views = image_views;

        std.log.debug("Created {d} swap-chain image views", .{
            self.swap_chain_image_views.len,
        });
    }

    fn destroyImageViews(self: *App) void {
        for (self.swap_chain_image_views) |image_view| {
            vk.vkDestroyImageView(self.device, image_view, null);
        }

        if (self.swap_chain_image_views.len != 0) {
            self.allocator.free(self.swap_chain_image_views);
        }

        self.swap_chain_image_views = &.{};
    }

    fn cleanupSwapChain(self: *App) void {
        if (self.device != null) {
            for (self.swap_chain_image_views) |image_view| {
                if (image_view != null) {
                    vk.vkDestroyImageView(
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
            vk.vkDestroySwapchainKHR(
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

    fn waitForDrawableSize(self: *App) !void {
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

    fn recreateSwapChain(self: *App) !void {
        if (self.device == null) {
            return error.DeviceNotCreated;
        }

        try self.waitForDrawableSize();

        try vkCheck(vk.vkDeviceWaitIdle(self.device), error.FailedToWaitForDeviceIdle);

        self.cleanupSwapChain();

        try self.createSwapChain();
        errdefer self.cleanupSwapChain();

        try self.createImageViews();

        self.framebuffer_resized = false;
    }

    fn acquireSwapChainImage(self: *App, present_complete_semaphore: vk.VkSemaphore) !?u32 {
        if (self.device == null) {
            return error.DeviceNotCreated;
        }

        if (self.swap_chain == null) {
            return error.SwapChainNotCreated;
        }

        var image_index: u32 = 0;

        const result = vk.vkAcquireNextImageKHR(
            self.device,
            self.swap_chain,
            std.math.maxInt(u64),
            present_complete_semaphore,
            null,
            &image_index,
        );

        if (result == vk.VK_ERROR_OUT_OF_DATE_KHR) {
            try self.recreateSwapChain();
            return null;
        }

        if (result != vk.VK_SUCCESS and result != vk.VK_SUBOPTIMAL_KHR) {
            std.log.err(
                "Failed to acquire a swap-chain image",
                .{},
            );
            return error.FailedToAcquireSwapChainImage;
        }

        if (result == vk.VK_SUBOPTIMAL_KHR) {
            self.framebuffer_resized = true;
        }

        return image_index;
    }

    fn presentSwapChainImage(
        self: *App,
        render_finished_semaphore: vk.VkSemaphore,
        image_index: u32,
    ) !void {
        if (self.swap_chain == null) {
            return error.SwapChainNotCreated;
        }

        var present_info = vk.VkPresentInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &render_finished_semaphore,
            .swapchainCount = 1,
            .pSwapchains = &self.swap_chain,
            .pImageIndices = &image_index,
            .pResults = null,
        };

        const result = vk.vkQueuePresentKHR(
            self.graphics_queue,
            &present_info,
        );

        if (result == vk.VK_ERROR_OUT_OF_DATE_KHR or
            result == vk.VK_SUBOPTIMAL_KHR)
        {
            self.framebuffer_resized = true;
            try self.recreateSwapChain();
            return;
        }

        if (result != vk.VK_SUCCESS) {
            std.log.err(
                "Failed to present the swap-chain image",
                .{},
            );
            return error.FailedToPresentSwapChainImage;
        }

        if (self.framebuffer_resized) {
            try self.recreateSwapChain();
        }
    }

    // +---------------------+
    // |  Graphics Pipeline  |
    // +---------------------+

    fn createPipelineLayout(self: *App) !void {
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

        try vkCheck(vk.vkCreatePipelineLayout(self.device, &create_info, null, &self.pipeline_layout), error.FailedToCreatePipelineLayout);

        std.log.debug("Created Vulkan pipeline layout", .{});
    }

    fn createGraphicsPipeline(self: *App) !void {
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

        try vkCheck(
            vk.vkCreateGraphicsPipelines(
                self.device,
                null,
                1,
                &pipeline_create_info,
                null,
                &self.graphics_pipeline,
            ),
            error.FailedToCreateGraphicsPipeline,
        );

        std.log.info("Created Vulkan graphics pipeline", .{});
    }

    fn destroyGraphicsPipeline(self: *App) void {
        if (self.graphics_pipeline != null) {
            vk.vkDestroyPipeline(
                self.device,
                self.graphics_pipeline,
                null,
            );
            self.graphics_pipeline = null;
        }
    }

    fn destroyPipelineLayout(self: *App) void {
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
        self: *App,
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

    fn createShaderModule(self: *App, code: []const u32) !vk.VkShaderModule {
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

        try vkCheck(vk.vkCreateShaderModule(self.device, &create_info, null, &shader_module), error.FailedToCreateShaderModule);

        return shader_module;
    }

    fn createShaderModules(self: *App) !void {
        const shader_code = try self.readShaderCode("shaders/slang.spv");
        defer self.allocator.free(shader_code);

        self.shader_module = try self.createShaderModule(shader_code);

        std.log.debug("Created Vulkan shader module", .{});
    }

    fn makeVertexShaderStage(self: *App) !vk.VkPipelineShaderStageCreateInfo {
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

    fn makeFragmentShaderStage(self: *App) !vk.VkPipelineShaderStageCreateInfo {
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

    fn createShaderStages(self: *App) ![2]vk.VkPipelineShaderStageCreateInfo {
        return .{
            try self.makeVertexShaderStage(),
            try self.makeFragmentShaderStage(),
        };
    }

    fn destroyShaderModule(self: *App) void {
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

    fn createCommandPool(self: *App) !void {
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

        try vkCheck(vk.vkCreateCommandPool(self.device, &pool_info, null, &self.command_pool), error.FailedToCreateCommandPool);

        std.log.debug("Created Vulkan command pool", .{});
    }

    fn createCommandBuffers(self: *App) !void {
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
            vk.VkCommandBuffer,
            max_frames_in_flight,
        );
        errdefer {
            self.allocator.free(self.command_buffers);
            self.command_buffers = &.{};
        }

        const alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = @intCast(max_frames_in_flight),
        };

        try vkCheck(vk.vkAllocateCommandBuffers(self.device, &alloc_info, self.command_buffers.ptr), error.FailedToAllocateCommandBuffers);

        std.log.debug(
            "Allocated {d} command buffers for frames in flight",
            .{max_frames_in_flight},
        );
    }

    fn transitionImageLayout(
        self: *App,
        command_buffer: vk.VkCommandBuffer,
        image_index: u32,
        old_layout: vk.VkImageLayout,
        new_layout: vk.VkImageLayout,
        src_access_mask: vk.VkAccessFlags2,
        dst_access_mask: vk.VkAccessFlags2,
        src_stage_mask: vk.VkPipelineStageFlags2,
        dst_stage_mask: vk.VkPipelineStageFlags2,
    ) !void {
        const index = image_index;

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
            command_buffer,
            &dependency_info,
        );
    }

    fn recordCommandBuffer(
        self: *App,
        command_buffer: vk.VkCommandBuffer,
        image_index: u32,
    ) !void {
        if (self.graphics_pipeline == null) {
            return error.GraphicsPipelineNotCreated;
        }

        if (image_index >= self.swap_chain_images.len) {
            return error.SwapChainImageIndexOutOfRange;
        }

        if (image_index >= self.swap_chain_image_views.len) {
            return error.SwapChainImageViewIndexOutOfRange;
        }

        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = 0,
            .pInheritanceInfo = null,
        };

        try vkCheck(vk.vkBeginCommandBuffer(command_buffer, &begin_info), error.FailedToBeginCommandBuffer);

        errdefer {
            _ = vk.vkEndCommandBuffer(command_buffer);
        }

        try self.transitionImageLayout(
            command_buffer,
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
            .imageView = self.swap_chain_image_views[image_index],
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
            command_buffer,
            &rendering_info,
        );

        vk.vkCmdBindPipeline(
            command_buffer,
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
            command_buffer,
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
            command_buffer,
            0,
            1,
            &scissor,
        );

        vk.vkCmdDraw(
            command_buffer,
            3,
            1,
            0,
            0,
        );

        vk.vkCmdEndRendering(command_buffer);

        try self.transitionImageLayout(
            command_buffer,
            @intCast(image_index),
            vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            vk.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            0,
            vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            vk.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT,
        );

        try vkCheck(vk.vkEndCommandBuffer(command_buffer), error.FailedToEndCommandBuffer);

        // Uncomment if you want to see this debug message (very spammy)
        // std.log.debug("Recorded command buffer for swap-chain image {d}", .{
        //     image_index,
        // });
    }

    fn destroyCommandBuffers(self: *App) void {
        if (self.device != null and
            self.command_pool != null and
            self.command_buffers.len != 0)
        {
            vk.vkFreeCommandBuffers(
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

    fn createSyncObjects(self: *App) !void {
        if (self.device == null) {
            return error.DeviceNotCreated;
        }

        if (self.swap_chain_images.len == 0) {
            return error.NoSwapChainImages;
        }

        if (self.present_complete_semaphores.len != 0 or
            self.render_finished_semaphores.len != 0 or
            self.in_flight_fences.len != 0)
        {
            return error.SyncObjectsAlreadyCreated;
        }

        self.present_complete_semaphores = try self.allocator.alloc(
            vk.VkSemaphore,
            max_frames_in_flight,
        );
        errdefer {
            self.allocator.free(self.present_complete_semaphores);
            self.present_complete_semaphores = &.{};
        }

        self.render_finished_semaphores = try self.allocator.alloc(
            vk.VkSemaphore,
            self.swap_chain_images.len,
        );
        errdefer {
            self.allocator.free(self.render_finished_semaphores);
            self.render_finished_semaphores = &.{};
        }

        self.in_flight_fences = try self.allocator.alloc(
            vk.VkFence,
            max_frames_in_flight,
        );
        errdefer {
            self.allocator.free(self.in_flight_fences);
            self.in_flight_fences = &.{};
        }

        const semaphore_info = vk.VkSemaphoreCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };

        const fence_info = vk.VkFenceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
        };

        var created_present_complete: u32 = 0;
        errdefer {
            while (created_present_complete > 0) {
                created_present_complete -= 1;
                vk.vkDestroySemaphore(
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
                vk.vkDestroySemaphore(
                    self.device,
                    self.render_finished_semaphores[created_render_finished],
                    null,
                );
            }
        }

        var created_fences: u32 = 0;
        errdefer {
            while (created_fences > 0) {
                created_fences -= 1;
                vk.vkDestroyFence(
                    self.device,
                    self.in_flight_fences[created_fences],
                    null,
                );
            }
        }

        while (created_present_complete < max_frames_in_flight) : (created_present_complete += 1) {
            try vkCheck(
                vk.vkCreateSemaphore(
                    self.device,
                    &semaphore_info,
                    null,
                    &self.present_complete_semaphores[created_present_complete],
                ),
                error.FailedToCreateAcquireSemaphore,
            );
        }

        while (created_render_finished < self.swap_chain_images.len) : (created_render_finished += 1) {
            try vkCheck(
                vk.vkCreateSemaphore(
                    self.device,
                    &semaphore_info,
                    null,
                    &self.render_finished_semaphores[created_render_finished],
                ),
                error.FailedToCreateRenderFinishedSemaphore,
            );
        }

        while (created_fences < max_frames_in_flight) : (created_fences += 1) {
            try vkCheck(
                vk.vkCreateFence(
                    self.device,
                    &fence_info,
                    null,
                    &self.in_flight_fences[created_fences],
                ),
                error.FailedToCreateInFlightFence,
            );
        }

        std.log.debug(
            "Created synchronization objects for {d} frames and {d} swap-chain images",
            .{
                max_frames_in_flight,
                self.swap_chain_images.len,
            },
        );
    }

    fn drawFrame(self: *App) !void {
        if (self.device == null) {
            return error.DeviceNotCreated;
        }

        if (self.graphics_queue == null) {
            return error.GraphicsQueueNotCreated;
        }

        if (self.swap_chain == null) {
            return error.SwapChainNotCreated;
        }

        if (self.command_buffers.len != max_frames_in_flight) {
            return error.CommandBuffersNotReady;
        }

        if (self.present_complete_semaphores.len != max_frames_in_flight) {
            return error.AcquireSemaphoresNotReady;
        }

        if (self.in_flight_fences.len != max_frames_in_flight) {
            return error.InFlightFencesNotReady;
        }

        if (self.render_finished_semaphores.len != self.swap_chain_images.len) {
            return error.RenderFinishedSemaphoresNotReady;
        }

        const frame_index = self.frame_index;

        // 1. Wait for this frame slot's fence (previous use of this slot is done)
        try vkCheck(
            vk.vkWaitForFences(
                self.device,
                1,
                &self.in_flight_fences[frame_index],
                vk.VK_TRUE,
                std.math.maxInt(u64),
            ),
            error.FailedToWaitForInFlightFence,
        );

        // 2. Acquire the next swap-chain image (may trigger recreation)
        const image_index = (try self.acquireSwapChainImage(
            self.present_complete_semaphores[frame_index],
        )) orelse return;

        if (image_index >= self.swap_chain_images.len) {
            return error.AcquiredImageIndexOutOfBounds;
        }

        if (image_index >= self.render_finished_semaphores.len) {
            return error.RenderFinishedSemaphoreIndexOutOfBounds;
        }

        // 3. Reset the fence (AFTER successful acquisition, before submission)
        try vkCheck(vk.vkResetFences(self.device, 1, &self.in_flight_fences[frame_index]), error.FailedToResetInFlightFence);

        // 4. Reset and record the command buffer for this frame slot
        try vkCheck(vk.vkResetCommandBuffer(self.command_buffers[frame_index], 0), error.FailedToResetCommandBuffer);

        try self.recordCommandBuffer(
            self.command_buffers[frame_index],
            image_index,
        );

        // 5. Submit the command buffer
        const wait_stage: vk.VkPipelineStageFlags = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;

        const submit_info = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.present_complete_semaphores[frame_index],
            .pWaitDstStageMask = &wait_stage,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.command_buffers[frame_index],
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &self.render_finished_semaphores[image_index],
        };

        try vkCheck(
            vk.vkQueueSubmit(
                self.graphics_queue,
                1,
                &submit_info,
                self.in_flight_fences[frame_index],
            ),
            error.FailedToSubmitFrame,
        );

        // 6. Present the rendered image (may trigger recreation)
        try self.presentSwapChainImage(
            self.render_finished_semaphores[image_index],
            image_index,
        );

        // 7. Advance to the next frame slot
        self.frame_index =
            (self.frame_index + 1) % max_frames_in_flight;
    }

    fn destroySyncObjects(self: *App) void {
        if (self.device != null) {
            for (self.present_complete_semaphores) |semaphore| {
                if (semaphore != null) {
                    vk.vkDestroySemaphore(
                        self.device,
                        semaphore,
                        null,
                    );
                }
            }

            for (self.render_finished_semaphores) |semaphore| {
                if (semaphore != null) {
                    vk.vkDestroySemaphore(
                        self.device,
                        semaphore,
                        null,
                    );
                }
            }

            for (self.in_flight_fences) |fence| {
                if (fence != null) {
                    vk.vkDestroyFence(
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

// +--------+
// |  Main  |
// +--------+

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = App{ .allocator = allocator };
    app.run() catch |err| {
        std.log.err("Error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

// +---------------+
// |  FPS Counter  |
// +---------------+

const FpsCounter = struct {
    timer: u64,
    frame_count: u32 = 0,

    fn init() FpsCounter {
        return .{ .timer = sdl.SDL_GetTicks() };
    }

    // Updates the window title with FPS/frame-time twice per second.
    fn tick(self: *FpsCounter, window: ?*sdl.SDL_Window) void {
        self.frame_count += 1;

        const now = sdl.SDL_GetTicks();
        const elapsed_ms = now - self.timer;
        if (elapsed_ms < 500) return;

        const fps = @as(f64, @floatFromInt(self.frame_count)) * 1000.0 /
            @as(f64, @floatFromInt(elapsed_ms));
        const avg_frame_time = @as(f64, @floatFromInt(elapsed_ms)) /
            @as(f64, @floatFromInt(self.frame_count));

        var title_buf: [128]u8 = undefined;
        const title = std.fmt.bufPrintZ(
            &title_buf,
            "Koba - FPS: {d:.1} | Frame: {d:.2}ms",
            .{ fps, avg_frame_time },
        ) catch "Koba";

        _ = sdl.SDL_SetWindowTitle(window, title.ptr);

        self.timer = now;
        self.frame_count = 0;
    }
};

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

fn checkRequiredFeatures(physical_device: vk.VkPhysicalDevice) bool {
    var extended_dynamic_state: vk.VkPhysicalDeviceExtendedDynamicStateFeaturesEXT = .{
        .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_FEATURES_EXT,
        .pNext = null,
        .extendedDynamicState = vk.VK_FALSE,
    };
    var vulkan_1_3_features: vk.VkPhysicalDeviceVulkan13Features = .{
        .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        .pNext = &extended_dynamic_state,
        .dynamicRendering = vk.VK_FALSE,
        .synchronization2 = vk.VK_FALSE,
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
        vulkan_1_3_features.synchronization2 == vk.VK_TRUE and
        extended_dynamic_state.extendedDynamicState == vk.VK_TRUE;
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
        // Uncomment to enable immediate mode (no vsync -> no fps cap)
        // if (mode == vk.VK_PRESENT_MODE_IMMEDIATE_KHR) {
        //     return vk.VK_PRESENT_MODE_IMMEDIATE_KHR;
        // }

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

// +------------------+
// |  Vulkan Helpers  |
// +------------------+

fn vkCheck(result: vk.VkResult, err: anytype) @TypeOf(err)!void {
    if (result == vk.VK_SUCCESS) return;

    std.log.err("{s} failed (VkResult = {d})", .{ @errorName(err), result });
    return err;
}

fn vkEnumerate(
    allocator: std.mem.Allocator,
    comptime T: type,
    func: anytype,
    args: anytype,
    err: anytype,
) (std.mem.Allocator.Error || @TypeOf(err))![]T {
    var count: u32 = 0;

    const count_result = @call(.auto, func, args ++ .{ &count, @as([*c]T, null) });
    if (@TypeOf(count_result) != void) try vkCheck(count_result, err);

    const items = try allocator.alloc(T, count);
    errdefer allocator.free(items);

    if (count > 0) {
        const fill_result = @call(.auto, func, args ++ .{ &count, items.ptr });
        if (@TypeOf(fill_result) != void) try vkCheck(fill_result, err);
    }

    return items;
}
