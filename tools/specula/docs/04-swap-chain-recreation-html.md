# Title

# Swap-Chain Recreation in Vulkan with Zig 0.16.0 and SDL3

## Overview

The previous Koba lessons created a swap chain and its image views:

1. SDL3 creates the window.
2. Vulkan creates an instance.
3. SDL3 creates a Vulkan surface.
4. Koba selects a physical device.
5. Koba creates a logical device and graphics queue.
6. Koba creates a swap chain.
7. Koba retrieves swap-chain images.
8. Koba creates image views.
9. Koba records and submits rendering commands.
10. Koba presents an image.

A swap chain is tied to the window's drawable size and surface capabilities. If
the window is resized, minimized, moved between displays, or otherwise changes
presentation conditions, the existing swap chain may no longer be usable.

The renderer must then:

```text
stop using the old swap chain
        |
        v
wait until the device is idle
        |
        v
destroy old image views and swap chain
        |
        v
create a new swap chain
        |
        v
retrieve new swap-chain images
        |
        v
create new image views
```

Vulkan reports this situation through result codes such as:

```zig
vk.VK_ERROR_OUT_OF_DATE_KHR
vk.VK_SUBOPTIMAL_KHR
```

This lesson translates the C++ swap-chain recreation code into Zig 0.16.0 using
Koba's existing `HelloTriangleApplication` in `src/main.zig`.

Koba uses raw translated C bindings:

```zig
const std = @import("std");
const sdl = @import("sdl3");
const vk = @import("vulkan");
```

There are no Vulkan proxy wrappers. Calls use names such as:

```zig
vk.vkDeviceWaitIdle(...)
vk.vkDestroySwapchainKHR(...)
vk.vkAcquireNextImageKHR(...)
vk.vkQueuePresentKHR(...)
```

SDL3 supplies window events and drawable-pixel sizes.

## Concepts & Explanations

### Why swap-chain recreation is necessary

The swap chain contains images with a specific size, format, and presentation
configuration. These properties come from the surface and the window's current
state.

For example, a window may begin at:

```text
1280 × 720 pixels
```

After resizing, it may become:

```text
1920 × 1080 pixels
```

The old swap-chain images still have the original dimensions. Vulkan cannot
automatically resize those images because they are already Vulkan objects owned
by the old swap chain.

The renderer must replace them:

```text
old window size
    |
    v
old swap-chain images
    |
    v
destroy and recreate
    |
    v
new window size
    |
    v
new swap-chain images
```

This is not specific to desktop resizing. Recreation can also be required when:

- the window is minimized and later restored,
- the surface becomes incompatible with the swap chain,
- the display configuration changes,
- the presentation engine reports that the swap chain is no longer current.

### `VK_ERROR_OUT_OF_DATE_KHR` and `VK_SUBOPTIMAL_KHR`

Vulkan distinguishes two common presentation results.

#### `VK_ERROR_OUT_OF_DATE_KHR`

The swap chain can no longer be used with the surface. The renderer must
recreate it before continuing.

This commonly occurs when the window size changes between frames.

#### `VK_SUBOPTIMAL_KHR`

The swap chain can still be used, but it is not an ideal match for the current
surface. The application may continue rendering, but recreating the swap chain
is usually the better choice.

A useful policy is:

```text
OUT_OF_DATE  -> recreate immediately and skip this frame
SUBOPTIMAL   -> recreate, or continue and recreate soon
SUCCESS      -> continue normally
other error  -> report failure
```

The result must be checked explicitly. Raw C Vulkan bindings do not throw
exceptions or convert result codes into Zig errors automatically.

### Why the device must be idle before destruction

The GPU executes asynchronously. A call such as:

```zig
vk.vkQueueSubmit(...)
```

returns before the GPU necessarily finishes the submitted work.

The GPU might still be using:

- a swap-chain image,
- an image view,
- a command buffer,
- a framebuffer or rendering attachment.

Destroying those objects while the GPU is using them is invalid.

Therefore recreation begins with:

```zig
vk.vkDeviceWaitIdle(self.device)
```

This blocks the CPU until all work submitted to the logical device has finished.

The trade-off is that waiting for the entire device is simple but not the most
efficient solution. A more advanced renderer may wait on specific fences or
track resource lifetimes more precisely. For a learning engine and a resize
operation, device-wide waiting is clear and safe.

### Raw C cleanup is different from C++ RAII cleanup

The C++ source contains:

```cpp
swapChainImageViews.clear();
swapChain = nullptr;
```

In a Vulkan-Hpp RAII application, clearing a container of RAII objects destroys
the contained image views.

Koba stores raw Vulkan handles:

```zig
swap_chain_image_views: []vk.VkImageView
swap_chain: vk.VkSwapchainKHR
```

Assigning an empty slice or `null` does not destroy anything. Zig does not
automatically call Vulkan destruction functions for raw handles.

The raw-binding translation must explicitly call:

```zig
vk.vkDestroyImageView(...)
vk.vkDestroySwapchainKHR(...)
```

and must release the allocator-owned slice containing the image-view handles.

### Cleanup order

The dependency order is:

```text
image views
    |
    v
swap chain
    |
    v
logical device
```

An image view refers to a swap-chain image, and the swap-chain owns those
images. Therefore destroy image views before destroying the swap chain.

The complete cleanup order remains:

```text
graphics resources
command buffers and command pool
image views
swap chain
logical device
surface
debug messenger
instance
SDL window
SDL
```

When recreating only the swap chain, Koba destroys only the resources that
depend on the swap chain. The logical device, surface, instance, and SDL window
remain alive.

### Swap-chain recreation may affect more than image views

This lesson follows the supplied source, which recreates:

```text
swap chain
image views
```

A complete renderer may also need to recreate resources that depend on the
swap-chain format or extent, such as:

- depth images and depth image views,
- framebuffers,
- render passes in some designs,
- graphics pipelines whose rendering formats changed,
- command buffers containing old render areas,
- per-image synchronization data.

Dynamic rendering reduces some framebuffer management, but it does not eliminate
all extent-dependent state. If a command buffer records the old swap-chain
extent, it must be re-recorded after recreation.

The correct dependency rule is:

> Recreate every object whose configuration depends on the old swap chain.

### Why image acquisition can request recreation

The frame loop usually acquires a swap-chain image with:

```zig
vk.vkAcquireNextImageKHR(...)
```

The result is returned separately from the image index. The image index is valid
only when acquisition succeeds or is suboptimal.

If acquisition returns `VK_ERROR_OUT_OF_DATE_KHR`, there is no image to render
into. The renderer must recreate the swap chain and skip the rest of the frame.

If acquisition returns `VK_SUBOPTIMAL_KHR`, an image index is normally still
returned. The renderer may render this frame, but it should recreate the swap
chain.

### Why presentation can request recreation

Presentation also returns a `VkResult`:

```zig
vk.vkQueuePresentKHR(...)
```

The swap chain may become out of date after rendering has completed. Therefore
both acquisition and presentation must handle:

```zig
vk.VK_ERROR_OUT_OF_DATE_KHR
vk.VK_SUBOPTIMAL_KHR
```

Checking only acquisition is not sufficient.

### Resizing and SDL3 events

GLFW uses a callback to set a resize flag. SDL3 normally reports window changes
through its event queue.

Koba can set a field when it receives:

```zig
sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED
```

The pixel-size event is especially useful because Vulkan uses drawable pixels,
not merely logical window units.

A resize flag is preferable to recreating the swap chain immediately inside
event processing. Recreation should happen at a controlled point in the frame
loop, after the current frame's Vulkan work has been handled.

### Minimized windows

A minimized window may have a drawable size of zero:

```text
width  = 0
height = 0
```

A swap chain cannot be created with a zero extent.

The renderer should wait until SDL reports a positive pixel size. During this
period, it should continue processing events so the application remains
responsive.

The basic strategy is:

```text
query drawable size
while width == 0 or height == 0:
    process SDL events
    wait briefly
    query drawable size
```

This is a special case of swap-chain recreation. It is not an error condition
that should terminate the application.

## Code Translation Sections

### Add recreation state to `HelloTriangleApplication`

Add a resize flag to the existing struct:

```zig
framebuffer_resized: bool = false,
```

For SDL3, the name `framebuffer_resized` is retained because it describes the
renderer's meaning: the drawable framebuffer size may no longer match the swap
chain.

The relevant fields can look like this:

```zig
const HelloTriangleApplication = struct {
    allocator: std.mem.Allocator,

    window: ?*sdl.SDL_Window = null,

    instance: vk.VkInstance = null,
    debug_messenger: vk.VkDebugUtilsMessengerEXT = null,
    surface: vk.VkSurfaceKHR = null,

    physical_device: vk.VkPhysicalDevice = null,
    device: vk.VkDevice = null,
    graphics_queue: vk.VkQueue = null,
    graphics_family: u32 = 0,

    swap_chain: vk.VkSwapchainKHR = null,
    swap_chain_images: []vk.VkImage = &.{},
    swap_chain_surface_format: vk.VkSurfaceFormatKHR = undefined,
    swap_chain_extent: vk.VkExtent2D = undefined,
    swap_chain_image_views: []vk.VkImageView = &.{},

    framebuffer_resized: bool = false,
};
```

The existing application may contain additional shader, pipeline,
command-buffer, and synchronization fields. Keep those fields and add only the
resize state required by this lesson.

### Process SDL3 resize events

Add a method inside `HelloTriangleApplication`:

```zig
fn pollEvents(self: *HelloTriangleApplication) bool {
    var event: sdl.SDL_Event = undefined;
    var running = true;

    while (sdl.SDL_PollEvent(&event)) {
        switch (event.type) {
            sdl.SDL_EVENT_QUIT => {
                running = false;
            },

            sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED,
            sdl.SDL_EVENT_WINDOW_RESIZED => {
                self.framebuffer_resized = true;
            },

            else => {},
        }
    }

    return running;
}
```

The event loop returns `false` when SDL requests application shutdown.

The pixel-size event is the important one for Vulkan because the swap chain uses
drawable pixel dimensions. Handling `SDL_EVENT_WINDOW_RESIZED` as well is useful
because different window-system situations may produce different SDL events.

The main loop can use the method like this:

```zig
while (app.pollEvents()) {
    try app.drawFrame();
}
```

If the existing entrypoint already processes events, merge the two resize cases
into that event loop instead of creating a second event-processing architecture.

### Destroy swap-chain-dependent resources

Add this method inside `HelloTriangleApplication`:

```zig
fn cleanupSwapChain(self: *HelloTriangleApplication) void {
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
```

This method translates the C++ `cleanupSwapChain` concept into explicit raw
Vulkan cleanup.

Important details:

- `vk.vkDestroyImageView` destroys each image view.
- The allocator-owned image-view slice is freed separately.
- `vk.vkDestroySwapchainKHR` destroys the swap chain.
- Swap-chain image handles must not be destroyed individually. They are owned by
  the swap chain.
- The image-handle slice is still application-owned memory, so Koba must free
  it.

The order is intentional:

```text
destroy image views
free image-view slice
destroy swap chain
free image slice
```

The image views must be destroyed before the swap chain that owns their
underlying images.

### Recreate the swap chain

Add this method inside `HelloTriangleApplication`:

```zig
fn recreateSwapChain(self: *HelloTriangleApplication) !void {
    if (self.device == null) {
        return error.DeviceNotCreated;
    }

    try self.waitForDrawableSize();

    const wait_result = vk.vkDeviceWaitIdle(self.device);
    if (wait_result != vk.VK_SUCCESS) {
        std.log.err(
            "Failed to wait for the device before swap-chain recreation",
            .{},
        );
        return error.FailedToWaitForDeviceIdle;
    }

    self.cleanupSwapChain();

    try self.createSwapChain();
    errdefer self.cleanupSwapChain();

    try self.createImageViews();

    self.framebuffer_resized = false;

    std.log.info("Recreated Vulkan swap chain", .{});
}
```

The order matches the C++ source:

```cpp
device.waitIdle();

cleanupSwapChain();

createSwapChain();
createImageViews();
```

The Zig version adds explicit error handling and cleanup protection.

If `createSwapChain()` succeeds but `createImageViews()` fails, the `errdefer`
calls `cleanupSwapChain()` so the partially recreated resources do not leak.

If later lessons add extent-dependent resources, extend this method:

```zig
try self.createSwapChain();
try self.createImageViews();
try self.createDepthResources();
try self.createFramebuffers();
try self.recordCommandBuffers();
```

The exact list depends on which objects the existing project has already
created.

### Wait for a usable drawable size

Add this helper inside `HelloTriangleApplication`:

```zig
fn waitForDrawableSize(self: *HelloTriangleApplication) !void {
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
```

This method uses `SDL_GetWindowSizeInPixels`, not a logical-size query. Vulkan
needs the actual drawable pixel extent.

The `SDL_Delay(16)` call prevents a minimized-window loop from consuming an
entire CPU core. Polling events inside the loop keeps the application responsive
while the window has no drawable area.

A production engine may use a more advanced event wait strategy, but this
version is easy to understand and safe for the tutorial.

### Recreate from swap-chain acquisition

The C++ source checks the result from `acquireNextImage`. The raw C Vulkan
version can be written as a helper that returns an optional image index:

```zig
fn acquireSwapChainImage(
    self: *HelloTriangleApplication,
    present_complete_semaphore: vk.VkSemaphore,
) !?u32 {
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
```

The optional return value has a clear meaning:

```text
some(image_index) -> render this frame
null               -> recreation occurred; skip this frame
```

`std.math.maxInt(u64)` is the Zig equivalent of the C++ `UINT64_MAX` timeout. It
requests an effectively unlimited wait.

The semaphore is supplied by the existing frame-synchronization code. The `null`
fence argument means that this example does not use an acquisition fence.

### Why acquisition may return an image index on `SUBOPTIMAL`

`VK_SUBOPTIMAL_KHR` is not a complete failure. Vulkan may still provide a usable
image index.

This code marks the swap chain for recreation:

```zig
if (result == vk.VK_SUBOPTIMAL_KHR) {
    self.framebuffer_resized = true;
}
```

The current frame may continue using the returned index. The frame loop can
recreate after presenting, or before the next frame.

A simpler policy is to recreate immediately after acquisition, but then the
acquired image and its semaphore state need careful handling. Marking the swap
chain for recreation avoids abandoning a partially acquired frame.

### Present the rendered image

The raw C translation of `queue.presentKHR` is:

```zig
fn presentSwapChainImage(
    self: *HelloTriangleApplication,
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
```

The fields retain Vulkan's translated C names:

```zig
.sType
.waitSemaphoreCount
.pWaitSemaphores
.swapchainCount
.pSwapchains
.pImageIndices
.pResults
```

The presentation call waits for `render_finished_semaphore`, which should be
signaled after rendering has completed.

The `pResults` field is `null` because only one swap chain is being presented
and the function's return value is sufficient.

### Integrate acquisition and presentation into the frame loop

The exact synchronization fields depend on the existing frame-loop lesson. The
control flow should resemble this:

```zig
fn drawFrame(
    self: *HelloTriangleApplication,
    present_complete_semaphore: vk.VkSemaphore,
    render_finished_semaphore: vk.VkSemaphore,
) !void {
    const image_index = (try self.acquireSwapChainImage(
        present_complete_semaphore,
    )) orelse return;

    // Existing work belongs here:
    //
    // 1. Reset or select the command buffer.
    // 2. Record commands for image_index.
    // 3. Submit the command buffer.
    // 4. Signal render_finished_semaphore when rendering completes.
    //
    // The command submission must wait on present_complete_semaphore.

    try self.presentSwapChainImage(
        render_finished_semaphore,
        image_index,
    );
}
```

This method intentionally does not invent a new synchronization architecture. It
accepts the semaphores that the existing frame loop already owns.

The important sequence is:

```text
wait for frame synchronization
        |
        v
acquire swap-chain image
        |
        v
record or select commands for image_index
        |
        v
submit command buffer
        |
        v
present image
        |
        v
recreate if required
```

If the existing application has per-frame fences, wait for the appropriate fence
before acquisition and reset it only when a submission will occur. This avoids
the deadlock described in the source lesson: do not reset a fence and then skip
submission because acquisition returned `VK_ERROR_OUT_OF_DATE_KHR`.

### Avoid resetting a fence before a skipped frame

A common frame-loop mistake is:

```text
wait for fence
reset fence
acquire image
acquisition reports OUT_OF_DATE
return without submitting
```

The fence is now unsignaled, but no submitted work exists that can signal it.
The next frame may wait forever.

The safer order is:

```text
wait for fence
acquire image
if acquisition requires recreation:
    recreate
    return
reset fence
submit work
```

In raw Vulkan, fence operations use explicit C functions such as:

```zig
vk.vkWaitForFences(...)
vk.vkResetFences(...)
```

Every returned `VkResult` must be checked against:

```zig
vk.VK_SUCCESS
```

This synchronization rule is separate from swap-chain recreation, but the two
interact whenever acquisition returns `VK_ERROR_OUT_OF_DATE_KHR`.

### Update the main cleanup method

The existing `cleanup()` method should call `cleanupSwapChain()` before
destroying the logical device:

```zig
fn cleanup(self: *HelloTriangleApplication) void {
    if (self.device != null) {
        const result = vk.vkDeviceWaitIdle(self.device);
        if (result != vk.VK_SUCCESS) {
            std.log.warn(
                "vkDeviceWaitIdle failed during cleanup",
                .{},
            );
        }
    }

    self.cleanupSwapChain();

    // Existing cleanup continues here:
    //
    // Destroy command buffers and command pool.
    // Destroy shader modules and graphics resources.
    // vk.vkDestroyDevice(...)
    // vk.vkDestroySurfaceKHR(...)
    // destroy debug messenger
    // vk.vkDestroyInstance(...)
    // sdl.SDL_DestroyWindow(...)
    // sdl.SDL_Quit()
}
```

The exact placement of command-buffer, pipeline, and shader cleanup should
follow their dependencies. In particular, all resources using the logical device
must be destroyed before:

```zig
vk.vkDestroyDevice(...)
```

If the existing project already calls `cleanupSwapChain()` from `cleanup()`, do
not add a second call. Replace the old incomplete implementation with the
explicit version above.

### Complete lesson-specific merge example

The following shows the swap-chain-related additions together in the existing
application style:

```zig
const HelloTriangleApplication = struct {
    allocator: std.mem.Allocator,

    window: ?*sdl.SDL_Window = null,

    instance: vk.VkInstance = null,
    debug_messenger: vk.VkDebugUtilsMessengerEXT = null,
    surface: vk.VkSurfaceKHR = null,

    physical_device: vk.VkPhysicalDevice = null,
    device: vk.VkDevice = null,
    graphics_queue: vk.VkQueue = null,
    graphics_family: u32 = 0,

    swap_chain: vk.VkSwapchainKHR = null,
    swap_chain_images: []vk.VkImage = &.{},
    swap_chain_surface_format: vk.VkSurfaceFormatKHR = undefined,
    swap_chain_extent: vk.VkExtent2D = undefined,
    swap_chain_image_views: []vk.VkImageView = &.{},

    framebuffer_resized: bool = false,

    fn pollEvents(self: *HelloTriangleApplication) bool {
        var event: sdl.SDL_Event = undefined;
        var running = true;

        while (sdl.SDL_PollEvent(&event)) {
            switch (event.type) {
                sdl.SDL_EVENT_QUIT => {
                    running = false;
                },

                sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED,
                sdl.SDL_EVENT_WINDOW_RESIZED => {
                    self.framebuffer_resized = true;
                },

                else => {},
            }
        }

        return running;
    }

    fn cleanupSwapChain(self: *HelloTriangleApplication) void {
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

    fn waitForDrawableSize(self: *HelloTriangleApplication) !void {
        const window = self.window orelse return error.WindowNotCreated;

        while (true) {
            var width: c_int = 0;
            var height: c_int = 0;

            if (!sdl.SDL_GetWindowSizeInPixels(
                window,
                &width,
                &height,
            )) {
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

    fn recreateSwapChain(self: *HelloTriangleApplication) !void {
        if (self.device == null) {
            return error.DeviceNotCreated;
        }

        try self.waitForDrawableSize();

        const wait_result = vk.vkDeviceWaitIdle(self.device);
        if (wait_result != vk.VK_SUCCESS) {
            return error.FailedToWaitForDeviceIdle;
        }

        self.cleanupSwapChain();

        try self.createSwapChain();
        errdefer self.cleanupSwapChain();

        try self.createImageViews();

        self.framebuffer_resized = false;
    }

    fn acquireSwapChainImage(
        self: *HelloTriangleApplication,
        present_complete_semaphore: vk.VkSemaphore,
    ) !?u32 {
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

        if (result != vk.VK_SUCCESS and
            result != vk.VK_SUBOPTIMAL_KHR)
        {
            return error.FailedToAcquireSwapChainImage;
        }

        if (result == vk.VK_SUBOPTIMAL_KHR) {
            self.framebuffer_resized = true;
        }

        return image_index;
    }

    fn presentSwapChainImage(
        self: *HelloTriangleApplication,
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
            return error.FailedToPresentSwapChainImage;
        }

        if (self.framebuffer_resized) {
            try self.recreateSwapChain();
        }
    }

    // Existing methods remain in this struct:
    //
    // createSwapChain
    // createImageViews
    // drawFrame
    // cleanup
};
```

The methods assume that the existing project already provides:

```zig
fn createSwapChain(self: *HelloTriangleApplication) !void
fn createImageViews(self: *HelloTriangleApplication) !void
```

They should remain the same raw-binding methods introduced in the earlier
swap-chain lesson.

## Recap & What's Next

This lesson translated swap-chain recreation from C++ to Zig.

The C++ sequence:

```cpp
device.waitIdle();

cleanupSwapChain();

createSwapChain();
createImageViews();
```

became:

```zig
const wait_result = vk.vkDeviceWaitIdle(self.device);
if (wait_result != vk.VK_SUCCESS) {
    return error.FailedToWaitForDeviceIdle;
}

self.cleanupSwapChain();

try self.createSwapChain();
try self.createImageViews();
```

Important points:

- A swap chain is tied to the surface and drawable window size.
- `VK_ERROR_OUT_OF_DATE_KHR` means the swap chain must be recreated.
- `VK_SUBOPTIMAL_KHR` means recreation is recommended even if the current frame
  can continue.
- Raw Vulkan handles require explicit destruction.
- Image views must be destroyed before the swap chain.
- The allocator-owned slices for image views and swap-chain images must also be
  freed.
- SDL3 resize events set a flag instead of recreating resources inside event
  processing.
- A minimized window may have a zero drawable size and must be handled before
  creating a new swap chain.
- The frame loop must avoid resetting a fence if acquisition fails and no
  submission will follow.
- Resources such as depth images, framebuffers, command buffers, and pipelines
  may also need recreation if they depend on the old extent or format.

Next, Koba can make the frame loop fully robust by managing multiple frames in
flight, per-image fences, command-buffer re-recording, and synchronization
between image acquisition, rendering, and presentation.
