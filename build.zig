const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "koba",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // **********
    // *  SDL3  *
    // **********
    const sdl3_path = "third_party/SDL3";

    const sdl3_translate_c = b.addTranslateC(.{
        .root_source_file = b.path("include/sdl_wrapper.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    sdl3_translate_c.addIncludePath(b.path(sdl3_path ++ "/include"));

    const sdl3_module = sdl3_translate_c.createModule();

    sdl3_module.addIncludePath(b.path(sdl3_path ++ "/include"));
    sdl3_module.addLibraryPath(b.path(sdl3_path ++ "/lib/x64"));

    sdl3_module.linkSystemLibrary("SDL3", .{});

    exe.root_module.addImport("sdl3", sdl3_module);

    // ************
    // *  Vulkan  *
    // ************
    const vulkan_sdk = "C:/VulkanSDK/1.4.350.0";
    const vulkan_include = std.Build.LazyPath{ .cwd_relative = vulkan_sdk ++ "/Include" };
    const vulkan_lib = std.Build.LazyPath{ .cwd_relative = vulkan_sdk ++ "/Lib" };

    const vulkan_translate_c = b.addTranslateC(.{
        .root_source_file = b.path("include/vulkan_wrapper.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    vulkan_translate_c.addIncludePath(vulkan_include);

    const vulkan_module = vulkan_translate_c.createModule();

    vulkan_module.addIncludePath(vulkan_include);
    vulkan_module.addLibraryPath(vulkan_lib);

    vulkan_module.linkSystemLibrary("vulkan-1", .{});

    exe.root_module.addImport("vulkan", vulkan_module);

    b.installArtifact(exe);

    const copy_dll = b.addInstallFile(b.path("third_party/SDL3/lib/x64/SDL3.dll"), "bin/SDL3.dll");
    b.getInstallStep().dependOn(&copy_dll.step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
