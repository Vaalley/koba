import { dirname, fromFileUrl, join, resolve } from "@std/path";

export interface StdlibModule {
  url: string;
  label: string;
  priority: string[];
  maxDecls: number;
}

export interface FeatureRule {
  pattern: string;
  feature: string;
  concepts: string[];
  modules: string[];
}

export interface Config {
  // Paths (resolved at module load)
  moduleDir: string;
  kobaRoot: string;
  docsDir: string;
  cacheDir: string;
  contextFile: string;

  // LLM
  endpoint: string;
  defaultModel: string;
  apiKeyEnvVar: string;
  temperature: number;
  extraHeaders: Record<string, string>;

  // Reference docs
  referenceUrl: string;

  // Stdlib
  stdlibModules: Record<string, StdlibModule>;
  featureRules: FeatureRule[];

  // Budgets
  maxBytesPerFile: number;
  maxTotalBytes: number;
  maxFiles: number;
  referenceLimit: number;
  stdlibLimit: number;
  maxPreviousLessons: number;
  previousLessonMaxBytes: number;

  // File scanning
  includeExt: string[];
  includeNames: string[];
  ignoreDirs: string[];
}

const MODULE_DIR = dirname(fromFileUrl(import.meta.url));
const KOBA_ROOT = resolve(join(MODULE_DIR, "../.."));

export const CONFIG: Config = {
  moduleDir: MODULE_DIR,
  kobaRoot: KOBA_ROOT,
  docsDir: join(MODULE_DIR, "docs"),
  cacheDir: join(MODULE_DIR, ".cache"),
  contextFile: join(MODULE_DIR, "CONTEXT.md"),

  endpoint: "https://openrouter.ai/api/v1/chat/completions",
  defaultModel: "openai/gpt-5.6-luna",
  // defaultModel: "openrouter/free",
  apiKeyEnvVar: "OPENROUTER_API_KEY",
  temperature: 0.2,
  extraHeaders: {
    "HTTP-Referer": "https://github.com/Vaalley/koba",
    "X-Title": "koba-lumina",
  },

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

  maxBytesPerFile: 48_000,
  maxTotalBytes: 120_000,
  maxFiles: 20,
  referenceLimit: 6,
  stdlibLimit: 24,
  maxPreviousLessons: 3,
  previousLessonMaxBytes: 4_000,

  includeExt: [".zig", ".zon", ".h", ".c", ".cpp", ".md", ".slang"],
  includeNames: [
    "CONTEXT.md",
    "README.md",
    "build.zig",
    "build.zig.zon",
    "main.zig",
  ],
  ignoreDirs: [
    ".git",
    ".cache",
    ".zig-cache",
    "zig-out",
    "third_party",
    "node_modules",
    "tools",
    ".vscode",
  ],
};
