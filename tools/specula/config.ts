export interface StdlibModule {
  url: string;
  label: string;
  priority: string[];
  maxDecls?: number;
}

export interface FeatureRule {
  pattern: string;
  feature: string;
  concepts: string[];
  modules: string[];
}

export interface ProjectFilePriority {
  contextNames: string[];
  buildNames: string[];
  entrypointNames: string[];
  sourceDirPrefixes: string[];
  headerExts: string[];
  readmeNames: string[];
}

export interface Provider {
  endpoint: string;
  headers: Record<string, string>;
}

export interface RagBudgets {
  maxBytesPerFile?: number;
  maxTotalBytes?: number;
  maxFiles?: number;
  referenceLimit?: number;
  stdlibLimit?: number;
}

export interface Config {
  sourceLanguage: string;
  targetLanguage: string;
  targetVersion: string;
  referenceUrl: string;
  stdlibModules: Record<string, StdlibModule>;
  featureRules: FeatureRule[];
  projectIncludeExt: string[];
  projectIncludeNames: string[];
  projectIgnoreDirs: string[];
  projectFilePriority: ProjectFilePriority;
  promptSections: string[];
  apiKeyEnvVar: string;
  temperature: number;
  fenceLanguage: Record<string, string>;
  provider: Provider;
  ragBudgets: RagBudgets;
}

export const KOBA_CONFIG: Config = {
  sourceLanguage: "cpp",
  targetLanguage: "zig",
  targetVersion: "0.16.0",
  referenceUrl: "https://ziglang.org/documentation/0.16.0/",
  stdlibModules: {
    array_list: {
      url: "array_list.zig",
      label: "ArrayList",
      priority: ["ArrayList", "ArrayListUnmanaged", "Aligned"],
      maxDecls: 12,
    },
    allocator: {
      url: "mem/Allocator.zig",
      label: "Allocator",
      priority: ["Allocator", "AllocatorError", "create", "destroy"],
      maxDecls: 12,
    },
    mem: {
      url: "mem.zig",
      label: "mem",
      priority: ["copy", "copyForwards", "copyBackwards", "zeroes", "set"],
      maxDecls: 12,
    },
    heap: {
      url: "heap.zig",
      label: "heap",
      priority: ["page_allocator", "GeneralPurposeAllocator", "ArenaAllocator"],
      maxDecls: 12,
    },
    fmt: {
      url: "fmt.zig",
      label: "fmt",
      priority: ["allocPrint", "print", "format", "comptimePrint"],
      maxDecls: 12,
    },
    hash_map: {
      url: "hash_map.zig",
      label: "hash_map",
      priority: ["HashMap", "StringHashMap", "AutoHashMap"],
      maxDecls: 12,
    },
    log: {
      url: "log.zig",
      label: "log",
      priority: ["info", "warn", "err", "debug"],
      maxDecls: 12,
    },
    debug: {
      url: "debug.zig",
      label: "debug",
      priority: ["assert", "panic", "printStackTrace"],
      maxDecls: 12,
    },
  },
  featureRules: [
    {
      pattern: "std::vector|Vector<|array list",
      feature: "dynamic arrays",
      concepts: ["dynamic arrays", "array lists", "allocation"],
      modules: ["array_list", "allocator", "mem"],
    },
    {
      pattern: "std::optional|optional",
      feature: "optional values",
      concepts: ["optionals", "nullability"],
      modules: ["mem"],
    },
    {
      pattern: "throw |try\\s*\\{|catch\\s*\\(",
      feature: "exception-style error handling",
      concepts: ["error handling", "error unions", "defer"],
      modules: ["log", "debug"],
    },
    {
      pattern: "std::unique_ptr|std::shared_ptr|new |delete ",
      feature: "ownership and lifetime",
      concepts: ["resource ownership", "defer", "allocators"],
      modules: ["allocator", "mem", "heap"],
    },
    {
      pattern: "std::unordered_map|std::map|hash map",
      feature: "maps and dictionaries",
      concepts: ["hash maps", "lookup tables"],
      modules: ["hash_map", "allocator"],
    },
    {
      pattern: "static_cast|reinterpret_cast|const_cast|dynamic_cast",
      feature: "casts",
      concepts: ["casts", "pointer conversions"],
      modules: ["mem"],
    },
    {
      pattern: "GLFW|glfw",
      feature: "windowing",
      concepts: ["SDL3 windowing", "event loop"],
      modules: ["log"],
    },
    {
      pattern: "VkInstance|VkDevice|vkCreate|vk::|Vulkan",
      feature: "Vulkan API usage",
      concepts: ["Vulkan bindings", "resource lifetime", "command buffers"],
      modules: ["log", "debug"],
    },
    {
      pattern:
        "render pass|pipeline|framebuffer|swap chain|swapchain|vertex buffer|index buffer",
      feature: "rendering pipeline",
      concepts: ["rendering", "graphics pipeline", "GPU resources"],
      modules: ["log", "debug"],
    },
  ],
  projectIncludeExt: [".zig", ".zon", ".h", ".c", ".cpp", ".md"],
  projectIncludeNames: [
    "CONTEXT.md",
    "README.md",
    "README",
    "build.zig",
    "build.zig.zon",
    "zig.fmt",
    "main.zig",
  ],
  projectIgnoreDirs: [
    ".git",
    ".cache",
    ".zig-cache",
    "zig-out",
    "third_party",
    "node_modules",
    "tools",
    ".vscode",
  ],
  projectFilePriority: {
    contextNames: ["CONTEXT.md"],
    buildNames: ["build.zig", "build.zig.zon"],
    entrypointNames: ["main.zig", "src/main.zig", "app.zig", "src/app.zig"],
    sourceDirPrefixes: ["src/"],
    headerExts: [".h", ".hpp"],
    readmeNames: ["README.md", "README"],
  },
  promptSections: [
    "Translate GLFW-oriented C++ Vulkan tutorial code into Zig code for the koba game engine project.",
    "Koba is a learning game-engine project using Zig 0.16.0, SDL3 for windowing, and Vulkan 1.4 for rendering.",
    "The Vulkan bindings are raw C bindings generated by Zig's addTranslateC on vulkan/vulkan.h. Use vk.VkInstance, vk.vkCreateInstance, vk.VK_STRUCTURE_TYPE_*, vk.VK_TRUE, vk.VK_NULL_HANDLE, etc. Do NOT use vulkan-zig proxy wrappers like vk.InstanceProxy, vk.DeviceProxy, or self.instance.create* methods.",
    "SDL3 is also a raw C binding via addTranslateC on SDL3/SDL.h and SDL3/SDL_vulkan.h. Use sdl.SDL_Window, sdl.SDL_CreateWindow, sdl.SDL_Vulkan_CreateSurface, sdl.SDL_GetWindowSizeInPixels, sdl.SDL_Event, etc.",
    "Match the existing HelloTriangleApplication struct style in src/main.zig: a struct with an allocator field, std.log.* for logging, error unions, explicit error names, defer cleanup, and explicit VkResult checking.",
    "Preserve the build.zig setup: Vulkan SDK at C:/VulkanSDK/1.4.350.0, SDL3 vendored in third_party/SDL3, and @import modules named 'sdl3' and 'vulkan'.",
    "Keep the translation aligned with Zig 0.16.0 idioms and the existing code's naming conventions. Vulkan struct fields keep their C names (e.g. .sType, .pApplicationName, .imageFormat, .imageExtent).",
    "Target the lesson output at game engine / game engine development learners. Explain why each Vulkan concept matters for rendering, and connect new ideas back to prior steps in the tutorial.",
  ],
  apiKeyEnvVar: "OPENROUTER_API_KEY",
  temperature: 0.2,
  fenceLanguage: {
    ".zig": "zig",
    ".zon": "zig",
    ".h": "c",
    ".c": "c",
    ".cpp": "cpp",
    ".md": "markdown",
  },
  provider: {
    endpoint: "https://openrouter.ai/api/v1/chat/completions",
    headers: {
      "HTTP-Referer": "https://github.com/Vaalley/specula",
      "X-Title": "koba",
    },
  },
  ragBudgets: {
    maxBytesPerFile: 16000,
    maxTotalBytes: 64000,
    maxFiles: 60,
    referenceLimit: 6,
    stdlibLimit: 24,
  },
};
