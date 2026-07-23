// Prompt builders for the lumina translator.
// Assembles the system and user prompts that drive the LLM lesson translation.

import { extname } from "@std/path";
import type { Config } from "./config.ts";
import type {
  CodeBlock,
  DocsSection,
  LessonPage,
  PreviousLesson,
  ProjectContext,
  ProjectFile,
  StdlibSection,
} from "./types.ts";

/** Rough token estimate: ~4 chars per token. */
export function estimateTokens(text: string): number {
  return Math.ceil(text.length / 4);
}

/** Map a file extension to a Markdown fence language tag. */
function fenceLanguageFor(ext: string): string {
  switch (ext.toLowerCase()) {
    case ".zig":
    case ".zon":
      return "zig";
    case ".h":
    case ".c":
      return "c";
    case ".cpp":
    case ".cc":
    case ".cxx":
      return "cpp";
    case ".md":
      return "markdown";
    case ".slang":
      return "slang";
    case ".glsl":
    case ".vert":
    case ".frag":
      return "glsl";
    case ".json":
      return "json";
    case ".toml":
      return "toml";
    case ".sh":
      return "bash";
    default:
      return "text";
  }
}

/**
 * Build the rich system prompt. This is the most important function: it embeds
 * the koba project conventions directly so the model cannot drift from them.
 */
export function buildSystemPrompt(
  _config: Config,
  context: ProjectContext,
): string {
  const v = context.versions;

  const sections: string[] = [];

  // --- Role ---
  sections.push(
    "You are a patient expert teacher translating a Vulkan C++ tutorial lesson into a Zig lesson for the koba game engine project.",
  );

  // --- Teaching guidelines ---
  sections.push(
    [
      "## Teaching guidelines",
      "",
      "- Explain *why* before *how*. The reader should understand the motivation before seeing the code.",
      "- Call out trade-offs, edge cases, and likely confusion points explicitly.",
      "- Connect each new idea back to the lesson's prior steps and to the existing koba codebase.",
      "- Target game engine learners: assume comfort with systems programming but not with Vulkan or Zig idioms.",
      "- Prefer concrete, runnable Zig snippets over abstract prose. Every code example must compile against the supplied project.",
      "- When a Vulkan C++ concept maps awkwardly to Zig, explain the impedance mismatch and the chosen resolution.",
    ].join("\n"),
  );

  // --- Detected versions ---
  sections.push(
    [
      "## Detected project versions",
      "",
      `- Zig: ${v.zig}`,
      `- Vulkan SDK: ${v.vulkanSdk}`,
      `- SDL3: ${v.sdl3}`,
      `- Zig stdlib source dir: ${v.zigStdDir}`,
    ].join("\n"),
  );

  // --- Project conventions (embedded from CONTEXT.md) ---
  sections.push(
    [
      "## Project conventions (ground truth — follow exactly)",
      "",
      "The koba project uses:",
      "",
      "- **Zig 0.16.0** as the implementation language.",
      "- **SDL3** via raw C bindings produced by `addTranslateC` (NOT a Zig wrapper).",
      "- **Vulkan 1.4** via raw C bindings produced by `addTranslateC` on `vulkan/vulkan.h` (NOT `vulkan-zig`).",
      "- **Slang** shaders, compiled to SPIR-V externally.",
      "- Build system: `build.zig`; entry point: `src/main.zig`.",
      "",
      "### Module imports",
      "",
      "```zig",
      'const std = @import("std");',
      'const builtin = @import("builtin");',
      'const sdl = @import("sdl3");',
      'const vulkan = @import("vulkan");',
      "```",
      "",
      "### Vulkan API style (the `vulkan.` prefix — NEVER `vk.`)",
      "",
      "The `vulkan` module is the C API translated directly into Zig. Therefore:",
      "",
      "- Vulkan handles: `vulkan.VkInstance`, `vulkan.VkDevice`, `vulkan.VkSurfaceKHR`, `vulkan.VkSwapchainKHR`, etc.",
      "- Vulkan functions: `vulkan.vkCreateInstance`, `vulkan.vkCreateDevice`, `vulkan.vkGetDeviceQueue`, etc.",
      "- Vulkan constants/enums: `vulkan.VK_*` and `vulkan.VK_STRUCTURE_TYPE_*`.",
      "- Vulkan struct fields keep their C names: `.sType`, `.pApplicationName`, `.pNext`, `.queueFamilyIndex`, `.imageFormat`, etc.",
      "- `VkBool32` values are `vulkan.VK_TRUE` and `vulkan.VK_FALSE`.",
      "- `VK_NULL_HANDLE` is `null` for handle fields in Zig, e.g. `instance: vulkan.VkInstance = null`.",
      "",
      "Correct example:",
      "",
      "```zig",
      "var create_info: vulkan.VkInstanceCreateInfo = .{",
      "    .sType = vulkan.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,",
      "    .pApplicationInfo = &app_info,",
      "    .enabledLayerCount = layer_count,",
      "    .ppEnabledLayerNames = layer_names.ptr,",
      "};",
      "```",
      "",
      "### SDL3 API style (raw C bindings)",
      "",
      "- Window type: `?*sdl.SDL_Window`.",
      "- Functions: `sdl.SDL_Init`, `sdl.SDL_CreateWindow`, `sdl.SDL_Vulkan_CreateSurface`, `sdl.SDL_GetWindowSizeInPixels`, `sdl.SDL_PollEvent`, etc.",
      "- Window flags: `sdl.SDL_WINDOW_VULKAN`.",
      "- Event type: `sdl.SDL_Event`; quit event: `sdl.SDL_EVENT_QUIT`.",
      "",
      "### Error handling — use `vulkan_check`, NOT hand-rolled VkResult checks",
      "",
      "Do NOT write `if (result != vulkan.VK_SUCCESS) { ... }` blocks. Use the shared `vulkan_check` helper, which logs the error name + VkResult and returns the supplied error on failure:",
      "",
      "```zig",
      "try vulkan_check(",
      "    vulkan.vkCreateInstance(&create_info, null, &self.instance),",
      "    error.InstanceCreationFailed,",
      ");",
      "```",
      "",
      'The `vulkan_check` helper lives in the "Vulkan Helpers" section at the bottom of `main.zig`, alongside the other free functions (`debug_callback`, `check_required_features`, `choose_swap_surface_format`, `choose_swap_present_mode`, `choose_swap_minimum_image_count`) and the `FPSCounter` struct. New free functions that do not need `self` go there too — NOT as `Application` methods with an unused `self` parameter.',
      "",
      "### The `Application` struct — extend it, do not invent a new architecture",
      "",
      "The main struct is `Application` in `src/main.zig`. It holds the allocator, window, instance/device setup, swap chain state, pipeline state, command recording, and per-frame sync objects. Constants (`frames_in_flight_max`, `swap_chain_images_max`, `validation_layers`, `enable_validation_layers`, `required_device_extensions`) live at file scope.",
      "",
      "Extend `Application` with new fields and methods for the lesson. Do NOT create a separate architecture, new module files, or parallel class hierarchies.",
      "",
      "### Allocation pattern",
      "",
      "```zig",
      "const items = try self.allocator.alloc(T, count);",
      "defer self.allocator.free(items);",
      "```",
      "",
      "### Logging",
      "",
      "```zig",
      'std.log.info("...", .{});',
      'std.log.debug("...", .{});',
      'std.log.err("...", .{});',
      "```",
      "",
      "### Cleanup order in `cleanup()`",
      "",
      "1. Destroy sync objects (semaphores, fences) and free command buffers.",
      "2. `vulkan.vkDestroyCommandPool(device, command_pool, null)`.",
      "3. Destroy graphics pipeline, pipeline layout, shader module.",
      "4. Clean up the swap chain (image views, swapchain, image slice).",
      "5. `vulkan.vkDestroyDevice(device, null)`.",
      "6. `vulkan.vkDestroySurfaceKHR(instance, surface, null)`.",
      "7. Destroy debug messenger.",
      "8. `vulkan.vkDestroyInstance(instance, null)`.",
      "9. `sdl.SDL_DestroyWindow(window)`.",
      "10. `sdl.SDL_Quit()`.",
      "",
      "### Things to avoid",
      "",
      "- Do NOT use `vulkan.InstanceProxy`, `vulkan.DeviceProxy`, `self.instance.create*`, or any `vulkan-zig`-style wrappers.",
      "- Do NOT use snake_case Vulkan struct field names (e.g. `.s_type`, `.image_format`). Use `.sType`, `.imageFormat`.",
      "- Do NOT invent new module names or a new project layout. Extend `Application`.",
      "- Do NOT hand-roll `if (result != vulkan.VK_SUCCESS) { ... }` blocks. Use `vulkan_check`.",
      "- Do NOT use `vk.` as a module prefix. The module is imported as `vulkan`, so use `vulkan.vkCreateInstance`, `vulkan.VkInstance`, etc.",
    ].join("\n"),
  );

  // --- Output format ---
  sections.push(
    [
      "## Output format",
      "",
      "Produce a single Markdown document with these sections, in order:",
      "",
      "1. **Title** — the lesson title as a top-level heading.",
      "2. **Overview** — a short paragraph framing what the lesson covers and why it matters for the koba engine.",
      "3. **Concepts & Explanations** — teach the Vulkan concepts and their Zig equivalents. Explain why before how; call out trade-offs and edge cases.",
      "4. **Code Translation** — walk through translating the source C++ into Zig that extends `Application`. Show the diff against the existing code where relevant, and explain each change. Every snippet must follow the conventions above.",
      "5. **Recap & What's Next** — summarize what was learned and tee up the natural next step.",
      "",
      "Use fenced code blocks with the `zig` language tag for Zig code. Keep prose tight and code correct.",
    ].join("\n"),
  );

  return sections.join("\n\n");
}

/** Format each ProjectFile as a heading + fenced code block. */
function formatProjectFiles(files: ProjectFile[]): string {
  return files
    .map((file) => {
      const fence = fenceLanguageFor(extname(file.relativePath));
      const suffix = file.truncated ? " (truncated)" : "";
      return [
        `### ${file.relativePath}${suffix}`,
        "```" + fence,
        file.content.trimEnd(),
        "```",
      ].join("\n");
    })
    .join("\n\n");
}

/** Format each CodeBlock as a heading + fenced code block. */
function formatCodeBlocks(codeBlocks: CodeBlock[]): string {
  return codeBlocks
    .map((block, index) => {
      const heading = block.heading || `Code block ${index + 1}`;
      const fence = block.language || "text";
      return [
        `### ${heading}`,
        "```" + fence,
        block.code.trimEnd(),
        "```",
      ].join("\n");
    })
    .join("\n\n");
}

/** Format each PreviousLesson as a heading + (truncated) content. */
function formatPreviousLessons(lessons: PreviousLesson[]): string {
  return lessons
    .map((lesson) => {
      return [
        `### ${lesson.title}`,
        lesson.content.trimEnd(),
      ].join("\n");
    })
    .join("\n\n");
}

/** Format each StdlibSection as a heading + signature code block + doc. */
function formatStdlibSections(sections: StdlibSection[]): string {
  return sections
    .map((section) => {
      const pieces: string[] = [`### ${section.moduleLabel}: ${section.title}`];
      if (section.signature) {
        pieces.push("```zig");
        pieces.push(section.signature.trimEnd());
        pieces.push("```");
      }
      if (section.doc) {
        pieces.push(section.doc.trimEnd());
      }
      return pieces.join("\n");
    })
    .join("\n\n");
}

/** Format each DocsSection as a heading + content (+ optional code). */
function formatReferenceSections(sections: DocsSection[]): string {
  return sections
    .map((section) => {
      const pieces: string[] = [`### ${section.title}`];
      if (section.content) {
        pieces.push(section.content.trimEnd());
      }
      if (section.code) {
        pieces.push("```zig");
        pieces.push(section.code.trimEnd());
        pieces.push("```");
      }
      return pieces.join("\n");
    })
    .join("\n\n");
}

/**
 * Build the user prompt with all context sections in the required order.
 */
export function buildUserPrompt(
  lesson: LessonPage,
  context: ProjectContext,
  _config: Config,
): string {
  const v = context.versions;
  const sections: string[] = [];

  // a. Lesson title
  sections.push(`# ${lesson.title}`);

  // b. Project versions
  sections.push(
    [
      "## Project versions",
      "",
      `- Zig: ${v.zig}`,
      `- Vulkan SDK: ${v.vulkanSdk}`,
      `- SDL3: ${v.sdl3}`,
    ].join("\n"),
  );

  // c. Project conventions (CONTEXT.md) — full contextMd in a code block
  sections.push(
    [
      "## Project conventions (CONTEXT.md)",
      "",
      "```markdown",
      context.contextMd.trimEnd(),
      "```",
    ].join("\n"),
  );

  // d. Project codebase
  if (context.files.length > 0) {
    sections.push(
      "## Project codebase",
      formatProjectFiles(context.files),
    );
  }

  // e. Previous lessons (for continuity)
  if (context.previousLessons.length > 0) {
    sections.push(
      "## Previous lessons (for continuity)",
      formatPreviousLessons(context.previousLessons),
    );
  }

  // f. Source lesson code blocks
  sections.push(
    "## Source lesson code blocks",
    formatCodeBlocks(lesson.codeBlocks),
  );

  // g. Zig stdlib API signatures
  if (context.stdlibSections.length > 0) {
    sections.push(
      "## Zig stdlib API signatures",
      formatStdlibSections(context.stdlibSections),
    );
  }

  // h. Zig reference documentation
  if (context.referenceSections.length > 0) {
    sections.push(
      "## Zig reference documentation",
      formatReferenceSections(context.referenceSections),
    );
  }

  // i. Task
  sections.push(
    [
      "## Task",
      "",
      "Translate this Vulkan C++ lesson into a Zig lesson for the koba project. Follow the project conventions exactly. Produce a single Markdown document with the required sections.",
    ].join("\n"),
  );

  return sections.join("\n\n");
}

/** Convenience: build both prompts in one call. */
export function buildPrompts(
  lesson: LessonPage,
  context: ProjectContext,
  config: Config,
): { system: string; user: string } {
  return {
    system: buildSystemPrompt(config, context),
    user: buildUserPrompt(lesson, context, config),
  };
}
