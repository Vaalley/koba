# Rendering and Presentation with Vulkan and Zig 0.16.0

## Overview

The previous Koba lessons created the resources needed to render:

1. SDL3 creates the window.
2. Vulkan creates an instance.
3. SDL3 creates a Vulkan surface.
4. Koba selects a physical device.
5. Koba creates a logical device and graphics queue.
6. Koba creates a swap chain.
7. Koba retrieves swap-chain images.
8. Koba creates image views.
9. Koba creates shader modules and a graphics pipeline.
10. Koba creates a command pool and command buffer.
11. Koba records rendering commands.

This lesson connects those pieces into a frame loop that submits work and presents an image:

```text
SDL events
    |
    v
wait for previous GPU work
    |
    v
acquire swap-chain image
    |
    v
record commands for that image
    |
    v
submit command buffer
    |
    v
present rendered image
```

The C++ source uses GLFW and Vulkan-Hpp RAII wrappers:

```cpp
while (!glfwWindowShouldClose(window)) {
    glfwPollEvents();
    drawFrame();
}
```

Koba uses SDL3 and raw Vulkan C bindings translated by `addTranslateC`. The corresponding calls are:

```zig
sdl.SDL_PollEvent(...)
vk.vkAcquireNextImageKHR(...)
vk.vkQueueSubmit(...)
vk.vkQueuePresentKHR(...)
```

No `vulkan-zig` proxy objects are introduced. Vulkan handles remain raw nullable handles such as:

```zig
vk.VkSemaphore
vk.VkFence
vk.VkCommandBuffer
```

This lesson extends the existing `HelloTriangleApplication` in `src/main.zig`.

---

## Concepts & Explanations

### Why synchronization is necessary

The CPU and GPU run asynchronously.

When the application submits a command buffer, the GPU may still be processing it while the CPU begins preparing the next frame. Without synchronization, the CPU could:

- reuse a command buffer that the GPU is still reading,
- acquire an image before the presentation engine releases it,
- overwrite resources still in use,
- present an image before rendering has finished.

The frame therefore uses three synchronization objects:

```text
present-complete semaphore
    |
    +--> signals that an acquired swap-chain image is available

draw fence
    |
    +--> signals that the submitted frame has finished

render-finished semaphore
    |
    +--> signals that rendering is complete and presentation may begin
```

### Semaphores synchronize GPU operations

A semaphore is primarily used between GPU operations or queue operations.

This frame uses two semaphores:

1. `present_complete_semaphore`
   - signaled by `vk.vkAcquireNextImageKHR`,
   - waited on by queue submission.

2. `render_finished_semaphore`
   - signaled when the submitted command buffer finishes,
   - waited on by presentation.

The dependency is:

```text
acquire image
    |
    | present_complete_semaphore
    v
submit rendering commands
    |
    | render_finished_semaphore
    v
present image
```

The CPU does not normally inspect a semaphore directly. It provides semaphores to Vulkan structures that describe GPU-side waits and signals.

### Fences synchronize the CPU with the GPU

A fence allows the CPU to wait until submitted GPU work is complete.

At the beginning of `drawFrame`, Koba waits for the previous submission's fence:

```zig
vk.vkWaitForFences(...)
```

Only after that wait succeeds is it safe to reuse the command buffer and submit another frame using the same fence.

The fence is created in the signaled state:

```zig
.flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
```

This matters because the first frame has not submitted any work yet. Without an initially signaled fence, the first call to `vk.vkWaitForFences` would wait forever.

### Why the fence is reset only after image acquisition

A subtle edge case occurs if image acquisition fails.

If the application resets the fence and then `vk.vkAcquireNextImageKHR` returns `VK_ERROR_OUT_OF_DATE_KHR`, no submission will signal the reset fence. Waiting on it during the next frame would block indefinitely.

This translation waits for the previous fence, acquires the image, and only then resets the fence:

```text
wait for previous submission
    |
    v
acquire image
    |
    +--> out of date: recreate later, do not reset fence
    |
    v
reset fence
    |
    v
submit work using that fence
```

This ordering is safer for swap-chain recreation.

### Why image acquisition is separate from rendering

The swap chain owns several images. The presentation engine decides which image is available next.

The application asks for an available image with:

```zig
vk.vkAcquireNextImageKHR(...)
```

The returned `image_index` selects matching entries in the swap-chain arrays:

```zig
self.swap_chain_images[image_index]
self.swap_chain_image_views[image_index]
```

The command buffer must record rendering commands for that selected image.

The image index is not a byte offset or an arbitrary application identifier. It is an index supplied by Vulkan and must be bounds-checked before converting it to a Zig slice index.

### `VK_SUBOPTIMAL_KHR` is not an immediate failure

Image acquisition and presentation can return:

```zig
vk.VK_SUBOPTIMAL_KHR
```

This means that the swap chain can still be used, but its configuration is no longer ideal. For example, the window may have changed size or display characteristics.

A renderer can continue using the returned image, but should normally recreate the swap chain when convenient.

By contrast:

```zig
vk.VK_ERROR_OUT_OF_DATE_KHR
```

usually means that the swap chain can no longer be used for the current surface configuration. A complete renderer should recreate it.

This lesson reports those conditions explicitly. Swap-chain recreation can be added in a later lesson without changing the synchronization model.

### Why the submit wait stage is color attachment output

The acquired swap-chain image must not be written until the acquire semaphore signals.

The submit structure uses:

```zig
vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
```

as the wait destination stage. This means the rendering work waits before the color-attachment stage writes the swap-chain image.

This matches the command buffer's use of the image as a color attachment.

The submit structure is a legacy Vulkan submission structure, so it uses the non-synchronization2 stage constant:

```zig
vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
```

That is different from the synchronization2 constant used inside image barriers:

```zig
vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT
```

The two constants belong to different Vulkan APIs and should not be mixed casually.

### Why presentation waits on the render-finished semaphore

Submitting a command buffer only schedules GPU work. It does not guarantee that rendering has completed when `vk.vkQueueSubmit` returns.

Presentation must wait until the color attachment has been rendered:

```text
queue submit
    |
    +--> signal render_finished_semaphore
              |
              v
        queue present
```

The `VkPresentInfoKHR` structure contains this wait semaphore:

```zig
.waitSemaphoreCount = 1
.pWaitSemaphores = &render_finished_semaphore
```

As a result, the presentation engine does not use the image until rendering has finished.

### Why the command buffer must be recorded for the acquired image

The command buffer's rendering attachment points at one image view:

```zig
.imageView = self.swap_chain_image_views[image_index]
```

Therefore, the command buffer must be recorded after image acquisition.

A simplified frame looks like this:

```text
acquire image index 2
    |
    v
record commands using image view 2
    |
    v
submit command buffer
    |
    v
present image 2
```

Recording once during initialization is not sufficient when the selected swap-chain image changes from frame to frame.

### The C++ subpass dependency is not used with dynamic rendering

The source includes a `vk::SubpassDependency`. That structure belongs to the traditional render-pass model:

```text
VkRenderPass
    |
    v
subpass dependency
```

Earlier Koba lessons use dynamic rendering:

```zig
vk.vkCmdBeginRendering(...)
vk.vkCmdEndRendering(...)
```

Dynamic rendering does not create a `VkRenderPass` or subpass, so a `VkSubpassDependency` should not be added to this path.

The equivalent synchronization for the dynamic-rendering path is already represented by the explicit `VkImageMemoryBarrier2` transitions recorded in the command buffer.

Do not add traditional render-pass dependencies unless the project changes back to `vk.vkCmdBeginRenderPass`.

### Cleanup order matters

Synchronization objects, command buffers, and command pools depend on the logical device.

A suitable cleanup order is:

```text
fence
semaphores
command buffer
command pool
graphics pipeline
shader module
image views
swap chain
logical device
surface
debug messenger
instance
SDL window
SDL
```

The exact order among independent device objects is less important than destroying every device-owned object before destroying the logical device.

---

## Code Translation Sections

### Add synchronization fields

Add these fields inside the existing `HelloTriangleApplication` struct:

```zig
present_complete_semaphore: vk.VkSemaphore = null,
render_finished_semaphore: vk.VkSemaphore = null,
draw_fence: vk.VkFence = null,
```

A combined rendering-resource section can look like this:

```zig
swap_chain_image_views: []vk.VkImageView = &.{},

shader_module: vk.VkShaderModule = null,
pipeline_layout: vk.VkPipelineLayout = null,
graphics_pipeline: vk.VkPipeline = null,

command_pool: vk.VkCommandPool = null,
command_buffer: vk.VkCommandBuffer = null,

present_complete_semaphore: vk.VkSemaphore = null,
render_finished_semaphore: vk.VkSemaphore = null,
draw_fence: vk.VkFence = null,
```

Each handle begins as `null`. In this project, `null` means that Koba does not currently own a valid Vulkan object.

### Extend Vulkan initialization

Append synchronization-object creation after command-buffer creation:

```zig
fn initVulkan(self: *HelloTriangleApplication) !void {
    try self.createInstance();
    try self.setupDebugMessenger();
    try self.createSurface();
    try self.pickPhysicalDevice();
    try self.createLogicalDevice();
    try self.createSwapChain();
    try self.createImageViews();
    try self.createShaderModules();
    try self.createGraphicsPipeline();
    try self.createCommandPool();
    try self.createCommandBuffer();
    try self.createSyncObjects();
}
```

Preserve any existing initialization calls from the project. The important dependency is:

```text
logical device
    |
    +--> command pool
    |       |
    |       +--> command buffer
    |
    +--> semaphores and fence
```

### Create the synchronization objects

Add this method inside `HelloTriangleApplication`:

```zig
fn createSyncObjects(self: *HelloTriangleApplication) !void {
    if (self.device == null) {
        return error.DeviceNotCreated;
    }

    if (self.present_complete_semaphore != null or
        self.render_finished_semaphore != null or
        self.draw_fence != null)
    {
        return error.SynchronizationObjectsAlreadyCreated;
    }

    const semaphore_info = vk.VkSemaphoreCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
    };

    var result = vk.vkCreateSemaphore(
        self.device,
        &semaphore_info,
        null,
        &self.present_complete_semaphore,
    );

    if (result != vk.VK_SUCCESS) {
        std.log.err("Failed to create image-acquisition semaphore", .{});
        return error.FailedToCreatePresentCompleteSemaphore;
    }

    errdefer {
        vk.vkDestroySemaphore(
            self.device,
            self.present_complete_semaphore,
            null,
        );
        self.present_complete_semaphore = null;
    }

    result = vk.vkCreateSemaphore(
        self.device,
        &semaphore_info,
        null,
        &self.render_finished_semaphore,
    );

    if (result != vk.VK_SUCCESS) {
        std.log.err("Failed to create render-finished semaphore", .{});
        return error.FailedToCreateRenderFinishedSemaphore;
    }

    errdefer {
        vk.vkDestroySemaphore(
            self.device,
            self.render_finished_semaphore,
            null,
        );
        self.render_finished_semaphore = null;
    }

    const fence_info = vk.VkFenceCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .pNext = null,
        .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
    };

    result = vk.vkCreateFence(
        self.device,
        &fence_info,
        null,
        &self.draw_fence,
    );

    if (result != vk.VK_SUCCESS) {
        std.log.err("Failed to create draw fence", .{});
        return error.FailedToCreateDrawFence;
    }

    std.log.debug("Created frame synchronization objects", .{});
}
```

The raw C binding requires an output pointer for each created handle. This is different from the C++ RAII constructor:

```cpp
vk::raii::Semaphore(device, semaphoreInfo)
```

The `errdefer` blocks prevent partially created synchronization objects from leaking if a later creation call fails.

### Add the frame loop

The GLFW loop:

```cpp
while (!glfwWindowShouldClose(window)) {
    glfwPollEvents();
    drawFrame();
}
```

becomes an SDL3 event loop:

```zig
fn mainLoop(self: *HelloTriangleApplication) !void {
    var running = true;

    while (running) {
        var event: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);

        while (sdl.SDL_PollEvent(&event)) {
            if (event.type == sdl.SDL_EVENT_QUIT) {
                running = false;
            }
        }

        if (running) {
            try self.drawFrame();
        }
    }

    if (self.device != null) {
        const result = vk.vkDeviceWaitIdle(self.device);

        if (result != vk.VK_SUCCESS) {
            std.log.err("Failed to wait for the device to become idle", .{});
            return error.FailedToWaitForDeviceIdle;
        }
    }
}
```

SDL3 does not use GLFW's `glfwWindowShouldClose`. The application instead observes SDL events and stops when it receives `SDL_EVENT_QUIT`.

`std.mem.zeroes` is appropriate for this C binding because `SDL_Event` is a C-style event union whose inactive fields do not need individual Zig initialization.

### Record the command buffer for the acquired image

The previous command-buffer lesson introduced `recordCommandBuffer`. Its call should receive the acquired image index.

If the existing method accepts a `usize`, use:

```zig
try self.recordCommandBuffer(
    self.command_buffer,
    @intCast(image_index),
);
```

If the project already stores the command buffer and its method accepts only an image index, use:

```zig
try self.recordCommandBuffer(@intCast(image_index));
```

The important rule is that the image index returned from Vulkan must be validated before it is used to index swap-chain arrays.

The command recording should contain the sequence already established in the previous lesson:

```text
transition image to color attachment layout
begin dynamic rendering
bind graphics pipeline
set viewport and scissor
draw
end dynamic rendering
transition image to presentation layout
```

### Wait for the previous frame

Add this helper:

```zig
fn waitForPreviousFrame(self: *HelloTriangleApplication) !void {
    const device = self.device orelse return error.DeviceNotCreated;
    const fence = self.draw_fence orelse return error.DrawFenceNotCreated;

    const result = vk.vkWaitForFences(
        device,
        1,
        &fence,
        vk.VK_TRUE,
        std.math.maxInt(u64),
    );

    if (result != vk.VK_SUCCESS) {
        std.log.err("Failed to wait for the previous frame", .{});
        return error.FailedToWaitForDrawFence;
    }
}
```

The timeout uses the largest `u64` value, which means “wait effectively forever” for this simple renderer.

A production engine may use a finite timeout so that it can detect a hung device or continue processing other engine tasks.

### Acquire the next swap-chain image

Add this helper:

```zig
fn acquireNextImage(self: *HelloTriangleApplication) !u32 {
    const device = self.device orelse return error.DeviceNotCreated;
    const swap_chain = self.swap_chain orelse return error.SwapChainNotCreated;
    const semaphore = self.present_complete_semaphore orelse {
        return error.PresentCompleteSemaphoreNotCreated;
    };

    var image_index: u32 = 0;

    const result = vk.vkAcquireNextImageKHR(
        device,
        swap_chain,
        std.math.maxInt(u64),
        semaphore,
        null,
        &image_index,
    );

    if (result == vk.VK_ERROR_OUT_OF_DATE_KHR) {
        std.log.warn(
            "Swap chain is out of date during image acquisition",
            .{},
        );
        return error.SwapChainOutOfDate;
    }

    if (result != vk.VK_SUCCESS and result != vk.VK_SUBOPTIMAL_KHR) {
        std.log.err("Failed to acquire a swap-chain image", .{});
        return error.FailedToAcquireSwapChainImage;
    }

    if (result == vk.VK_SUBOPTIMAL_KHR) {
        std.log.warn(
            "Swap chain is suboptimal during image acquisition",
            .{},
        );
    }

    const index: usize = @intCast(image_index);

    if (index >= self.swap_chain_images.len) {
        return error.AcquiredImageIndexOutOfBounds;
    }

    if (index >= self.swap_chain_image_views.len) {
        return error.AcquiredImageViewIndexOutOfBounds;
    }

    return image_index;
}
```

The `null` fence argument means that image availability is reported through the semaphore rather than a fence.

The returned image index is checked against both arrays because the command recorder will use both the image and its image view.

### Reset the frame fence

Add this helper:

```zig
fn resetDrawFence(self: *HelloTriangleApplication) !void {
    const device = self.device orelse return error.DeviceNotCreated;
    const fence = self.draw_fence orelse return error.DrawFenceNotCreated;

    const result = vk.vkResetFences(
        device,
        1,
        &fence,
    );

    if (result != vk.VK_SUCCESS) {
        std.log.err("Failed to reset draw fence", .{});
        return error.FailedToResetDrawFence;
    }
}
```

This is deliberately called after successful image acquisition. If acquisition reports that the swap chain is out of date, the fence remains signaled and can safely be waited on during the next frame.

### Submit the command buffer

Add this method:

```zig
fn submitCommandBuffer(self: *HelloTriangleApplication) !void {
    const queue = self.graphics_queue orelse {
        return error.GraphicsQueueNotCreated;
    };

    const command_buffer = self.command_buffer orelse {
        return error.CommandBufferNotCreated;
    };

    const present_complete_semaphore =
        self.present_complete_semaphore orelse {
            return error.PresentCompleteSemaphoreNotCreated;
        };

    const render_finished_semaphore =
        self.render_finished_semaphore orelse {
            return error.RenderFinishedSemaphoreNotCreated;
        };

    const draw_fence = self.draw_fence orelse {
        return error.DrawFenceNotCreated;
    };

    const wait_stage = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;

    const submit_info = vk.VkSubmitInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = null,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &present_complete_semaphore,
        .pWaitDstStageMask = &wait_stage,
        .commandBufferCount = 1,
        .pCommandBuffers = &command_buffer,
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &render_finished_semaphore,
    };

    const result = vk.vkQueueSubmit(
        queue,
        1,
        &submit_info,
        draw_fence,
    );

    if (result != vk.VK_SUCCESS) {
        std.log.err("Failed to submit the command buffer", .{});
        return error.FailedToSubmitCommandBuffer;
    }
}
```

The fields retain the raw Vulkan C names:

```zig
.sType
.waitSemaphoreCount
.pWaitSemaphores
.pWaitDstStageMask
.commandBufferCount
.pCommandBuffers
.signalSemaphoreCount
.pSignalSemaphores
```

The local variables are safe here because Vulkan reads the structures during the call that records the queue submission.

### Present the rendered image

Add this method:

```zig
fn presentImage(self: *HelloTriangleApplication, image_index: u32) !void {
    const queue = self.graphics_queue orelse {
        return error.GraphicsQueueNotCreated;
    };

    const swap_chain = self.swap_chain orelse {
        return error.SwapChainNotCreated;
    };

    const render_finished_semaphore =
        self.render_finished_semaphore orelse {
            return error.RenderFinishedSemaphoreNotCreated;
        };

    const present_info = vk.VkPresentInfoKHR{
        .sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .pNext = null,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &render_finished_semaphore,
        .swapchainCount = 1,
        .pSwapchains = &swap_chain,
        .pImageIndices = &image_index,
        .pResults = null,
    };

    const result = vk.vkQueuePresentKHR(
        queue,
        &present_info,
    );

    if (result == vk.VK_ERROR_OUT_OF_DATE_KHR) {
        std.log.warn(
            "Swap chain is out of date during presentation",
            .{},
        );
        return error.SwapChainOutOfDate;
    }

    if (result == vk.VK_SUBOPTIMAL_KHR) {
        std.log.warn(
            "Swap chain is suboptimal during presentation",
            .{},
        );
        return;
    }

    if (result != vk.VK_SUCCESS) {
        std.log.err("Failed to present the swap-chain image", .{});
        return error.FailedToPresentSwapChainImage;
    }
}
```

The `.pResults = null` field is intentional. Per-swap-chain results are optional when only one swap chain is being presented.

The presentation operation waits for `render_finished_semaphore`, ensuring that the submitted rendering commands have finished before the image is displayed.

### Combine the frame operations

Add this method inside `HelloTriangleApplication`:

```zig
fn drawFrame(self: *HelloTriangleApplication) !void {
    try self.waitForPreviousFrame();

    const image_index = self.acquireNextImage() catch |err| {
        if (err == error.SwapChainOutOfDate) {
            std.log.warn(
                "Frame skipped; swap-chain recreation is not implemented yet",
                .{},
            );
            return;
        }

        return err;
    };

    // Reset only after acquisition succeeds. If acquisition failed, the
    // fence remains signaled for the next frame.
    try self.resetDrawFence();

    const command_buffer = self.command_buffer orelse {
        return error.CommandBufferNotCreated;
    };

    const image_index_usize: usize = @intCast(image_index);

    if (image_index_usize >= self.swap_chain_images.len) {
        return error.AcquiredImageIndexOutOfBounds;
    }

    if (image_index_usize >= self.swap_chain_image_views.len) {
        return error.AcquiredImageViewIndexOutOfBounds;
    }

    // Use the command-recording method introduced in the previous lesson.
    // This form matches a method that receives the command buffer explicitly.
    try self.recordCommandBuffer(
        command_buffer,
        image_index_usize,
    );

    try self.submitCommandBuffer();

    self.presentImage(image_index) catch |err| {
        if (err == error.SwapChainOutOfDate) {
            std.log.warn(
                "Presentation requested swap-chain recreation",
                .{},
            );
            return;
        }

        return err;
    };

    std.log.debug(
        "Rendered and presented swap-chain image {d}",
        .{image_index},
    );
}
```

If the existing `recordCommandBuffer` method stores the command buffer as application state and accepts only an image index, replace the call with:

```zig
try self.recordCommandBuffer(image_index_usize);
```

Do not create a second command-buffer architecture just for this lesson.

### Add synchronization cleanup

Add this helper inside `HelloTriangleApplication`:

```zig
fn destroySyncObjects(self: *HelloTriangleApplication) void {
    const device = self.device orelse return;

    if (self.draw_fence != null) {
        vk.vkDestroyFence(device, self.draw_fence, null);
        self.draw_fence = null;
    }

    if (self.render_finished_semaphore != null) {
        vk.vkDestroySemaphore(
            device,
            self.render_finished_semaphore,
            null,
        );
        self.render_finished_semaphore = null;
    }

    if (self.present_complete_semaphore != null) {
        vk.vkDestroySemaphore(
            device,
            self.present_complete_semaphore,
            null,
        );
        self.present_complete_semaphore = null;
    }
}
```

Update the existing `cleanup()` method so these objects are destroyed before the command pool and logical device:

```zig
fn cleanup(self: *HelloTriangleApplication) void {
    self.destroySyncObjects();

    if (self.device != null and self.command_buffer != null and
        self.command_pool != null)
    {
        const command_buffer = self.command_buffer.?;

        vk.vkFreeCommandBuffers(
            self.device,
            self.command_pool,
            1,
            &command_buffer,
        );

        self.command_buffer = null;
    }

    if (self.device != null and self.command_pool != null) {
        vk.vkDestroyCommandPool(
            self.device,
            self.command_pool,
            null,
        );
        self.command_pool = null;
    }

    // Keep the existing cleanup for:
    // graphics pipeline
    // pipeline layout
    // shader module
    // image views
    // swap chain
    // device
    // surface
    // debug messenger
    // instance
    // SDL window
    // SDL_Quit
}
```

Merge this into the existing cleanup implementation rather than replacing cleanup with a new architecture.

The command-buffer pointer passed to `vk.vkFreeCommandBuffers` must remain valid during the call. A local unwrapped handle is useful because the application field is nullable.

### Complete lesson-specific `HelloTriangleApplication` additions

The following is the single target-language merge unit for this lesson. Place the fields and methods inside the existing `HelloTriangleApplication` declaration in `src/main.zig`:

```zig
const std = @import("std");
const sdl = @import("sdl3");
const vk = @import("vulkan");

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

    shader_module: vk.VkShaderModule = null,
    pipeline_layout: vk.VkPipelineLayout = null,
    graphics_pipeline: vk.VkPipeline = null,

    command_pool: vk.VkCommandPool = null,
    command_buffer: vk.VkCommandBuffer = null,

    present_complete_semaphore: vk.VkSemaphore = null,
    render_finished_semaphore: vk.VkSemaphore = null,
    draw_fence: vk.VkFence = null,

    fn initVulkan(self: *HelloTriangleApplication) !void {
        try self.createInstance();
        try self.setupDebugMessenger();
        try self.createSurface();
        try self.pickPhysicalDevice();
        try self.createLogicalDevice();
        try self.createSwapChain();
        try self.createImageViews();
        try self.createShaderModules();
        try self.createGraphicsPipeline();
        try self.createCommandPool();
        try self.createCommandBuffer();
        try self.createSyncObjects();
    }

    fn mainLoop(self: *HelloTriangleApplication) !void {
        var running = true;

        while (running) {
            var event: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);

            while (sdl.SDL_PollEvent(&event)) {
                if (event.type == sdl.SDL_EVENT_QUIT) {
                    running = false;
                }
            }

            if (running) {
                try self.drawFrame();
            }
        }

        const device = self.device orelse return;

        const result = vk.vkDeviceWaitIdle(device);
        if (result != vk.VK_SUCCESS) {
            std.log.err(
                "Failed to wait for the device to become idle",
                .{},
            );
            return error.FailedToWaitForDeviceIdle;
        }
    }

    fn createSyncObjects(self: *HelloTriangleApplication) !void {
        if (self.device == null) {
            return error.DeviceNotCreated;
        }

        const semaphore_info = vk.VkSemaphoreCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };

        var result = vk.vkCreateSemaphore(
            self.device,
            &semaphore_info,
            null,
            &self.present_complete_semaphore,
        );

        if (result != vk.VK_SUCCESS) {
            return error.FailedToCreatePresentCompleteSemaphore;
        }

        result = vk.vkCreateSemaphore(
            self.device,
            &semaphore_info,
            null,
            &self.render_finished_semaphore,
        );

        if (result != vk.VK_SUCCESS) {
            vk.vkDestroySemaphore(
                self.device,
                self.present_complete_semaphore,
                null,
            );
            self.present_complete_semaphore = null;
            return error.FailedToCreateRenderFinishedSemaphore;
        }

        const fence_info = vk.VkFenceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
        };

        result = vk.vkCreateFence(
            self.device,
            &fence_info,
            null,
            &self.draw_fence,
        );

        if (result != vk.VK_SUCCESS) {
            vk.vkDestroySemaphore(
                self.device,
                self.render_finished_semaphore,
                null,
            );
            vk.vkDestroySemaphore(
                self.device,
                self.present_complete_semaphore,
                null,
            );

            self.render_finished_semaphore = null;
            self.present_complete_semaphore = null;

            return error.FailedToCreateDrawFence;
        }
    }

    fn waitForPreviousFrame(self: *HelloTriangleApplication) !void {
        const device = self.device orelse return error.DeviceNotCreated;
        const fence = self.draw_fence orelse {
            return error.DrawFenceNotCreated;
        };

        const result = vk.vkWaitForFences(
            device,
            1,
            &fence,
            vk.VK_TRUE,
            std.math.maxInt(u64),
        );

        if (result != vk.VK_SUCCESS) {
            return error.FailedToWaitForDrawFence;
        }
    }

    fn acquireNextImage(self: *HelloTriangleApplication) !u32 {
        const device = self.device orelse return error.DeviceNotCreated;
        const swap_chain = self.swap_chain orelse {
            return error.SwapChainNotCreated;
        };
        const semaphore = self.present_complete_semaphore orelse {
            return error.PresentCompleteSemaphoreNotCreated;
        };

        var image_index: u32 = 0;

        const result = vk.vkAcquireNextImageKHR(
            device,
            swap_chain,
            std.math.maxInt(u64),
            semaphore,
            null,
            &image_index,
        );

        if (result == vk.VK_ERROR_OUT_OF_DATE_KHR) {
            return error.SwapChainOutOfDate;
        }

        if (result != vk.VK_SUCCESS and result != vk.VK_SUBOPTIMAL_KHR) {
            return error.FailedToAcquireSwapChainImage;
        }

        const index: usize = @intCast(image_index);

        if (index >= self.swap_chain_images.len) {
            return error.AcquiredImageIndexOutOfBounds;
        }

        if (index >= self.swap_chain_image_views.len) {
            return error.AcquiredImageViewIndexOutOfBounds;
        }

        return image_index;
    }

    fn resetDrawFence(self: *HelloTriangleApplication) !void {
        const device = self.device orelse return error.DeviceNotCreated;
        const fence = self.draw_fence orelse {
            return error.DrawFenceNotCreated;
        };

        const result = vk.vkResetFences(
            device,
            1,
            &fence,
        );

        if (result != vk.VK_SUCCESS) {
            return error.FailedToResetDrawFence;
        }
    }

    fn submitCommandBuffer(self: *HelloTriangleApplication) !void {
        const queue = self.graphics_queue orelse {
            return error.GraphicsQueueNotCreated;
        };
        const command_buffer = self.command_buffer orelse {
            return error.CommandBufferNotCreated;
        };
        const wait_semaphore = self.present_complete_semaphore orelse {
            return error.PresentCompleteSemaphoreNotCreated;
        };
        const signal_semaphore = self.render_finished_semaphore orelse {
            return error.RenderFinishedSemaphoreNotCreated;
        };
        const fence = self.draw_fence orelse {
            return error.DrawFenceNotCreated;
        };

        const wait_stage = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;

        const submit_info = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &wait_semaphore,
            .pWaitDstStageMask = &wait_stage,
            .commandBufferCount = 1,
            .pCommandBuffers = &command_buffer,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &signal_semaphore,
        };

        const result = vk.vkQueueSubmit(
            queue,
            1,
            &submit_info,
            fence,
        );

        if (result != vk.VK_SUCCESS) {
            return error.FailedToSubmitCommandBuffer;
        }
    }

    fn presentImage(
        self: *HelloTriangleApplication,
        image_index: u32,
    ) !void {
        const queue = self.graphics_queue orelse {
            return error.GraphicsQueueNotCreated;
        };
        const swap_chain = self.swap_chain orelse {
            return error.SwapChainNotCreated;
        };
        const wait_semaphore = self.render_finished_semaphore orelse {
            return error.RenderFinishedSemaphoreNotCreated;
        };

        const present_info = vk.VkPresentInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &wait_semaphore,
            .swapchainCount = 1,
            .pSwapchains = &swap_chain,
            .pImageIndices = &image_index,
            .pResults = null,
        };

        const result = vk.vkQueuePresentKHR(
            queue,
            &present_info,
        );

        if (result == vk.VK_ERROR_OUT_OF_DATE_KHR) {
            return error.SwapChainOutOfDate;
        }

        if (result == vk.VK_SUBOPTIMAL_KHR) {
            return;
        }

        if (result != vk.VK_SUCCESS) {
            return error.FailedToPresentSwapChainImage;
        }
    }

    fn drawFrame(self: *HelloTriangleApplication) !void {
        try self.waitForPreviousFrame();

        const image_index = self.acquireNextImage() catch |err| {
            if (err == error.SwapChainOutOfDate) {
                std.log.warn(
                    "Skipping frame because the swap chain is out of date",
                    .{},
                );
                return;
            }

            return err;
        };

        try self.resetDrawFence();

        const command_buffer = self.command_buffer orelse {
            return error.CommandBufferNotCreated;
        };

        const index: usize = @intCast(image_index);

        if (index >= self.swap_chain_images.len) {
            return error.AcquiredImageIndexOutOfBounds;
        }

        if (index >= self.swap_chain_image_views.len) {
            return error.AcquiredImageViewIndexOutOfBounds;
        }

        try self.recordCommandBuffer(
            command_buffer,
            index,
        );

        try self.submitCommandBuffer();

        self.presentImage(image_index) catch |err| {
            if (err == error.SwapChainOutOfDate) {
                std.log.warn(
                    "Presentation requires swap-chain recreation",
                    .{},
                );
                return;
            }

            return err;
        };
    }

    fn destroySyncObjects(self: *HelloTriangleApplication) void {
        const device = self.device orelse return;

        if (self.draw_fence != null) {
            vk.vkDestroyFence(device, self.draw_fence, null);
            self.draw_fence = null;
        }

        if (self.render_finished_semaphore != null) {
            vk.vkDestroySemaphore(
                device,
                self.render_finished_semaphore,
                null,
            );
            self.render_finished_semaphore = null;
        }

        if (self.present_complete_semaphore != null) {
            vk.vkDestroySemaphore(
                device,
                self.present_complete_semaphore,
                null,
            );
            self.present_complete_semaphore = null;
        }
    }

    // Existing Koba methods remain in this same struct:
    //
    // createInstance
    // setupDebugMessenger
    // createSurface
    // pickPhysicalDevice
    // createLogicalDevice
    // createSwapChain
    // createImageViews
    // createShaderModules
    // createGraphicsPipeline
    // createCommandPool
    // createCommandBuffer
    // recordCommandBuffer
    //
    // The existing cleanup method should call:
    //
    // self.destroySyncObjects();
    //
    // then free command_buffer, destroy command_pool, and continue
    // with the existing device-resource cleanup order.
};
```

The code uses the existing project imports and raw C binding names:

```zig
const std = @import("std");
const sdl = @import("sdl3");
const vk = @import("vulkan");
```

It does not add a new module, wrapper type, or application architecture.

---

## Recap & What's Next

This lesson connected Koba's recorded command buffer to the display system.

The C++ frame loop:

```cpp
while (!glfwWindowShouldClose(window)) {
    glfwPollEvents();
    drawFrame();
}
```

became an SDL3 loop that polls:

```zig
sdl.SDL_PollEvent(...)
```

and stops on:

```zig
sdl.SDL_EVENT_QUIT
```

The Vulkan frame now follows this sequence:

```text
wait for previous frame fence
    |
    v
acquire swap-chain image
    |
    v
reset fence
    |
    v
record command buffer for image index
    |
    v
submit command buffer
    |
    v
wait on render-finished semaphore
    |
    v
present image
```

Important points:

- Semaphores coordinate GPU-side operations.
- The fence lets the CPU know that previous GPU work is complete.
- The fence starts signaled so the first frame does not block forever.
- The fence is reset only after successful image acquisition.
- `VK_SUBOPTIMAL_KHR` means the swap chain still works but may need recreation.
- `VK_ERROR_OUT_OF_DATE_KHR` requires a later swap-chain recreation path.
- Dynamic rendering uses explicit image barriers rather than `VkSubpassDependency`.
- The raw Vulkan functions require explicit output pointers and `VkResult` checks.
- Synchronization objects must be destroyed before the logical device.

The renderer can now submit and present frames. The next important engine feature is swap-chain recreation: handling window resizing, minimized windows, out-of-date presentation, and rebuilding image views, pipeline-dependent state, and per-frame resources safely.