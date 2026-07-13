# Command Buffers in Vulkan with Zig 0.16.0

## Overview

The previous lessons created the resources needed to render:

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

This lesson adds command-buffer support.

A command buffer is a recorded list of GPU instructions. Vulkan separates **recording commands** from **executing commands**:

```text
create command pool
        |
        v
allocate command buffer
        |
        v
record rendering commands
        |
        v
submit command buffer to graphics queue
```

The command buffer created here will:

1. transition a swap-chain image into a color-attachment layout,
2. begin dynamic rendering,
3. bind the graphics pipeline,
4. set the viewport and scissor,
5. draw three vertices,
6. end dynamic rendering,
7. transition the image into a presentation layout.

This lesson records commands but does not yet add semaphores, fences, image acquisition, queue submission, or presentation. Those synchronization and frame-loop steps belong to the next part of the renderer.

Koba continues to use the existing `HelloTriangleApplication` in `src/main.zig` and the raw translated C bindings:

```zig
const std = @import("std");
const sdl = @import("sdl3");
const vk = @import("vulkan");
```

No Vulkan proxy wrappers are introduced.

---

## Concepts & Explanations

### Why command buffers exist

A Vulkan application does not issue most drawing commands directly to the GPU. Instead, it records commands into a `VkCommandBuffer`.

This design gives Vulkan several advantages:

- command recording can happen before execution,
- command buffers can be reused,
- multiple CPU threads can record different command buffers,
- the driver can validate and prepare command streams efficiently,
- the application controls exactly what work is submitted.

For a game engine, command buffers are the bridge between high-level scene decisions and GPU execution:

```text
scene and renderer systems
        |
        v
recorded Vulkan commands
        |
        v
graphics queue
        |
        v
GPU execution
```

The trade-off is that Vulkan requires more explicit lifetime and synchronization management than a higher-level graphics API.

### Command pools own command-buffer allocation

A command buffer is allocated from a command pool.

The relationship is:

```text
logical device
      |
      v
command pool
      |
      v
command buffer
```

A command pool is associated with one queue family. This lesson uses `self.graphics_family`, which was selected when the physical device and logical device were created.

A command pool is not itself a queue. It is an allocator and reset context for command buffers.

### Why the command pool allows command-buffer reset

The C++ source uses:

```cpp
vk::CommandPoolCreateFlagBits::eResetCommandBuffer
```

The raw Vulkan equivalent is:

```zig
vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT
```

This flag allows an individual command buffer to be reset and recorded again without resetting the entire command pool.

That is convenient for a first renderer because the same command buffer can be reused every frame.

The trade-off is that command-pool reset behavior and allocation strategy can affect performance. More advanced engines often use:

- one pool per recording thread,
- one pool per frame in flight,
- separate transient pools for short-lived work,
- pool reset instead of individual command-buffer reset.

### Primary command buffers

The command buffer is allocated with:

```zig
.level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY
```

A primary command buffer can be submitted directly to a queue.

A secondary command buffer cannot be submitted by itself. It must be executed from a primary command buffer. Secondary buffers are useful when several systems or threads record portions of a frame independently, but they add another layer of organization.

For the first triangle, a single primary command buffer is the simplest correct choice.

### Recording is not execution

Calling:

```zig
vk.vkBeginCommandBuffer(...)
vk.vkCmdDraw(...)
vk.vkEndCommandBuffer(...)
```

only records commands.

The GPU does not execute them until the command buffer is submitted to a queue with a call such as:

```zig
vk.vkQueueSubmit(...)
```

This distinction is important:

```text
recordCommandBuffer()
        |
        v
commands stored in command buffer
        |
        v
vkQueueSubmit()
        |
        v
GPU executes commands
```

The current lesson deliberately stops after recording. The next lesson can connect the recorded command buffer to swap-chain image acquisition, queue submission, and presentation.

### Why image layout transitions are needed

A Vulkan image has a layout that describes how the image is being used.

The swap-chain image begins in an undefined or presentation-related state. Before rendering, it must be transitioned to:

```zig
vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
```

After rendering, it must be transitioned to:

```zig
vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
```

The intended sequence is:

```text
present source
      |
      v
color attachment optimal
      |
      v
rendering
      |
      v
present source
```

A layout transition is also a memory dependency. It tells Vulkan:

- what previous operations may have touched the image,
- what future operations will do with the image,
- which pipeline stages must wait for one another.

Without the correct transition, validation errors or visual corruption are likely.

### Synchronization 2 barriers

The source uses:

```cpp
vk::ImageMemoryBarrier2
vk::DependencyInfo
commandBuffer.pipelineBarrier2(...)
```

The raw Vulkan bindings use:

```zig
vk.VkImageMemoryBarrier2
vk.VkDependencyInfo
vk.vkCmdPipelineBarrier2(...)
```

`VkImageMemoryBarrier2` describes one image transition. `VkDependencyInfo` packages one or more memory, buffer, and image barriers.

The first transition uses:

```zig
.srcStageMask = 0,
.srcAccessMask = 0,
.dstStageMask = vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
.dstAccessMask = vk.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
```

This means there is no previous operation that Koba needs to wait for in this initial example. The color-attachment output stage must wait before writing.

The second transition uses:

```zig
.srcStageMask = vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
.srcAccessMask = vk.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
.dstStageMask = vk.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT,
.dstAccessMask = 0,
```

This makes color writes available before the image is used for presentation.

The exact synchronization masks become more important once the frame loop has semaphores and multiple frames in flight.

### Dynamic rendering does not use a render pass object

This lesson follows the supplied source, which uses dynamic rendering:

```cpp
commandBuffer.beginRendering(renderingInfo);
```

The raw Vulkan call is:

```zig
vk.vkCmdBeginRendering(command_buffer, &rendering_info);
```

Dynamic rendering describes the active color attachment directly in the command buffer. It does not require a traditional `VkRenderPass` and framebuffer object for this draw.

The rendering relationship is:

```text
swap-chain image view
        |
        v
VkRenderingAttachmentInfo
        |
        v
VkRenderingInfo
        |
        v
vkCmdBeginRendering
```

This differs from the earlier render-pass-based pipeline description. If the existing graphics pipeline was created for dynamic rendering, it must include the appropriate `VkPipelineRenderingCreateInfo` in its `pNext` chain and use a null render-pass handle. If the existing pipeline was created with a traditional render pass, the command-buffer code must instead use `vkCmdBeginRenderPass`.

Do not mix the two models accidentally.

### Clear values and load/store operations

The dynamic-rendering attachment uses:

```zig
.loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
.storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
```

This means:

- clear the image when rendering begins,
- preserve the rendered result after rendering ends.

The clear color is black with full opacity:

```zig
.float32 = .{ 0.0, 0.0, 0.0, 1.0 }
```

A game engine may later use:

- `LOAD` when preserving an existing render target,
- `DONT_CARE` when the old contents are irrelevant,
- `STORE` when the image will be displayed or sampled,
- `DONT_CARE` when the result will never be used.

These choices affect performance and must match how the image is used.

### Dynamic viewport and scissor state must be set

The earlier pipeline configuration made the viewport and scissor dynamic. Therefore, the command buffer must set both values before drawing:

```zig
vk.vkCmdSetViewport(...)
vk.vkCmdSetScissor(...)
```

If either command is omitted, the pipeline has required dynamic state that was never provided.

The viewport uses floating-point dimensions:

```zig
.width = @floatFromInt(self.swap_chain_extent.width),
.height = @floatFromInt(self.swap_chain_extent.height),
```

The scissor uses integer extent values directly.

### Command-buffer lifetime and cleanup

The command buffer must be freed before its command pool:

```text
command buffer
      |
      v
command pool
      |
      v
logical device
```

The command buffer is not destroyed with `vk.vkDestroyCommandBuffer`. It is returned to its pool using:

```zig
vk.vkFreeCommandBuffers(...)
```

The command pool is destroyed with:

```zig
vk.vkDestroyCommandPool(...)
```

Both objects must be cleaned up before destroying the logical device.

---

## Code Translation Sections

### Add command-buffer state

Add these fields to the existing `HelloTriangleApplication` struct:

```zig
command_pool: vk.VkCommandPool = null,
command_buffer: vk.VkCommandBuffer = null,
```

Place them near the other rendering resources:

```zig
swap_chain_image_views: []vk.VkImageView = &.{},

shader_module: vk.VkShaderModule = null,
pipeline_layout: vk.VkPipelineLayout = null,
graphics_pipeline: vk.VkPipeline = null,

command_pool: vk.VkCommandPool = null,
command_buffer: vk.VkCommandBuffer = null,
```

The handles are nullable because `null` means that Koba does not currently own the corresponding Vulkan object.

### Extend `initVulkan`

The C++ initialization sequence becomes:

```cpp
createCommandPool();
createCommandBuffer();
```

The Zig version appends the equivalent calls to the existing method:

```zig
fn initVulkan(self: *HelloTriangleApplication) !void {
    try self.createInstance();
    try self.setupDebugMessenger();
    try self.createSurface();
    try self.pickPhysicalDevice();
    try self.createLogicalDevice();
    try self.createSwapChain();
    try self.createImageViews();
    try self.createGraphicsPipeline();
    try self.createCommandPool();
    try self.createCommandBuffer();
}
```

The command pool requires the logical device and the selected graphics queue-family index. The command buffer requires the command pool and logical device, so this ordering is required.

If the existing lesson creates shader modules or other resources between image views and the pipeline, preserve those existing calls and place the command-pool calls after pipeline creation.

### Create the command pool

The C++ source creates:

```cpp
vk::CommandPoolCreateInfo poolInfo{
    .flags = vk::CommandPoolCreateFlagBits::eResetCommandBuffer,
    .queueFamilyIndex = queueIndex
};
```

The raw C-binding translation is:

```zig
fn createCommandPool(self: *HelloTriangleApplication) !void {
    if (self.device == null) {
        return error.DeviceNotCreated;
    }

    if (self.command_pool != null) {
        return error.CommandPoolAlreadyCreated;
    }

    const pool_info = vk.VkCommandPoolCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .pNext = null,
        .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = self.graphics_family,
    };

    const result = vk.vkCreateCommandPool(
        self.device,
        &pool_info,
        null,
        &self.command_pool,
    );

    if (result != vk.VK_SUCCESS) {
        std.log.err("Failed to create command pool", .{});
        return error.FailedToCreateCommandPool;
    }

    std.log.debug("Created Vulkan command pool", .{});
}
```

The command pool is tied to `self.graphics_family`, not directly to `self.graphics_queue`. A queue is obtained from a queue family, and command buffers allocated from this pool are intended for submission to queues in that family.

### Allocate a primary command buffer

The C++ source uses:

```cpp
vk::CommandBufferAllocateInfo allocInfo{
    .commandPool = commandPool,
    .level = vk::CommandBufferLevel::ePrimary,
    .commandBufferCount = 1
};
```

The raw binding version is:

```zig
fn createCommandBuffer(self: *HelloTriangleApplication) !void {
    if (self.device == null) {
        return error.DeviceNotCreated;
    }

    if (self.command_pool == null) {
        return error.CommandPoolNotCreated;
    }

    if (self.command_buffer != null) {
        return error.CommandBufferAlreadyCreated;
    }

    const alloc_info = vk.VkCommandBufferAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = self.command_pool,
        .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };

    const result = vk.vkAllocateCommandBuffers(
        self.device,
        &alloc_info,
        &self.command_buffer,
    );

    if (result != vk.VK_SUCCESS) {
        std.log.err("Failed to allocate command buffer", .{});
        return error.FailedToAllocateCommandBuffer;
    }

    std.log.debug("Allocated primary command buffer", .{});
}
```

Unlike the C++ RAII version, the raw C API writes the allocated handle into an output pointer.

Only one command buffer is allocated because this lesson records one image at a time. A complete renderer will usually allocate one command buffer per frame in flight or per swap-chain image.

### Begin and end command-buffer recording

The command buffer must be placed into the recording state before commands are added:

```zig
const begin_info = vk.VkCommandBufferBeginInfo{
    .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
    .pNext = null,
    .flags = 0,
    .pInheritanceInfo = null,
};

const result = vk.vkBeginCommandBuffer(
    self.command_buffer,
    &begin_info,
);
```

After all commands have been recorded, call:

```zig
const result = vk.vkEndCommandBuffer(self.command_buffer);
```

Both functions return `VkResult` and must be checked explicitly.

The command buffer cannot be submitted while it is still recording.

### Add a helper for image layout transitions

Add this method inside `HelloTriangleApplication`:

```zig
fn transitionImageLayout(
    self: *HelloTriangleApplication,
    image_index: u32,
    old_layout: vk.VkImageLayout,
    new_layout: vk.VkImageLayout,
    src_access_mask: vk.VkAccessFlags2,
    dst_access_mask: vk.VkAccessFlags2,
    src_stage_mask: vk.VkPipelineStageFlags2,
    dst_stage_mask: vk.VkPipelineStageFlags2,
) !void {
    if (self.command_buffer == null) {
        return error.CommandBufferNotCreated;
    }

    const image_index_usize: usize = @intCast(image_index);

    if (image_index_usize >= self.swap_chain_images.len) {
        return error.SwapChainImageIndexOutOfRange;
    }

    const barrier = vk.VkImageMemoryBarrier2{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .pNext = null,
        .srcStageMask = src_stage_mask,
        .srcAccessMask = src_access_mask,
        .dstStageMask = dst_stage_mask,
        .dstAccessMask = dst_access_mask,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .image = self.swap_chain_images[image_index_usize],
        .subresourceRange = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };

    const dependency_info = vk.VkDependencyInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .pNext = null,
        .dependencyFlags = 0,
        .memoryBarrierCount = 0,
        .pMemoryBarriers = null,
        .bufferMemoryBarrierCount = 0,
        .pBufferMemoryBarriers = null,
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &barrier,
    };

    vk.vkCmdPipelineBarrier2(
        self.command_buffer,
        &dependency_info,
    );
}
```

This method uses the swap-chain image handle, not the image-view handle. Layout transitions operate on images.

The image view is used later when dynamic rendering describes the color attachment.

### Record the rendering commands

Add the following method:

```zig
fn recordCommandBuffer(
    self: *HelloTriangleApplication,
    image_index: u32,
) !void {
    if (self.command_buffer == null) {
        return error.CommandBufferNotCreated;
    }

    if (self.graphics_pipeline == null) {
        return error.GraphicsPipelineNotCreated;
    }

    const image_index_usize: usize = @intCast(image_index);

    if (image_index_usize >= self.swap_chain_images.len) {
        return error.SwapChainImageIndexOutOfRange;
    }

    if (image_index_usize >= self.swap_chain_image_views.len) {
        return error.SwapChainImageViewIndexOutOfRange;
    }

    const begin_info = vk.VkCommandBufferBeginInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = 0,
        .pInheritanceInfo = null,
    };

    var result = vk.vkBeginCommandBuffer(
        self.command_buffer,
        &begin_info,
    );

    if (result != vk.VK_SUCCESS) {
        std.log.err("Failed to begin command-buffer recording", .{});
        return error.FailedToBeginCommandBuffer;
    }

    errdefer {
        _ = vk.vkEndCommandBuffer(self.command_buffer);
    }

    try self.transitionImageLayout(
        image_index,
        vk.VK_IMAGE_LAYOUT_UNDEFINED,
        vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        0,
        vk.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
        0,
        vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
    );

    const clear_value = vk.VkClearValue{
        .color = .{
            .float32 = .{ 0.0, 0.0, 0.0, 1.0 },
        },
    };

    const attachment_info = vk.VkRenderingAttachmentInfo{
        .sType = vk.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .pNext = null,
        .imageView = self.swap_chain_image_views[image_index_usize],
        .imageLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .resolveMode = vk.VK_RESOLVE_MODE_NONE,
        .resolveImageView = null,
        .resolveImageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue = clear_value,
    };

    const rendering_info = vk.VkRenderingInfo{
        .sType = vk.VK_STRUCTURE_TYPE_RENDERING_INFO,
        .pNext = null,
        .flags = 0,
        .renderArea = .{
            .offset = .{
                .x = 0,
                .y = 0,
            },
            .extent = self.swap_chain_extent,
        },
        .layerCount = 1,
        .viewMask = 0,
        .colorAttachmentCount = 1,
        .pColorAttachments = &attachment_info,
        .pDepthAttachment = null,
        .pStencilAttachment = null,
    };

    vk.vkCmdBeginRendering(
        self.command_buffer,
        &rendering_info,
    );

    vk.vkCmdBindPipeline(
        self.command_buffer,
        vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
        self.graphics_pipeline,
    );

    const viewport = vk.VkViewport{
        .x = 0.0,
        .y = 0.0,
        .width = @floatFromInt(self.swap_chain_extent.width),
        .height = @floatFromInt(self.swap_chain_extent.height),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };

    vk.vkCmdSetViewport(
        self.command_buffer,
        0,
        1,
        &viewport,
    );

    const scissor = vk.VkRect2D{
        .offset = .{
            .x = 0,
            .y = 0,
        },
        .extent = self.swap_chain_extent,
    };

    vk.vkCmdSetScissor(
        self.command_buffer,
        0,
        1,
        &scissor,
    );

    vk.vkCmdDraw(
        self.command_buffer,
        3,
        1,
        0,
        0,
    );

    vk.vkCmdEndRendering(self.command_buffer);

    try self.transitionImageLayout(
        image_index,
        vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        vk.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
        0,
        vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        vk.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT,
    );

    result = vk.vkEndCommandBuffer(self.command_buffer);

    if (result != vk.VK_SUCCESS) {
        std.log.err("Failed to finish command-buffer recording", .{});
        return error.FailedToEndCommandBuffer;
    }

    std.log.debug("Recorded command buffer for swap-chain image {d}", .{
        image_index,
    });
}
```

The method uses `image_index` to connect three resources:

```text
swap_chain_images[image_index]
swap_chain_image_views[image_index]
recorded rendering commands
```

This matching index is important. Rendering with the image view for one swap-chain image while transitioning another image would produce invalid synchronization and incorrect output.

### Why `errdefer` is used while recording

Once `vkBeginCommandBuffer` succeeds, an error during recording can leave the command buffer in the recording state.

The `errdefer` block attempts to end recording if a later helper returns an error:

```zig
errdefer {
    _ = vk.vkEndCommandBuffer(self.command_buffer);
}
```

This is useful for a teaching implementation because it keeps the command buffer from being left open on ordinary error paths.

A production renderer may reset the command buffer explicitly after a failed recording attempt. The exact recovery strategy depends on the frame scheduler.

### Reset before recording again

Because the command pool was created with:

```zig
vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT
```

the command buffer can be reset before being recorded for another frame:

```zig
fn resetCommandBuffer(
    self: *HelloTriangleApplication,
) !void {
    if (self.command_buffer == null) {
        return error.CommandBufferNotCreated;
    }

    const result = vk.vkResetCommandBuffer(
        self.command_buffer,
        0,
    );

    if (result != vk.VK_SUCCESS) {
        std.log.err("Failed to reset command buffer", .{});
        return error.FailedToResetCommandBuffer;
    }
}
```

The frame loop will eventually use:

```zig
try self.resetCommandBuffer();
try self.recordCommandBuffer(image_index);
```

Do not reset a command buffer while the GPU is still executing it. A fence or another synchronization mechanism must first prove that the previous submission has completed.

### Free the command buffer and destroy the command pool

Add this cleanup helper:

```zig
fn destroyCommandResources(
    self: *HelloTriangleApplication,
) void {
    if (self.command_buffer != null) {
        if (self.command_pool != null and self.device != null) {
            vk.vkFreeCommandBuffers(
                self.device,
                self.command_pool,
                1,
                &self.command_buffer,
            );
        }

        self.command_buffer = null;
    }

    if (self.command_pool != null and self.device != null) {
        vk.vkDestroyCommandPool(
            self.device,
            self.command_pool,
            null,
        );

        self.command_pool = null;
    }
}
```

Call this helper from the existing `cleanup()` method before destroying the logical device:

```zig
fn cleanup(self: *HelloTriangleApplication) void {
    // Destroy graphics pipeline and related resources first,
    // using the cleanup order already established by earlier lessons.

    self.destroyCommandResources();

    // Existing cleanup continues:
    // destroy image views
    // destroy swap chain
    // destroy shader modules
    // destroy device
    // destroy surface
    // destroy debug messenger
    // destroy instance
    // destroy SDL window
    // call SDL_Quit
}
```

The exact position relative to the graphics pipeline depends on which Vulkan objects the command buffer may reference. The important rule is that the command buffer must no longer be in use before its pool or device is destroyed.

If the application waits for the device to become idle during shutdown, that wait should happen before freeing command buffers:

```zig
const result = vk.vkDeviceWaitIdle(self.device);
if (result != vk.VK_SUCCESS) {
    std.log.err("Failed to wait for Vulkan device idle", .{});
}
```

Keep the project's existing cleanup policy if it already performs this wait.

### Complete command-buffer additions to merge into `src/main.zig`

The following is the command-buffer-specific portion to add inside the existing `HelloTriangleApplication` struct:

```zig
command_pool: vk.VkCommandPool = null,
command_buffer: vk.VkCommandBuffer = null,

fn createCommandPool(self: *HelloTriangleApplication) !void {
    if (self.device == null) {
        return error.DeviceNotCreated;
    }

    if (self.command_pool != null) {
        return error.CommandPoolAlreadyCreated;
    }

    const pool_info = vk.VkCommandPoolCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .pNext = null,
        .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = self.graphics_family,
    };

    const result = vk.vkCreateCommandPool(
        self.device,
        &pool_info,
        null,
        &self.command_pool,
    );

    if (result != vk.VK_SUCCESS) {
        return error.FailedToCreateCommandPool;
    }
}

fn createCommandBuffer(self: *HelloTriangleApplication) !void {
    if (self.device == null) {
        return error.DeviceNotCreated;
    }

    if (self.command_pool == null) {
        return error.CommandPoolNotCreated;
    }

    if (self.command_buffer != null) {
        return error.CommandBufferAlreadyCreated;
    }

    const alloc_info = vk.VkCommandBufferAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = self.command_pool,
        .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };

    const result = vk.vkAllocateCommandBuffers(
        self.device,
        &alloc_info,
        &self.command_buffer,
    );

    if (result != vk.VK_SUCCESS) {
        return error.FailedToAllocateCommandBuffer;
    }
}

fn transitionImageLayout(
    self: *HelloTriangleApplication,
    image_index: u32,
    old_layout: vk.VkImageLayout,
    new_layout: vk.VkImageLayout,
    src_access_mask: vk.VkAccessFlags2,
    dst_access_mask: vk.VkAccessFlags2,
    src_stage_mask: vk.VkPipelineStageFlags2,
    dst_stage_mask: vk.VkPipelineStageFlags2,
) !void {
    if (self.command_buffer == null) {
        return error.CommandBufferNotCreated;
    }

    const index: usize = @intCast(image_index);

    if (index >= self.swap_chain_images.len) {
        return error.SwapChainImageIndexOutOfRange;
    }

    const barrier = vk.VkImageMemoryBarrier2{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .pNext = null,
        .srcStageMask = src_stage_mask,
        .srcAccessMask = src_access_mask,
        .dstStageMask = dst_stage_mask,
        .dstAccessMask = dst_access_mask,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .image = self.swap_chain_images[index],
        .subresourceRange = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };

    const dependency_info = vk.VkDependencyInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .pNext = null,
        .dependencyFlags = 0,
        .memoryBarrierCount = 0,
        .pMemoryBarriers = null,
        .bufferMemoryBarrierCount = 0,
        .pBufferMemoryBarriers = null,
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &barrier,
    };

    vk.vkCmdPipelineBarrier2(
        self.command_buffer,
        &dependency_info,
    );
}

fn recordCommandBuffer(
    self: *HelloTriangleApplication,
    image_index: u32,
) !void {
    if (self.command_buffer == null) {
        return error.CommandBufferNotCreated;
    }

    if (self.graphics_pipeline == null) {
        return error.GraphicsPipelineNotCreated;
    }

    const index: usize = @intCast(image_index);

    if (index >= self.swap_chain_images.len) {
        return error.SwapChainImageIndexOutOfRange;
    }

    if (index >= self.swap_chain_image_views.len) {
        return error.SwapChainImageViewIndexOutOfRange;
    }

    const begin_info = vk.VkCommandBufferBeginInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = 0,
        .pInheritanceInfo = null,
    };

    var result = vk.vkBeginCommandBuffer(
        self.command_buffer,
        &begin_info,
    );

    if (result != vk.VK_SUCCESS) {
        return error.FailedToBeginCommandBuffer;
    }

    errdefer {
        _ = vk.vkEndCommandBuffer(self.command_buffer);
    }

    try self.transitionImageLayout(
        image_index,
        vk.VK_IMAGE_LAYOUT_UNDEFINED,
        vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        0,
        vk.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
        0,
        vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
    );

    const clear_value = vk.VkClearValue{
        .color = .{
            .float32 = .{ 0.0, 0.0, 0.0, 1.0 },
        },
    };

    const attachment_info = vk.VkRenderingAttachmentInfo{
        .sType = vk.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .pNext = null,
        .imageView = self.swap_chain_image_views[index],
        .imageLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .resolveMode = vk.VK_RESOLVE_MODE_NONE,
        .resolveImageView = null,
        .resolveImageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue = clear_value,
    };

    const rendering_info = vk.VkRenderingInfo{
        .sType = vk.VK_STRUCTURE_TYPE_RENDERING_INFO,
        .pNext = null,
        .flags = 0,
        .renderArea = .{
            .offset = .{
                .x = 0,
                .y = 0,
            },
            .extent = self.swap_chain_extent,
        },
        .layerCount = 1,
        .viewMask = 0,
        .colorAttachmentCount = 1,
        .pColorAttachments = &attachment_info,
        .pDepthAttachment = null,
        .pStencilAttachment = null,
    };

    vk.vkCmdBeginRendering(
        self.command_buffer,
        &rendering_info,
    );

    vk.vkCmdBindPipeline(
        self.command_buffer,
        vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
        self.graphics_pipeline,
    );

    const viewport = vk.VkViewport{
        .x = 0.0,
        .y = 0.0,
        .width = @floatFromInt(self.swap_chain_extent.width),
        .height = @floatFromInt(self.swap_chain_extent.height),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };

    vk.vkCmdSetViewport(
        self.command_buffer,
        0,
        1,
        &viewport,
    );

    const scissor = vk.VkRect2D{
        .offset = .{
            .x = 0,
            .y = 0,
        },
        .extent = self.swap_chain_extent,
    };

    vk.vkCmdSetScissor(
        self.command_buffer,
        0,
        1,
        &scissor,
    );

    vk.vkCmdDraw(
        self.command_buffer,
        3,
        1,
        0,
        0,
    );

    vk.vkCmdEndRendering(self.command_buffer);

    try self.transitionImageLayout(
        image_index,
        vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        vk.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
        0,
        vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        vk.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT,
    );

    result = vk.vkEndCommandBuffer(self.command_buffer);

    if (result != vk.VK_SUCCESS) {
        return error.FailedToEndCommandBuffer;
    }
}

fn destroyCommandResources(
    self: *HelloTriangleApplication,
) void {
    if (self.command_buffer != null) {
        if (self.device != null and self.command_pool != null) {
            vk.vkFreeCommandBuffers(
                self.device,
                self.command_pool,
                1,
                &self.command_buffer,
            );
        }

        self.command_buffer = null;
    }

    if (self.command_pool != null and self.device != null) {
        vk.vkDestroyCommandPool(
            self.device,
            self.command_pool,
            null,
        );

        self.command_pool = null;
    }
}
```

Add these calls to the existing initialization method:

```zig
try self.createCommandPool();
try self.createCommandBuffer();
```

Add this call to cleanup before destroying the logical device:

```zig
self.destroyCommandResources();
```

The surrounding fields and methods remain those already present in `src/main.zig`.

### Important dynamic-rendering compatibility note

The command-buffer code above uses dynamic rendering. Therefore, the graphics pipeline must also have been created for dynamic rendering.

The pipeline creation code normally places a `VkPipelineRenderingCreateInfo` structure in the pipeline create-info `pNext` chain:

```zig
const pipeline_rendering_info = vk.VkPipelineRenderingCreateInfo{
    .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
    .pNext = null,
    .viewMask = 0,
    .colorAttachmentCount = 1,
    .pColorAttachmentFormats = &self.swap_chain_surface_format.format,
    .depthAttachmentFormat = vk.VK_FORMAT_UNDEFINED,
    .stencilAttachmentFormat = vk.VK_FORMAT_UNDEFINED,
};
```

The pipeline create info then uses:

```zig
.pNext = &pipeline_rendering_info,
.renderPass = null,
.subpass = 0,
```

If the existing project instead uses a traditional render pass, replace the dynamic-rendering commands with the corresponding render-pass and framebuffer commands. The two approaches are alternatives, not interchangeable command sequences.

### Likely issue: `VkClearValue` union syntax

Raw translated C unions can appear slightly differently depending on the exact Zig translate-C output. The intended structure is:

```zig
vk.VkClearValue{
    .color = .{
        .float32 = .{ 0.0, 0.0, 0.0, 1.0 },
    },
}
```

If the generated binding exposes the union members under a different translated spelling, inspect the generated `vulkan` module. Do not replace the raw Vulkan type with a wrapper-library clear-value type.

The Vulkan field names in the surrounding structures must remain the C names:

```zig
.sType
.imageView
.imageLayout
.loadOp
.storeOp
.clearValue
```

### Likely issue: synchronization feature support

`vk.vkCmdPipelineBarrier2` is part of Vulkan's synchronization2 functionality. With Vulkan 1.4, the feature is normally available through the core API, but the logical device still needs the relevant feature enabled according to the physical-device feature configuration.

If validation reports that synchronization2 is unavailable, verify the logical-device feature chain and the selected Vulkan API version.

### Likely issue: the first layout may not be `UNDEFINED`

The example uses:

```zig
vk.VK_IMAGE_LAYOUT_UNDEFINED
```

for the first transition because the initial contents are discarded by the clear operation.

After the first frame, the image will normally be in presentation layout. Once acquisition and submission are implemented, the transition should reflect the actual image state and synchronization supplied by the frame loop.

Do not blindly use `UNDEFINED` if the renderer needs to preserve the old image contents.

---

## Recap & What's Next

This lesson translated the command-buffer portion of the C++ Vulkan tutorial into Zig:

```cpp
vk::raii::CommandPool commandPool = nullptr;
```

became:

```zig
command_pool: vk.VkCommandPool = null,
```

and:

```cpp
vk::raii::CommandBuffer commandBuffer = nullptr;
```

became:

```zig
command_buffer: vk.VkCommandBuffer = null,
```

The main additions were:

- creation of a resettable command pool,
- allocation of a primary command buffer,
- explicit Vulkan result checking,
- image layout transitions with synchronization2,
- dynamic rendering commands,
- pipeline binding,
- dynamic viewport and scissor setup,
- a three-vertex draw command,
- command-buffer and command-pool cleanup.

The rendering commands now form this sequence:

```text
begin command buffer
        |
        v
transition image to color attachment
        |
        v
begin dynamic rendering
        |
        v
bind graphics pipeline
        |
        v
set viewport and scissor
        |
        v
draw three vertices
        |
        v
end dynamic rendering
        |
        v
transition image to presentation layout
        |
        v
end command buffer
```

Important points:

- Recording commands does not execute them.
- The command buffer must eventually be submitted to `graphics_queue`.
- The command pool must use the graphics queue-family index.
- A command buffer must not be reset or freed while the GPU is using it.
- Image views and swap-chain images must use the same image index.
- Dynamic rendering must match how the graphics pipeline was created.
- Command buffers must be freed before their command pool and before the logical device.

Next, Koba can add the frame loop:

1. wait for a frame fence,
2. acquire a swap-chain image,
3. reset and record the command buffer,
4. submit it to the graphics queue,
5. present the rendered image,
6. handle swap-chain recreation when the window is resized or minimized.