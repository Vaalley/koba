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
```

## Notes

- SDL3 is linked statically via Zig's `addTranslateC` and `linkSystemLibrary`.
- Vulkan is loaded via the system loader (`vulkan-1.dll`), which must be present in `PATH` or shipped next to the executable.
- Currently targets Windows x64. Other architectures (x86, arm64) and platforms (Linux, macOS, web) are planned.
