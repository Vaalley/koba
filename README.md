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

## Notes

- SDL3 is linked statically via Zig's `addTranslateC` and `linkSystemLibrary`.
- Vulkan is loaded via the system loader (`vulkan-1.dll`), which must be present in `PATH` or shipped next to the executable.
- Currently targets Windows x64. Other architectures (x86, arm64) and platforms (Linux, macOS, web) may come later as needed.
- Command to compile slang shaders: `slangc shaders/shader.slang -target spirv -profile spirv_1_4 -emit-spirv-directly -fvk-use-entrypoint-name -entry vertMain -entry fragMain -o shaders/slang.spv`
