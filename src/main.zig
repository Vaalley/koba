const std = @import("std");
const sdl = @import("sdl3");

pub fn main() !void {
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) {
        std.log.err("SDL Initialization Failed: {s}", .{sdl.SDL_GetError()});
        return error.SDLInitFailed;
    }
    defer sdl.SDL_Quit();

    const window = sdl.SDL_CreateWindow(
        "Koba",
        1280,
        720,
        sdl.SDL_WINDOW_VULKAN | sdl.SDL_WINDOW_RESIZABLE,
    ) orelse {
        std.log.err("Window Creation Failed: {s}", .{sdl.SDL_GetError()});
        return error.WindowCreationFailed;
    };
    defer sdl.SDL_DestroyWindow(window);

    std.debug.print("Clean SDL3 window is running under Zig 0.16.0!\n", .{});

    var running = true;
    while (running) {
        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event)) {
            if (event.type == sdl.SDL_EVENT_QUIT) {
                running = false;
            }
            if (event.type == sdl.SDL_EVENT_KEY_DOWN) {
                if (event.key.scancode == sdl.SDL_SCANCODE_ESCAPE) {
                    running = false;
                }
            }
        }
        sdl.SDL_Delay(16);
    }
}
