# Title

# Frames in Flight in Vulkan with Zig 0.16.0

## Overview

The previous Koba lessons created the objects needed to record and submit
rendering work:

1. SDL3 creates the window.
2. Vulkan creates an instance.
3. SDL3 creates a Vulkan surface.
4. Koba selects a physical device.
5. Koba creates a logical device and graphics queue.
6. Koba creates a swap chain.
7. Koba retrieves swap-chain images.
8. Koba creates image views.
9. Koba loads shader code.
10. Koba creates a graphics pipeline.
11. Koba creates a command pool.
12. Koba allocates command buffers.
13. Koba records rendering commands.

This lesson adds **frames in flight**.

A frame in flight is a frame whose GPU work has been submitted but may not have
finished yet. Rather than waiting for every frame to complete before starting
the next one, the CPU can prepare a limited number of frames ahead of the GPU.

Koba will use two frames in flight:

```zig
const max_frames_in_flight: usize = 2;
```

The frame loop becomes:

```text
wait for this frame's fence
        |
        v
reset this frame's fence
        |
        v
acquire a swap-chain image
        |
        v
reset and record this frame's command buffer
        |
        v
submit work, waiting on an acquire semaphore
        |
        v
signal a render-finished semaphore
        |
        v
advance to the next frame slot
```

The C++ source uses RAII containers:

```cpp
std::vector<vk::raii::CommandBuffer> commandBuffers;
std::vector<vk::raii::Semaphore> presentCompleteSemaphores;
std::vector<vk::raii::Semaphore> renderFinishedSemaphores;
std::vector<vk::raii::Fence> inFlightFences;
```

Koba uses raw Vulkan handles and allocator-owned Zig slices instead:

```zig
[]vk.VkCommandBuffer
[]vk.VkSemaphore
[]vk.VkFence
```

This lesson extends `HelloTriangleApplication` in `src/main.zig`. It does not
introduce a second application type or another module.

The imports remain:

```zig
const std = @import("std");
const sdl = @import("sdl3");
const vk = @import("vulkan");
```

## Concepts & Explanations

### Why multiple frames can be useful

If the CPU waits for the GPU after every submitted frame, the two devices cannot
work independently:

```text
CPU records frame 0
GPU executes frame 0
CPU records frame 1
GPU executes frame 1
```

The CPU may spend much of its time idle while the GPU renders.

With multiple frames in flight, the CPU can prepare another frame while the GPU
is still processing the previous one:

```text
CPU: GPU work for frame 0 | records frame 1 | records frame 2
GPU:                      | executes frame 0 | executes frame 1
```

This improves throughput and keeps the rendering pipeline busy.

There is a trade-off:

- More frames in flight can improve CPU/GPU overlap.
- More frames in flight can increase input latency.
- Each frame may require command buffers, semaphores, and fences.
- Too many frames can increase memory use and make synchronization harder.

Two frames is a common starting point because it provides overlap without
creating a large queue of old input.

### A frame slot is not the same as a swap-chain image

This distinction is one of the most important parts of the lesson.

A **frame slot** represents CPU/GPU synchronization state:

```text
frame_index = 0
    |
    +-- command_buffers[0]
    +-- present_complete_semaphores[0]
    +-- in_flight_fences[0]
```

A **swap-chain image index** identifies the image returned by Vulkan:

```text
image_index = 2
    |
    +-- swap_chain_images[2]
    +-- swap_chain_image_views[2]
    +-- render_finished_semaphores[2]
```

They are selected by different mechanisms:

- `frame_index` advances predictably with modulo arithmetic.
- `image_index` is returned by `vk.vkAcquireNextImageKHR`.

Therefore, a command buffer is indexed by `frame_index`, while the
render-finished semaphore in the supplied C++ source is indexed by
`image_index`.

Do not replace every index with the same value.

### Why fences and semaphores are both needed

Vulkan uses different synchronization objects for different participants.

A **fence** is primarily used by the CPU to observe GPU completion:

```text
GPU finishes submitted work
        |
        v
fence becomes signaled
        |
        v
CPU wait returns
```

A **semaphore** is used to order operations submitted to the GPU:

```text
swap-chain image acquisition
        |
        v
present-complete semaphore
        |
        v
graphics queue submission
```

The submitted rendering work signals another semaphore:

```text
rendering completes
        |
        v
render-finished semaphore
        |
        v
presentation
```

The current source only submits work. A later lesson will pass the
render-finished semaphore to `vk.vkQueuePresentKHR`.

### Why fences start signaled

The first call to `drawFrame` waits on `in_flight_fences[0]`.

If the fence began unsignaled, the first frame would wait forever because no
previous submission exists to signal it.

The C++ source creates fences with:

```cpp
vk::FenceCreateInfo{.flags = vk::FenceCreateFlagBits::eSignaled}
```

The raw Vulkan translation is:

```zig
.flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
```

This means the first wait succeeds immediately. After the first frame, the fence
is reset and associated with the submitted GPU work.

### Why the fence is reset after waiting

The frame loop follows this order:

```text
wait for fence
reset fence
submit work with that fence
```

Waiting confirms that the previous use of the frame slot has completed.
Resetting changes the fence back to the unsignaled state so the next queue
submission can signal it again.

Do not reset the fence before waiting unless the program has another way to
guarantee that the GPU is finished with the previous submission.

### Command buffers are reused by frame slot

The source allocates:

```cpp
MAX_FRAMES_IN_FLIGHT
```

command buffers rather than one command buffer per swap-chain image.

That produces this relationship:

```text
command_buffers[frame_index]
```

The command buffer belongs to the current CPU/GPU frame slot. During that frame,
it records commands for whichever swap-chain image Vulkan returns.

This is different from the earlier simplified lesson, which used one command
buffer. The old singular field should be replaced by a slice of command buffers.

### Why command-buffer reset must be checked

The C++ wrapper provides:

```cpp
commandBuffers[frameIndex].reset();
```

The raw binding requires:

```zig
const result = vk.vkResetCommandBuffer(
    self.command_buffers[frame_index],
    0,
);
```

The result must be checked explicitly. Resetting a command buffer that is still
in use by the GPU is invalid, which is why the fence is waited on first.

### The acquire semaphore orders image use

`vk.vkAcquireNextImageKHR` obtains ownership of a usable swap-chain image and
signals the supplied semaphore when acquisition is complete.

The queue submission waits on that semaphore:

```zig
.pWaitSemaphores = &self.present_complete_semaphores[frame_index],
```

The queue must not execute color-attachment commands before the acquired image
is ready.

The wait stage is:

```zig
vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
```

This says that the wait must be satisfied before the color-attachment stage
begins.

### The render-finished semaphore belongs to presentation

The submit operation signals a semaphore after the command buffer completes:

```zig
.pSignalSemaphores = &self.render_finished_semaphores[image_index],
```

The next presentation call will wait on that semaphore before displaying the
image.

The supplied source creates one render-finished semaphore per swap-chain image.
That is a valid design, but it is not the only possible design. Another common
design creates one render-finished semaphore per frame slot.

The important rule is consistency: the semaphore must not be reused while a
previous GPU operation may still signal it.

### Swap-chain recreation changes the allocation sizes

The number of swap-chain images can change after window resizing or surface
recreation.

When recreating the swap chain, Koba must also recreate any state sized by
`swap_chain_images.len`, including:

- `render_finished_semaphores`,
- command buffers if they are allocated per image,
- image views,
- layout-tracking arrays.

The frame-slot arrays are different:

- command buffers in this lesson have `MAX_FRAMES_IN_FLIGHT` entries,
- acquire semaphores have `MAX_FRAMES_IN_FLIGHT` entries,
- fences have `MAX_FRAMES_IN_FLIGHT` entries.

The render-finished array follows the supplied source and has one entry per
swap-chain image.

### The current source does not present yet

The supplied C++ `drawFrame` ends after `queue.submit`.

A complete frame loop will later call `vk.vkQueuePresentKHR`, waiting on the
render-finished semaphore. This lesson intentionally stops at submission so the
synchronization roles are clear.

Do not treat a successful queue submission as proof that an image has already
appeared on screen. Submission only places the work into the graphics queue.

## Code Translation Sections

### Add the frame-slot constant

Add this near the other module-level constants in `src/main.zig`:

```zig
const max_frames_in_flight: usize = 2;
```

The name follows Zig's lowercase naming convention while preserving the meaning
of the C++ constant.

This is a compile-time value, so it can be used for array sizes and for modulo
arithmetic.

### Replace the singular command-buffer field

If the previous lesson added:

```zig
command_buffer: vk.VkCommandBuffer = null,
```

replace it with:

```zig
command_buffers: []vk.VkCommandBuffer = &.{},
```

The synchronization fields are:

```zig
present_complete_semaphores: []vk.VkSemaphore = &.{},
render_finished_semaphores: []vk.VkSemaphore = &.{},
in_flight_fences: []vk.VkFence = &.{},

frame_index: usize = 0,
```

The relevant section of `HelloTriangleApplication` should look like this:

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

    shader_module: vk.VkShaderModule = null,
    pipeline_layout: vk.VkPipelineLayout = null,
    graphics_pipeline: vk.VkPipeline = null,

    command_pool: vk.VkCommandPool = null,
    command_buffers: []vk.VkCommandBuffer = &.{},

    present_complete_semaphores: []vk.VkSemaphore = &.{},
    render_finished_semaphores: []vk.VkSemaphore = &.{},
    in_flight_fences: []vk.VkFence = &.{},

    frame_index: usize = 0,

    // Existing methods remain in this struct.
};
```

The empty slices do not own memory. They are safe initial values for cleanup and
error handling. The slices become owned allocations only after their
corresponding creation methods succeed.

### Extend `initVulkan`

The initialization sequence must create frame resources after the command pool
exists:

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
    try self.createCommandBuffers();
    try self.createSyncObjects();
}
```

Preserve any existing initialization calls from earlier lessons. The important
dependencies are:

```text
logical device
    |
    +--> command pool
    |       |
    |       +--> command buffers
    |
    +--> semaphores
    +--> fences
```

### Allocate command buffers for frames in flight

The C++ code creates `MAX_FRAMES_IN_FLIGHT` primary command buffers. The raw
Vulkan translation is:

```zig
fn createCommandBuffers(self: *HelloTriangleApplication) !void {
    if (self.device == null) {
        return error.DeviceNotCreated;
    }

    if (self.command_pool == null) {
        return error.CommandPoolNotCreated;
    }

    if (self.command_buffers.len != 0) {
        return error.CommandBuffersAlreadyCreated;
    }

    self.command_buffers = try self.allocator.alloc(
        vk.VkCommandBuffer,
        max_frames_in_flight,
    );
    errdefer {
        self.allocator.free(self.command_buffers);
        self.command_buffers = &.{};
    }

    const alloc_info = vk.VkCommandBufferAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = self.command_pool,
        .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = max_frames_in_flight,
    };

    const result = vk.vkAllocateCommandBuffers(
        self.device,
        &alloc_info,
        self.command_buffers.ptr,
    );

    if (result != vk.VK_SUCCESS) {
        std.log.err("Failed to allocate command buffers", .{});
        return error.FailedToAllocateCommandBuffers;
    }

    std.log.debug(
        "Allocated {d} command buffers for frames in flight",
        .{max_frames_in_flight},
    );
}
```

The command-buffer allocation count is a `u32` in Vulkan. Zig can assign the
comptime-known `usize` value here when the translated declaration permits the
integer coercion. If the generated binding requires an explicit conversion, use:

```zig
.commandBufferCount = @intCast(max_frames_in_flight),
```

The output pointer is the beginning of the allocated slice:

```zig
self.command_buffers.ptr
```

The slice itself is application memory used to store the returned handles. The
command buffers are Vulkan objects owned by the command pool.

### Create the synchronization objects

The source creates:

- one render-finished semaphore per swap-chain image,
- one acquire semaphore per frame in flight,
- one fence per frame in flight.

Add this method inside `HelloTriangleApplication`:

```zig
fn createSyncObjects(self: *HelloTriangleApplication) !void {
    if (self.device == null) {
        return error.DeviceNotCreated;
    }

    if (self.swap_chain_images.len == 0) {
        return error.NoSwapChainImages;
    }

    if (self.present_complete_semaphores.len != 0 or
        self.render_finished_semaphores.len != 0 or
        self.in_flight_fences.len != 0)
    {
        return error.SyncObjectsAlreadyCreated;
    }

    self.present_complete_semaphores = try self.allocator.alloc(
        vk.VkSemaphore,
        max_frames_in_flight,
    );
    errdefer {
        self.allocator.free(self.present_complete_semaphores);
        self.present_complete_semaphores = &.{};
    }

    self.render_finished_semaphores = try self.allocator.alloc(
        vk.VkSemaphore,
        self.swap_chain_images.len,
    );
    errdefer {
        self.allocator.free(self.render_finished_semaphores);
        self.render_finished_semaphores = &.{};
    }

    self.in_flight_fences = try self.allocator.alloc(
        vk.VkFence,
        max_frames_in_flight,
    );
    errdefer {
        self.allocator.free(self.in_flight_fences);
        self.in_flight_fences = &.{};
    }

    const semaphore_info = vk.VkSemaphoreCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
    };

    const fence_info = vk.VkFenceCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .pNext = null,
        .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
    };

    var created_present_complete: usize = 0;
    errdefer {
        while (created_present_complete > 0) {
            created_present_complete -= 1;
            vk.vkDestroySemaphore(
                self.device,
                self.present_complete_semaphores[created_present_complete],
                null,
            );
        }
    }

    var created_render_finished: usize = 0;
    errdefer {
        while (created_render_finished > 0) {
            created_render_finished -= 1;
            vk.vkDestroySemaphore(
                self.device,
                self.render_finished_semaphores[created_render_finished],
                null,
            );
        }
    }

    var created_fences: usize = 0;
    errdefer {
        while (created_fences > 0) {
            created_fences -= 1;
            vk.vkDestroyFence(
                self.device,
                self.in_flight_fences[created_fences],
                null,
            );
        }
    }

    while (created_present_complete < max_frames_in_flight) : (created_present_complete += 1) {
        const result = vk.vkCreateSemaphore(
            self.device,
            &semaphore_info,
            null,
            &self.present_complete_semaphores[created_present_complete],
        );

        if (result != vk.VK_SUCCESS) {
            std.log.err(
                "Failed to create acquire semaphore for frame {d}",
                .{created_present_complete},
            );
            return error.FailedToCreateAcquireSemaphore;
        }
    }

    while (created_render_finished < self.swap_chain_images.len) : (created_render_finished += 1) {
        const result = vk.vkCreateSemaphore(
            self.device,
            &semaphore_info,
            null,
            &self.render_finished_semaphores[created_render_finished],
        );

        if (result != vk.VK_SUCCESS) {
            std.log.err(
                "Failed to create render-finished semaphore for image {d}",
                .{created_render_finished},
            );
            return error.FailedToCreateRenderFinishedSemaphore;
        }
    }

    while (created_fences < max_frames_in_flight) : (created_fences += 1) {
        const result = vk.vkCreateFence(
            self.device,
            &fence_info,
            null,
            &self.in_flight_fences[created_fences],
        );

        if (result != vk.VK_SUCCESS) {
            std.log.err(
                "Failed to create fence for frame {d}",
                .{created_fences},
            );
            return error.FailedToCreateInFlightFence;
        }
    }

    std.log.debug(
        "Created synchronization objects for {d} frames and {d} swap-chain images",
        .{
            max_frames_in_flight,
            self.swap_chain_images.len,
        },
    );
}
```

The `errdefer` blocks are important because synchronization creation can fail
partway through. For example, the first few semaphores may succeed while a later
semaphore fails. The already-created Vulkan objects must be destroyed before
returning the error.

### A shorter creation method

If the project already has a reliable cleanup path for partially initialized
objects, the creation loops can be shorter:

```zig
fn createSyncObjects(self: *HelloTriangleApplication) !void {
    self.present_complete_semaphores = try self.allocator.alloc(
        vk.VkSemaphore,
        max_frames_in_flight,
    );

    self.render_finished_semaphores = try self.allocator.alloc(
        vk.VkSemaphore,
        self.swap_chain_images.len,
    );

    self.in_flight_fences = try self.allocator.alloc(
        vk.VkFence,
        max_frames_in_flight,
    );

    // Create Vulkan objects and check every VkResult.
}
```

The longer version is preferable while learning because ownership and
partial-failure behavior are explicit.

### Add the frame index

The C++ source starts with:

```cpp
uint32_t frameIndex = 0;
```

The Zig field is:

```zig
frame_index: usize = 0,
```

A `usize` is convenient because it directly indexes Zig slices.

Advance it after submission:

```zig
self.frame_index =
    (self.frame_index + 1) % max_frames_in_flight;
```

Because `max_frames_in_flight` is two, the sequence is:

```text
0, 1, 0, 1, ...
```

### Implement `drawFrame`

Add this method inside `HelloTriangleApplication`:

```zig
fn drawFrame(self: *HelloTriangleApplication) !void {
    if (self.device == null) {
        return error.DeviceNotCreated;
    }

    if (self.graphics_queue == null) {
        return error.GraphicsQueueNotCreated;
    }

    if (self.swap_chain == null) {
        return error.SwapChainNotCreated;
    }

    if (self.command_buffers.len != max_frames_in_flight) {
        return error.CommandBuffersNotReady;
    }

    if (self.present_complete_semaphores.len != max_frames_in_flight) {
        return error.AcquireSemaphoresNotReady;
    }

    if (self.in_flight_fences.len != max_frames_in_flight) {
        return error.InFlightFencesNotReady;
    }

    if (self.render_finished_semaphores.len != self.swap_chain_images.len) {
        return error.RenderFinishedSemaphoresNotReady;
    }

    const frame_index = self.frame_index;

    var result = vk.vkWaitForFences(
        self.device,
        1,
        &self.in_flight_fences[frame_index],
        vk.VK_TRUE,
        std.math.maxInt(u64),
    );

    if (result != vk.VK_SUCCESS) {
        std.log.err(
            "Failed to wait for fence for frame {d}",
            .{frame_index},
        );
        return error.FailedToWaitForInFlightFence;
    }

    result = vk.vkResetFences(
        self.device,
        1,
        &self.in_flight_fences[frame_index],
    );

    if (result != vk.VK_SUCCESS) {
        std.log.err(
            "Failed to reset fence for frame {d}",
            .{frame_index},
        );
        return error.FailedToResetInFlightFence;
    }

    var image_index: u32 = 0;

    result = vk.vkAcquireNextImageKHR(
        self.device,
        std.math.maxInt(u64),
        self.present_complete_semaphores[frame_index],
        null,
        &image_index,
    );

    if (result == vk.VK_ERROR_OUT_OF_DATE_KHR) {
        return error.SwapChainOutOfDate;
    }

    if (result != vk.VK_SUCCESS and
        result != vk.VK_SUBOPTIMAL_KHR)
    {
        std.log.err("Failed to acquire a swap-chain image", .{});
        return error.FailedToAcquireSwapChainImage;
    }

    const image_index_usize: usize = @intCast(image_index);

    if (image_index_usize >= self.swap_chain_images.len) {
        return error.AcquiredImageIndexOutOfBounds;
    }

    if (image_index_usize >= self.render_finished_semaphores.len) {
        return error.RenderFinishedSemaphoreIndexOutOfBounds;
    }

    result = vk.vkResetCommandBuffer(
        self.command_buffers[frame_index],
        0,
    );

    if (result != vk.VK_SUCCESS) {
        std.log.err(
            "Failed to reset command buffer for frame {d}",
            .{frame_index},
        );
        return error.FailedToResetCommandBuffer;
    }

    try self.recordCommandBuffer(
        self.command_buffers[frame_index],
        image_index_usize,
    );

    const wait_stage = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;

    const submit_info = vk.VkSubmitInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = null,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &self.present_complete_semaphores[frame_index],
        .pWaitDstStageMask = &wait_stage,
        .commandBufferCount = 1,
        .pCommandBuffers = &self.command_buffers[frame_index],
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &self.render_finished_semaphores[image_index_usize],
    };

    result = vk.vkQueueSubmit(
        self.graphics_queue,
        1,
        &submit_info,
        self.in_flight_fences[frame_index],
    );

    if (result != vk.VK_SUCCESS) {
        std.log.err(
            "Failed to submit frame {d}",
            .{frame_index},
        );
        return error.FailedToSubmitFrame;
    }

    std.log.debug(
        "Submitted frame slot {d} for swap-chain image {d}",
        .{
            frame_index,
            image_index,
        },
    );

    self.frame_index =
        (self.frame_index + 1) % max_frames_in_flight;
}
```

This method assumes the existing lesson already provides:

```zig
fn recordCommandBuffer(
    self: *HelloTriangleApplication,
    command_buffer: vk.VkCommandBuffer,
    image_index: usize,
) !void
```

The command buffer is selected by frame slot, while the image index is supplied
by Vulkan.

### Why `VK_SUBOPTIMAL_KHR` is accepted

The acquire operation can return:

```zig
vk.VK_SUBOPTIMAL_KHR
```

This means that the swap chain is still usable, but it no longer matches the
surface perfectly. For example, a resize may be in progress.

The frame can often continue rendering in this situation. A later swap-chain
recreation lesson can mark the swap chain for recreation after the current
frame.

By contrast:

```zig
vk.VK_ERROR_OUT_OF_DATE_KHR
```

means that the swap chain can no longer be used as-is. The application should
recreate it instead of continuing with the old configuration.

### Raw translation of `vk::PipelineStageFlagBits`

The C++ submit code uses:

```cpp
vk::PipelineStageFlags waitDestinationStageMask(
    vk::PipelineStageFlagBits::eColorAttachmentOutput
);
```

The raw C binding uses the Vulkan C constant:

```zig
const wait_stage = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
```

This is not the synchronization2 stage constant. The submit structure here is
`VkSubmitInfo`, so it uses the original `VkPipelineStageFlags` type.

If a later lesson switches to `VkSubmitInfo2`, it must use the synchronization2
structures and flags consistently rather than mixing the two API forms.

### Record the command buffer for the acquired image

The existing command-recording method should receive the frame-selected command
buffer and the acquired image index:

```zig
try self.recordCommandBuffer(
    self.command_buffers[frame_index],
    image_index_usize,
);
```

The method can continue to use the image index to select:

```zig
self.swap_chain_images[image_index]
self.swap_chain_image_views[image_index]
```

The important relationship is now:

```text
frame_index
    |
    +--> command_buffers[frame_index]
    +--> present_complete_semaphores[frame_index]
    +--> in_flight_fences[frame_index]

image_index
    |
    +--> swap_chain_images[image_index]
    +--> swap_chain_image_views[image_index]
    +--> render_finished_semaphores[image_index]
```

### Add cleanup for synchronization objects

Synchronization objects must be destroyed before the logical device is
destroyed.

Add this method:

```zig
fn destroySyncObjects(self: *HelloTriangleApplication) void {
    if (self.device != null) {
        for (self.present_complete_semaphores) |semaphore| {
            if (semaphore != null) {
                vk.vkDestroySemaphore(
                    self.device,
                    semaphore,
                    null,
                );
            }
        }

        for (self.render_finished_semaphores) |semaphore| {
            if (semaphore != null) {
                vk.vkDestroySemaphore(
                    self.device,
                    semaphore,
                    null,
                );
            }
        }

        for (self.in_flight_fences) |fence| {
            if (fence != null) {
                vk.vkDestroyFence(
                    self.device,
                    fence,
                    null,
                );
            }
        }
    }

    if (self.present_complete_semaphores.len != 0) {
        self.allocator.free(self.present_complete_semaphores);
        self.present_complete_semaphores = &.{};
    }

    if (self.render_finished_semaphores.len != 0) {
        self.allocator.free(self.render_finished_semaphores);
        self.render_finished_semaphores = &.{};
    }

    if (self.in_flight_fences.len != 0) {
        self.allocator.free(self.in_flight_fences);
        self.in_flight_fences = &.{};
    }

    self.frame_index = 0;
}
```

The translated handle types may be nullable, as required by the project context.
The null checks make cleanup safe when creation failed before every array
element was initialized.

### Free command buffers before destroying the command pool

Add this method:

```zig
fn destroyCommandBuffers(self: *HelloTriangleApplication) void {
    if (self.device != null and
        self.command_pool != null and
        self.command_buffers.len != 0)
    {
        vk.vkFreeCommandBuffers(
            self.device,
            self.command_pool,
            @intCast(self.command_buffers.len),
            self.command_buffers.ptr,
        );
    }

    if (self.command_buffers.len != 0) {
        self.allocator.free(self.command_buffers);
        self.command_buffers = &.{};
    }
}
```

The dependency order is:

```text
command buffers
        |
        v
command pool
        |
        v
logical device
```

Therefore, call `destroyCommandBuffers` before:

```zig
vk.vkDestroyCommandPool(...)
```

### Extend the existing cleanup order

The existing project cleanup order starts with device-owned objects and ends
with SDL:

```text
device-owned resources
logical device
surface
debug messenger
instance
SDL window
SDL
```

The frame-specific portion should be:

```zig
fn cleanup(self: *HelloTriangleApplication) void {
    self.destroySyncObjects();
    self.destroyCommandBuffers();

    if (self.command_pool != null and self.device != null) {
        vk.vkDestroyCommandPool(
            self.device,
            self.command_pool,
            null,
        );
        self.command_pool = null;
    }

    // Existing cleanup continues:
    //
    // graphics pipeline
    // pipeline layout
    // shader module
    // image views
    // swap chain
    // logical device
    // surface
    // debug messenger
    // instance
    // SDL window
    // SDL_Quit
}
```

If the existing cleanup method already destroys the command pool, insert the two
new helper calls immediately before that destruction. Do not destroy the logical
device before these resources.

### Call `drawFrame` from the existing main loop

The existing SDL event loop can call:

```zig
while (running) {
    var event: sdl.SDL_Event = undefined;

    while (sdl.SDL_PollEvent(&event)) {
        if (event.type == sdl.SDL_EVENT_QUIT) {
            running = false;
        }
    }

    if (running) {
        try app.drawFrame();
    }
}
```

The exact event-loop variables should follow the existing `src/main.zig`. The
important change is that rendering now submits one frame at a time while cycling
through the frame slots.

A later lesson will add:

```zig
vk.vkQueuePresentKHR(...)
```

after submission and will handle swap-chain recreation when the window changes
size.

## Recap & What's Next

This lesson translated the C++ frames-in-flight code into raw Vulkan calls using
Zig slices and explicit ownership.

The main translations were:

```cpp
constexpr int MAX_FRAMES_IN_FLIGHT = 2;
```

became:

```zig
const max_frames_in_flight: usize = 2;
```

RAII command-buffer allocation:

```cpp
commandBuffers = vk::raii::CommandBuffers(device, allocInfo);
```

became:

```zig
self.command_buffers = try self.allocator.alloc(
    vk.VkCommandBuffer,
    max_frames_in_flight,
);

try check the result from vk.vkAllocateCommandBuffers(...);
```

Fence waiting became:

```zig
const result = vk.vkWaitForFences(
    self.device,
    1,
    &self.in_flight_fences[frame_index],
    vk.VK_TRUE,
    std.math.maxInt(u64),
);
```

Semaphore and fence creation use raw Vulkan structures:

```zig
vk.VkSemaphoreCreateInfo
vk.VkFenceCreateInfo
vk.vkCreateSemaphore(...)
vk.vkCreateFence(...)
```

Queue submission uses:

```zig
vk.VkSubmitInfo
vk.vkQueueSubmit(...)
```

Important concepts:

- A frame slot is different from a swap-chain image index.
- Fences let the CPU wait for GPU completion.
- Semaphores order GPU operations.
- Fences begin signaled so the first frame can proceed.
- Command buffers are reset only after their previous GPU work has completed.
- `VK_SUBOPTIMAL_KHR` can be usable, while `VK_ERROR_OUT_OF_DATE_KHR` generally
  requires swap-chain recreation.
- Every Vulkan result is checked explicitly.
- Device-owned synchronization objects and command buffers are destroyed before
  the logical device.

The next step is to present the rendered image with `vk.vkQueuePresentKHR`. That
lesson will connect the render-finished semaphore to presentation and handle the
resize and swap-chain-recreation cases that can occur while frames are in
flight.
