# Title

# Command Buffer Recording with Dynamic Rendering in Vulkan and Zig 0.16.0

## Overview

The previous Koba lessons created the resources needed to draw:

1. SDL3 creates the window.
2. Vulkan creates an instance.
3. SDL3 creates a Vulkan surface.
4. Koba selects a physical device.
5. Koba creates a logical device and graphics queue.
6. Koba creates a swap chain.
7. Koba retrieves swap-chain images.
8. Koba creates image views.
9. Koba loads SPIR-V shader code.
10. Koba creates shader stages and graphics-pipeline state.

This lesson records commands for one frame using **Vulkan dynamic rendering**.

The C++ source uses wrapper-style calls:

```cpp
commandBuffer.begin({});
commandBuffer.beginRendering(renderingInfo);
commandBuffer.endRendering();
commandBuffer.end();
```

Koba uses the raw C Vulkan bindings supplied by `addTranslateC`. The equivalent calls are:

```zig
vk.vkBeginCommandBuffer(...)
vk.vkCmdBeginRendering(...)
vk.vkCmdEndRendering(...)
vk.vkEndCommandBuffer(...)
```

The rendering sequence is:

```text
begin command buffer
        |
        v
transition swap-chain image to color-attachment layout
        |
        v
begin dynamic rendering
        |
        v
draw commands will be recorded here
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

This lesson extends the existing `HelloTriangleApplication` in `src/main.zig`. It does not introduce another application type or another module.

The imports remain:

```zig
const std = @import("std");
const sdl = @import("sdl3");
const vk = @import("vulkan");
```

## Concepts & Explanations

### Why command buffers matter

Vulkan does not usually execute drawing commands immediately when the application calls a rendering function. Instead, the application records commands into a command buffer.

A command buffer is a reusable description of GPU work:

```text
application code
      |
      v
command buffer
      |
      v
queue submission
      |
      v
GPU execution
```

This separation allows the engine to prepare work ahead of time and submit it efficiently to a graphics queue.

For a game engine, command buffers eventually contain commands such as:

- setting the viewport and scissor,
- binding a graphics pipeline,
- binding vertex and index buffers,
- binding material descriptors,
- issuing draw calls,
- transitioning images,
- copying buffers and textures.

The current lesson records the render-target setup. A later lesson can insert the actual pipeline and draw commands between `vk.vkCmdBeginRendering` and `vk.vkCmdEndRendering`.

### Why the image layout must change

A Vulkan image can be used in different layouts depending on the operation being performed.

The swap-chain image begins in an undefined or presentation layout. Before drawing, it must be in:

```zig
vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
```

After drawing, it must be in:

```zig
vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
```

The layout transition tells Vulkan how the image will be used next:

```text
presentation layout
        |
        v
color-attachment layout
        |
        v
rendering
        |
        v
presentation layout
```

Vulkan requires these transitions to be explicit because the driver may need to perform cache maintenance, memory synchronization, or other layout-specific work.

### Why synchronization2 is used

The C++ source uses the modern synchronization2 API:

```cpp
vk::AccessFlagBits2
vk::PipelineStageFlagBits2
```

The raw C Vulkan equivalent uses:

```zig
vk.VkImageMemoryBarrier2
vk.VkDependencyInfo
vk.vkCmdPipelineBarrier2(...)
```

A `VkImageMemoryBarrier2` describes:

- what operation was using the image before,
- what operation will use it next,
- the old layout,
- the new layout,
- which image and subresource range are affected.

The stage and access masks are not interchangeable:

- **pipeline stages** describe where execution occurs,
- **access masks** describe what kind of memory access occurs.

For example, color attachment writes occur at:

```zig
vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT
```

and use:

```zig
vk.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT
```

### Dynamic rendering replaces a render pass for this path

Traditional Vulkan rendering uses a `VkRenderPass` and one or more `VkFramebuffer` objects.

Dynamic rendering describes the attachments directly when recording commands:

```zig
vk.VkRenderingAttachmentInfo
vk.VkRenderingInfo
vk.vkCmdBeginRendering(...)
```

This reduces the amount of render-pass and framebuffer setup required for simple rendering paths.

The trade-offs are:

- **Benefit:** attachment descriptions are closer to the draw commands.
- **Benefit:** fewer framebuffer objects are needed.
- **Benefit:** render-target configurations can be easier to change.
- **Cost:** the physical device and logical device must support dynamic rendering.
- **Cost:** the graphics pipeline must be created with compatible dynamic-rendering information.

Vulkan 1.4 includes dynamic rendering as core functionality, but the required device feature still needs to be enabled during logical-device creation.

### Dynamic rendering does not remove pipeline compatibility

Dynamic rendering removes the need to begin a traditional render pass, but the graphics pipeline still needs to know the formats it will render into.

When the graphics pipeline was created, the pipeline-rendering information should match the swap-chain format, typically through:

```zig
vk.VkPipelineRenderingCreateInfo
```

The command buffer's color attachment must then use a compatible image view and format.

Dynamic rendering changes how rendering begins; it does not make pipeline state optional.

### Why the clear value is stored in the attachment

The attachment description contains:

```zig
.loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
.clearValue = clear_value,
```

This means that beginning rendering clears the color attachment before draw commands execute.

The alternative is:

```zig
.loadOp = vk.VK_ATTACHMENT_LOAD_OP_LOAD,
```

which preserves the previous contents. That is useful for techniques such as:

- incremental UI rendering,
- tiled rendering,
- multiple rendering passes.

For the first frame, clearing is simpler and avoids depending on the previous contents of a swap-chain image.

### Important edge case: `VK_IMAGE_LAYOUT_UNDEFINED`

The source uses:

```zig
.oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED
```

for the first transition. This is valid when the previous contents do not need to be preserved. The transition is allowed to discard the old image contents.

However, after presenting an image, the next use of that same image should normally use:

```zig
vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
```

as the old layout.

A production renderer therefore tracks the current layout of each swap-chain image, or uses a known swap-chain lifecycle where the old layout is guaranteed.

The simplified code below follows the supplied lesson and uses the source's `UNDEFINED` transition for the initial recording path. Do not assume that this is sufficient for swap-chain recreation or repeated frame reuse without additional layout tracking.

### Image index validation matters

The acquired image index comes from Vulkan. It must be used to index both:

```zig
self.swap_chain_images
self.swap_chain_image_views
```

Those arrays must have the same length and matching order:

```text
swap_chain_images[image_index]
        |
        +--> swap_chain_image_views[image_index]
```

The Zig method checks the index before accessing either slice. This turns a possible out-of-bounds memory access into an explicit error.

## Code Translation Sections

### Required device feature

Dynamic rendering must be enabled when the logical device is created.

For Vulkan 1.4, add the feature structure to the `pNext` chain used by `vk.VkDeviceCreateInfo`:

```zig
var dynamic_rendering_features = vk.VkPhysicalDeviceDynamicRenderingFeatures{
    .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES,
    .pNext = null,
    .dynamicRendering = vk.VK_TRUE,
};
```

Then connect it to the logical-device creation structure:

```zig
var device_create_info = vk.VkDeviceCreateInfo{
    .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
    .pNext = &dynamic_rendering_features,
    // Existing queue, feature, and extension fields remain here.
};
```

Keep the existing logical-device setup from earlier lessons. Do not replace it with a proxy or wrapper object.

If the existing project already enables dynamic rendering through another feature chain, keep one correctly connected feature structure rather than adding a duplicate.

### Add the command-recording method

Add this method inside the existing `HelloTriangleApplication` struct:

```zig
fn recordCommandBuffer(
    self: *HelloTriangleApplication,
    command_buffer: vk.VkCommandBuffer,
    image_index: usize,
) !void {
    if (image_index >= self.swap_chain_images.len) {
        return error.InvalidSwapChainImageIndex;
    }

    if (image_index >= self.swap_chain_image_views.len) {
        return error.ImageViewIndexOutOfBounds;
    }

    var begin_info = vk.VkCommandBufferBeginInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = 0,
        .pInheritanceInfo = null,
    };

    var result = vk.vkBeginCommandBuffer(
        command_buffer,
        &begin_info,
    );

    if (result != vk.VK_SUCCESS) {
        std.log.err("Failed to begin command buffer", .{});
        return error.FailedToBeginCommandBuffer;
    }

    errdefer {
        // The command buffer may be in a recording state here. The caller
        // owns command-buffer reset and reuse policy.
        std.log.debug("Command-buffer recording failed", .{});
    }

    const image = self.swap_chain_images[image_index];

    try self.transitionImageLayout(
        command_buffer,
        image,
        vk.VK_IMAGE_LAYOUT_UNDEFINED,
        vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        0,
        vk.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
        vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
    );

    var clear_value = vk.VkClearValue{
        .color = .{
            .float32 = .{
                0.0,
                0.0,
                0.0,
                1.0,
            },
        },
    };

    var attachment_info = vk.VkRenderingAttachmentInfo{
        .sType = vk.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .pNext = null,
        .imageView = self.swap_chain_image_views[image_index],
        .imageLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .resolveMode = vk.VK_RESOLVE_MODE_NONE,
        .resolveImageView = null,
        .resolveImageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue = clear_value,
    };

    var rendering_info = vk.VkRenderingInfo{
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
        command_buffer,
        &rendering_info,
    );

    // Future drawing commands belong here. For example:
    //
    // vk.vkCmdBindPipeline(
    //     command_buffer,
    //     vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
    //     self.graphics_pipeline,
    // );
    //
    // vk.vkCmdDraw(command_buffer, 3, 1, 0, 0);

    vk.vkCmdEndRendering(command_buffer);

    try self.transitionImageLayout(
        command_buffer,
        image,
        vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        vk.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
        0,
        vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        vk.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT,
    );

    result = vk.vkEndCommandBuffer(command_buffer);

    if (result != vk.VK_SUCCESS) {
        std.log.err("Failed to end command buffer", .{});
        return error.FailedToEndCommandBuffer;
    }

    std.log.debug(
        "Recorded command buffer for swap-chain image {d}",
        .{image_index},
    );
}
```

The function accepts a command buffer as an argument rather than inventing a new command-buffer architecture. The existing application can pass the command buffer it already allocates and manages.

### Record the image-layout transition

Add this helper inside `HelloTriangleApplication`:

```zig
fn transitionImageLayout(
    self: *HelloTriangleApplication,
    command_buffer: vk.VkCommandBuffer,
    image: vk.VkImage,
    old_layout: vk.VkImageLayout,
    new_layout: vk.VkImageLayout,
    src_access_mask: vk.VkAccessFlags2,
    dst_access_mask: vk.VkAccessFlags2,
    src_stage_mask: vk.VkPipelineStageFlags2,
    dst_stage_mask: vk.VkPipelineStageFlags2,
) !void {
    _ = self;

    var image_barrier = vk.VkImageMemoryBarrier2{
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
        .image = image,
        .subresourceRange = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };

    var dependency_info = vk.VkDependencyInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .pNext = null,
        .dependencyFlags = 0,
        .memoryBarrierCount = 0,
        .pMemoryBarriers = null,
        .bufferMemoryBarrierCount = 0,
        .pBufferMemoryBarriers = null,
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &image_barrier,
    };

    vk.vkCmdPipelineBarrier2(
        command_buffer,
        &dependency_info,
    );
}
```

The helper uses the raw Vulkan C names:

```zig
.sType
.srcStageMask
.srcAccessMask
.oldLayout
.newLayout
.subresourceRange
```

It does not use wrapper-style methods such as:

```zig
image.transitionLayout(...)
command_buffer.pipelineBarrier2(...)
```

### Why `pImageMemoryBarriers` points to a local variable

The dependency structure contains a pointer:

```zig
.pImageMemoryBarriers = &image_barrier
```

That pointer only needs to remain valid while `vk.vkCmdPipelineBarrier2` reads it. The call records the barrier into the command buffer before the local function returns, so a local structure is sufficient.

The same lifetime rule applies to:

```zig
.pColorAttachments = &attachment_info
```

and:

```zig
.pColorAttachments = &attachment_info
```

The structures must remain alive during the corresponding Vulkan call, not necessarily until the GPU executes the command.

### Adding the future draw commands

The dynamic-rendering section is intentionally empty:

```zig
vk.vkCmdBeginRendering(command_buffer, &rendering_info);

// Draw commands will be added here.

vk.vkCmdEndRendering(command_buffer);
```

When the graphics pipeline and command-buffer state are ready, the first triangle can be drawn with code similar to:

```zig
vk.vkCmdBindPipeline(
    command_buffer,
    vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
    self.graphics_pipeline,
);

var viewport = vk.VkViewport{
    .x = 0.0,
    .y = 0.0,
    .width = @floatFromInt(self.swap_chain_extent.width),
    .height = @floatFromInt(self.swap_chain_extent.height),
    .minDepth = 0.0,
    .maxDepth = 1.0,
};

var scissor = vk.VkRect2D{
    .offset = .{
        .x = 0,
        .y = 0,
    },
    .extent = self.swap_chain_extent,
};

vk.vkCmdSetViewport(command_buffer, 0, 1, &viewport);
vk.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

vk.vkCmdDraw(
    command_buffer,
    3,
    1,
    0,
    0,
);
```

This assumes the earlier fixed-function lesson made viewport and scissor dynamic.

The pipeline must be bound between beginning and ending dynamic rendering. A draw command outside that region does not have a color attachment to write into.

### Use the method from the existing frame loop

The existing frame loop should pass the acquired swap-chain image index to the recording method:

```zig
try self.recordCommandBuffer(
    command_buffer,
    image_index,
);
```

The exact synchronization and submission code remains part of the existing application. The important relationship is:

```text
acquire image
    |
    v
record commands for image_index
    |
    v
submit command buffer
    |
    v
present image_index
```

The command buffer must be submitted to a queue that can execute graphics commands. The presentation operation must use the same swap-chain image index acquired for this frame.

### Complete lesson-specific code to merge into `src/main.zig`

The following is the complete dynamic-rendering code for this lesson. Place both methods inside the existing `HelloTriangleApplication` struct.

```zig
fn recordCommandBuffer(
    self: *HelloTriangleApplication,
    command_buffer: vk.VkCommandBuffer,
    image_index: usize,
) !void {
    if (image_index >= self.swap_chain_images.len) {
        return error.InvalidSwapChainImageIndex;
    }

    if (image_index >= self.swap_chain_image_views.len) {
        return error.ImageViewIndexOutOfBounds;
    }

    var begin_info = vk.VkCommandBufferBeginInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = 0,
        .pInheritanceInfo = null,
    };

    var result = vk.vkBeginCommandBuffer(
        command_buffer,
        &begin_info,
    );

    if (result != vk.VK_SUCCESS) {
        std.log.err("Failed to begin command buffer", .{});
        return error.FailedToBeginCommandBuffer;
    }

    const image = self.swap_chain_images[image_index];

    try self.transitionImageLayout(
        command_buffer,
        image,
        vk.VK_IMAGE_LAYOUT_UNDEFINED,
        vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        0,
        vk.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
        vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
    );

    var clear_value = vk.VkClearValue{
        .color = .{
            .float32 = .{
                0.0,
                0.0,
                0.0,
                1.0,
            },
        },
    };

    var attachment_info = vk.VkRenderingAttachmentInfo{
        .sType = vk.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .pNext = null,
        .imageView = self.swap_chain_image_views[image_index],
        .imageLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .resolveMode = vk.VK_RESOLVE_MODE_NONE,
        .resolveImageView = null,
        .resolveImageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue = clear_value,
    };

    var rendering_info = vk.VkRenderingInfo{
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
        command_buffer,
        &rendering_info,
    );

    // Bind the graphics pipeline and issue drawing commands here.

    vk.vkCmdEndRendering(command_buffer);

    try self.transitionImageLayout(
        command_buffer,
        image,
        vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        vk.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
        0,
        vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        vk.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT,
    );

    result = vk.vkEndCommandBuffer(command_buffer);

    if (result != vk.VK_SUCCESS) {
        std.log.err("Failed to end command buffer", .{});
        return error.FailedToEndCommandBuffer;
    }
}

fn transitionImageLayout(
    self: *HelloTriangleApplication,
    command_buffer: vk.VkCommandBuffer,
    image: vk.VkImage,
    old_layout: vk.VkImageLayout,
    new_layout: vk.VkImageLayout,
    src_access_mask: vk.VkAccessFlags2,
    dst_access_mask: vk.VkAccessFlags2,
    src_stage_mask: vk.VkPipelineStageFlags2,
    dst_stage_mask: vk.VkPipelineStageFlags2,
) !void {
    _ = self;

    var image_barrier = vk.VkImageMemoryBarrier2{
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
        .image = image,
        .subresourceRange = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };

    var dependency_info = vk.VkDependencyInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .pNext = null,
        .dependencyFlags = 0,
        .memoryBarrierCount = 0,
        .pMemoryBarriers = null,
        .bufferMemoryBarrierCount = 0,
        .pBufferMemoryBarriers = null,
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &image_barrier,
    };

    vk.vkCmdPipelineBarrier2(
        command_buffer,
        &dependency_info,
    );
}
```

If the generated Vulkan translation names the synchronization2 flag types differently, use the exact typedef names generated from the installed `vulkan/vulkan.h`. The structure and function names above are the raw Vulkan API names and must not be replaced with proxy-wrapper types.

### Common confusion points

#### `vkCmdBeginRendering` does not clear the image by itself

The clear occurs because the attachment specifies:

```zig
.loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR
```

and provides:

```zig
.clearValue = clear_value
```

Without the clear load operation, the rendering operation may preserve the existing contents instead.

#### The image view is not the image

The barrier applies to:

```zig
.image = image
```

The rendering attachment uses:

```zig
.imageView = self.swap_chain_image_views[image_index]
```

The image is the storage object. The image view describes how rendering accesses that storage.

#### Dynamic rendering is not a substitute for synchronization

Dynamic rendering describes the render target. It does not automatically transition image layouts or synchronize previous and future accesses. The explicit `VkImageMemoryBarrier2` calls are still required.

#### The command buffer is not submitted by this method

`recordCommandBuffer` only records commands. The existing frame loop must submit the command buffer with `vk.vkQueueSubmit` and present the image afterward.

This separation is useful because recording and execution are different stages in Vulkan's model.

## Recap & What's Next

This lesson translated the C++ command-buffer recording sequence into raw Vulkan calls from Zig 0.16.0:

```cpp
commandBuffer.begin({});
```

became:

```zig
vk.vkBeginCommandBuffer(command_buffer, &begin_info);
```

Dynamic rendering became:

```zig
vk.vkCmdBeginRendering(command_buffer, &rendering_info);
// draw commands
vk.vkCmdEndRendering(command_buffer);
```

The image-layout transitions became:

```zig
vk.VkImageMemoryBarrier2
vk.VkDependencyInfo
vk.vkCmdPipelineBarrier2(...)
```

Important points:

- The swap-chain image is transitioned before rendering.
- The image view for the acquired image becomes the color attachment.
- The color attachment is cleared and stored.
- Dynamic rendering does not require a traditional render pass or framebuffer for this recording path.
- The graphics pipeline must still be compatible with the dynamic-rendering color format.
- Vulkan results from `vk.vkBeginCommandBuffer` and `vk.vkEndCommandBuffer` are checked explicitly.
- The image index is validated before indexing image and image-view slices.
- The logical device must enable dynamic rendering.
- The simplified `UNDEFINED` old layout is suitable only when previous contents may be discarded; repeated frame rendering eventually needs correct layout tracking.

Next, Koba can connect this recorded command buffer to synchronization and submission:

```text
acquire swap-chain image
        |
        v
wait for the frame's fence
        |
        v
record command buffer
        |
        v
submit with vk.vkQueueSubmit
        |
        v
present with vk.vkQueuePresentKHR
```

After that, the engine can add the graphics-pipeline bind and `vk.vkCmdDraw` call to produce the first visible triangle.