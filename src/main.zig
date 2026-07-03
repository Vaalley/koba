const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl3");
const vk = @import("vulkan");

const validationLayers = [_][*c]const u8{"VK_LAYER_KHRONOS_validation"};
const enableValidationLayers = builtin.mode == .Debug;

const HelloTriangleApplication = struct {
    window: ?*sdl.SDL_Window = null,
    instance: vk.VkInstance = null,
    allocator: std.mem.Allocator,
    debugMessenger: vk.VkDebugUtilsMessengerEXT = null,

    const WIDTH: u32 = 1280;
    const HEIGHT: u32 = 720;

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

    fn createInstance(self: *HelloTriangleApplication) !void {
        if (enableValidationLayers) {
            const supported = try checkValidationLayerSupport(self.allocator);
            if (!supported) {
                std.log.err("Validation layers requested, but not available!", .{});
                return error.ValidationLayersNotSupported;
            }
        }

        const appInfo = vk.VkApplicationInfo{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "Koba",
            .applicationVersion = vk.VK_MAKE_VERSION(1, 0, 0),
            .pEngineName = "No Engine",
            .engineVersion = vk.VK_MAKE_VERSION(1, 0, 0),
            .apiVersion = vk.VK_API_VERSION_1_4,
        };

        const requiredExtensions = try getRequiredExtensions(self.allocator);
        defer self.allocator.free(requiredExtensions);

        try checkExtensionSupport(self.allocator, requiredExtensions);

        const requiredLayers: []const [*c]const u8 =
            if (enableValidationLayers) &validationLayers else &[_][*c]const u8{};

        var createInfo = vk.VkInstanceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &appInfo,
            .enabledExtensionCount = @intCast(requiredExtensions.len),
            .ppEnabledExtensionNames = requiredExtensions.ptr,
            .enabledLayerCount = @intCast(requiredLayers.len),
            .ppEnabledLayerNames = requiredLayers.ptr,
        };

        const result = vk.vkCreateInstance(&createInfo, null, &self.instance);
        if (result != vk.VK_SUCCESS) {
            std.log.err("Failed to create Vulkan instance (VkResult = {d})", .{result});
            return error.InstanceCreationFailed;
        }
    }

    fn initVulkan(self: *HelloTriangleApplication) !void {
        try self.createInstance();
        try self.setupDebugMessenger();
    }

    fn setupDebugMessenger(self: *HelloTriangleApplication) !void {
        if (!enableValidationLayers) return;

        const createInfo = vk.VkDebugUtilsMessengerCreateInfoEXT{
            .sType = vk.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .messageSeverity = vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType = vk.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT |
                vk.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT,
            .pfnUserCallback = debugCallback,
        };

        const createFn: vk.PFN_vkCreateDebugUtilsMessengerEXT = @ptrCast(
            vk.vkGetInstanceProcAddr(self.instance, "vkCreateDebugUtilsMessengerEXT"),
        );

        const func = createFn orelse {
            std.log.err("vkCreateDebugUtilsMessengerEXT is not available", .{});
            return error.ExtensionNotPresent;
        };

        const result = func(self.instance, &createInfo, null, &self.debugMessenger);
        if (result != vk.VK_SUCCESS) {
            std.log.err("Failed to set up debug messenger (VkResult = {d})", .{result});
            return error.DebugMessengerCreationFailed;
        }
    }

    fn destroyDebugMessenger(self: *HelloTriangleApplication) void {
        if (self.debugMessenger == null) return;

        const destroyFn: vk.PFN_vkDestroyDebugUtilsMessengerEXT = @ptrCast(
            vk.vkGetInstanceProcAddr(self.instance, "vkDestroyDebugUtilsMessengerEXT"),
        );

        if (destroyFn) |func| {
            func(self.instance, self.debugMessenger, null);
        }
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
        self.destroyDebugMessenger();

        if (self.instance != null) {
            vk.vkDestroyInstance(self.instance, null);
        }

        sdl.SDL_DestroyWindow(self.window);
        sdl.SDL_Quit();
    }
};

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

fn checkExtensionSupport(allocator: std.mem.Allocator, requiredExtensions: []const [*c]const u8) !void {
    var extensionCount: u32 = 0;
    _ = vk.vkEnumerateInstanceExtensionProperties(null, &extensionCount, null);

    const availableExtensions = try allocator.alloc(vk.VkExtensionProperties, extensionCount);
    defer allocator.free(availableExtensions);

    _ = vk.vkEnumerateInstanceExtensionProperties(null, &extensionCount, availableExtensions.ptr);

    std.log.debug("available extensions:", .{});
    for (availableExtensions) |extension| {
        std.log.debug("\t{s}", .{std.mem.sliceTo(&extension.extensionName, 0)});
    }

    for (requiredExtensions) |requiredExtension| {
        const required = std.mem.sliceTo(requiredExtension, 0);

        var found = false;
        for (availableExtensions) |extension| {
            const name = std.mem.sliceTo(&extension.extensionName, 0);
            if (std.mem.eql(u8, name, required)) {
                found = true;
                break;
            }
        }

        if (!found) {
            std.log.err("Required extension not supported: {s}", .{required});
            return error.RequiredExtensionNotSupported;
        }
    }
}

fn checkValidationLayerSupport(allocator: std.mem.Allocator) !bool {
    var layerCount: u32 = 0;
    _ = vk.vkEnumerateInstanceLayerProperties(&layerCount, null);

    const availableLayers = try allocator.alloc(vk.VkLayerProperties, layerCount);
    defer allocator.free(availableLayers);

    _ = vk.vkEnumerateInstanceLayerProperties(&layerCount, availableLayers.ptr);

    for (validationLayers) |layerName| {
        const required = std.mem.sliceTo(layerName, 0);
        var found = false;

        for (availableLayers) |layerProperties| {
            const name = std.mem.sliceTo(&layerProperties.layerName, 0);
            if (std.mem.eql(u8, name, required)) {
                found = true;
                break;
            }
        }

        if (!found) return false;
    }

    return true;
}

fn getRequiredExtensions(allocator: std.mem.Allocator) ![][*c]const u8 {
    var sdlExtensionCount: u32 = 0;
    const sdlExtensions = sdl.SDL_Vulkan_GetInstanceExtensions(&sdlExtensionCount) orelse {
        std.log.err("Failed to query SDL Vulkan extensions: {s}", .{sdl.SDL_GetError()});
        return error.SDLVulkanExtensionsFailed;
    };

    var extensions: std.ArrayList([*c]const u8) = .empty;
    defer extensions.deinit(allocator);

    try extensions.appendSlice(allocator, sdlExtensions[0..sdlExtensionCount]);

    if (enableValidationLayers) {
        try extensions.append(allocator, vk.VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
    }

    return extensions.toOwnedSlice(allocator);
}

fn debugCallback(
    messageSeverity: vk.VkDebugUtilsMessageSeverityFlagBitsEXT,
    messageType: vk.VkDebugUtilsMessageTypeFlagsEXT,
    callbackData: ?*const vk.VkDebugUtilsMessengerCallbackDataEXT,
    userData: ?*anyopaque,
) callconv(.c) vk.VkBool32 {
    _ = messageSeverity;
    _ = messageType;
    _ = userData;

    if (callbackData) |data| {
        std.log.warn("validation layer: {s}", .{data.pMessage});
    }

    return vk.VK_FALSE;
}
