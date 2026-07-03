# Koba

A Zig game engine project using SDL3 for windowing and Vulkan for rendering.

## Prerequisites

- [Zig 0.16.0](https://ziglang.org/)
- [Vulkan SDK](https://vulkan.lunarg.com/) (tested with 1.4.350.0)
- SDL3 (vendored in `third_party/SDL3/`)

## Build & Run

```sh
zig build run
```

Other commands:

```sh
zig build        # build only
zig build test   # run tests
```

## Project Layout

```
src/                 Application source
include/             C wrappers used by Zig's translate-c
  vulkan_wrapper.h   Loads Vulkan headers with Win32 surface support
third_party/SDL3/    Vendored SDL3 headers and Windows binaries (x86, x64, arm64)
build.zig            Build script
build.zig.zon        Package manifest
specula.config.json  Defaults for the specula tutorial translator
```

## Translating Vulkan tutorial pages

Tutorial translation is handled by [specula](https://github.com/Vaalley/specula),
a profile-driven CLI. This repo ships a `specula.config.json` that selects the
`vulkan-cpp-to-zig-sdl3` profile and points `projectRoot` at the koba root, so
translations are fed the real koba source as context.

1. Clone and enter specula (separate from this repo):

   ```sh
   git clone https://github.com/Vaalley/specula.git
   cd specula
   ```

2. Set your OpenRouter API key:

   ```sh
   # Windows (PowerShell)
   $env:OPENROUTER_API_KEY="your-key-here"
   # Linux/macOS
   export OPENROUTER_API_KEY="your-key-here"
   ```

3. Fetch the Zig 0.16.0 reference and stdlib caches (once):

   ```sh
   deno task fetch-docs --profile vulkan-cpp-to-zig-sdl3
   ```

4. Translate a lesson, pointing `--project` at the koba repo so specula picks up
   `specula.config.json` and scans the codebase:

   ```sh
   deno task translate https://docs.vulkan.org/tutorial/latest/03_Drawing_a_triangle/00_Setup/00_Base_code.html \
     --project /path/to/koba \
     --out ./out/Base_code.md
   ```

With `specula.config.json` present, `--profile` and the RAG budgets are applied
automatically; you only need `--project` (or run specula from inside the koba
root). See the specula README for the full flag reference.

## Notes

- SDL3 is linked statically via Zig's `addTranslateC` and `linkSystemLibrary`.
- Vulkan is loaded via the system loader (`vulkan-1.dll`), which must be present in `PATH` or shipped next to the executable.
- Currently targets Windows x64. Other architectures (x86, arm64) and platforms (Linux, macOS, web) are planned.
