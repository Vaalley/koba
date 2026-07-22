# Image Views in Vulkan with Zig 0.16.0 and SDL3

## Overview

The previous lessons built the resources needed to obtain images for rendering:

1. Koba creates an SDL3 window.
2. Vulkan creates an instance.
3. SDL3 creates a Vulkan surface.
4. Koba selects a physical device.
5. Koba creates a logical device and graphics queue.
6. Koba creates a swap chain and retrieves its images.

This lesson adds **image views**.

A swap-chain image is a Vulkan image handle, but a renderer normally does not
use the image handle directly. An **image view** describes how Vulkan should
interpret an image:

- which image it refers to,
- whether it is a 1D, 2D, or 3D image,
- which format it uses,
- which mip levels and array layers are visible,
- which parts of the image, such as color or depth, are being accessed.

For this first renderer, each swap-chain image is a normal 2D color image with:

- the swap-chain's selected format,
- one mip level,
- one array layer,
- the color aspect.

The Vulkan resource relationship is:

```text
swap chain
    |
    +-- swap-chain image 0 --> image view 0
    +-- swap-chain image 1 --> image view 1
    +-- swap-chain image 2 --> image view 2
```

Later lessons will use these image views when creating framebuffers and
selecting a render target.

This translation extends the existing `HelloTriangleApplication` in
`src/main.zig`. It uses the project's raw C Vulkan bindings:

```zig
const std = @import("std");
const sdl = @import("sdl3");
const vk = @import("vulkan");
```

There are no Vulkan-Hpp or `vulkan-zig` proxy objects in this version. Image
views are created with:

```zig
vk.vkCreateImageView(...)
```

and destroyed with:

```zig
vk.vkDestroyImageView(...)
```

---

## Concepts & Explanations

### Why image views exist

A Vulkan image represents storage for pixels, but the image itself does not
fully describe how a particular operation should access that storage.

An image view supplies that interpretation. For example, the same underlying
image storage could potentially be viewed as:

- a color target,
- a depth target,
- one mip level,
- several mip levels,
- one array layer,
- multiple array layers.

This explicit description gives Vulkan flexibility and makes resource usage
visible to the driver.

For the swap chain, the view configuration is straightforward:

```text
image type:       2D
format:           swap-chain format
component mapping: identity
aspect:           color
mip levels:       0 through 0
array layers:     0 through 0
```

### An image view does not own the image

Creating an image view does not create another copy of the pixels. It creates a
small Vulkan object that refers to an existing image.

The swap-chain images are owned by the swap chain. Therefore:

- Koba must not call `vk.vkDestroyImage` on swap-chain images.
- Koba must destroy each image view it created.
- Koba must destroy the image views before destroying the swap chain.

The cleanup relationship is:

```text
image views
swap chain
logical device
surface
debug messenger
instance
SDL window
SDL
```

This is a common Vulkan lifetime rule: destroy objects before the resources they
refer to.

### Raw Vulkan bindings make the ownership explicit

The C++ source uses:

```cpp
std::vector<vk::raii::ImageView>
```

The RAII wrapper automatically destroys each image view. Koba's raw C bindings
do not provide that ownership behavior.

Instead, Koba stores the handles in an allocator-owned slice:

```zig
swap_chain_image_views: []vk.VkImageView = &.{},
```

The application is responsible for:

1. allocating the slice,
2. creating one image view per swap-chain image,
3. destroying every successfully created image view,
4. freeing the slice,
5. clearing the slice after cleanup.

This is more code than the C++ RAII version, but the lifetime is visible and
controllable.

### One image view per swap-chain image

The swap chain contains several images because rendering and presentation can
overlap.

Each image needs its own image view:

```zig
for (self.swap_chain_images) |image| {
    // create a view for this image
}
```

The number of image views must equal the number of swap-chain images. Keeping
the two slices in the same order is important:

```text
swap_chain_images[0]       <--> swap_chain_image_views[0]
swap_chain_images[1]       <--> swap_chain_image_views[1]
swap_chain_images[2]       <--> swap_chain_image_views[2]
```

Later, when Koba creates framebuffers, framebuffer `i` will use image view `i`.

### Component swizzles

A component swizzle controls where each output component comes from. For
example, a view could remap red to blue.

For ordinary swap-chain images, no remapping is wanted. Identity mapping means:

```text
view red   = image red
view green = image green
view blue  = image blue
view alpha = image alpha
```

The raw C translation uses the Vulkan constants:

```zig
vk.VK_COMPONENT_SWIZZLE_IDENTITY
```

### The subresource range

The `.subresourceRange` field tells Vulkan which part of the image the view
covers.

For this lesson:

```zig
.aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
.baseMipLevel = 0,
.levelCount = 1,
.baseArrayLayer = 0,
.layerCount = 1,
```

This means:

- access the color aspect,
- begin at mip level zero,
- include one mip level,
- begin at array layer zero,
- include one array layer.

Swap-chain images are single-level, non-array 2D images for this renderer, so
these values match the entire image.

Later texture lessons may use:

- multiple mip levels,
- several array layers,
- `VK_IMAGE_ASPECT_DEPTH_BIT`,
- `VK_IMAGE_ASPECT_STENCIL_BIT`.

### Failure during partial creation

Image-view creation happens in a loop. That means creation can partially
succeed:

```text
view 0 succeeds
view 1 succeeds
view 2 fails
```

If view 2 fails, views 0 and 1 still exist and must be destroyed.

The translation uses `errdefer` and a creation counter to clean up only the
views that were successfully created. This avoids leaking Vulkan objects during
an error path.

That pattern is especially important in game engines, where device creation,
swap-chain creation, and resource loading can all fail at runtime.

---

## Code Translation Sections

### Add image-view state to `HelloTriangleApplication`

Add this field to the existing struct:

```zig
swap_chain_image_views: []vk.VkImageView = &.{},
```

Place it near the existing swap-chain fields:

```zig
swap_chain: vk.VkSwapchainKHR = null,
swap_chain_images: []vk.VkImage = &.{},
swap_chain_surface_format: vk.VkSurfaceFormatKHR = undefined,
swap_chain_extent: vk.VkExtent2D = undefined,
swap_chain_image_views: []vk.VkImageView = &.{},
```

The empty slice means that no image views have been created yet.

After `createImageViews` succeeds, the slice owns memory allocated through
`self.allocator`. It must remain alive because later framebuffer code will use
the image-view handles.

### Extend `initVulkan`

The C++ lesson changes initialization from:

```cpp
void initVulkan()
{
    createInstance();
    setupDebugMessenger();
    createSurface();
    pickPhysicalDevice();
    createLogicalDevice();
    createSwapChain();
    createImageViews();
}
```

The corresponding Zig method should extend the existing method:

```zig
fn initVulkan(self: *HelloTriangleApplication) !void {
    try self.createInstance();
    try self.setupDebugMessenger();
    try self.createSurface();
    try self.pickPhysicalDevice();
    try self.createLogicalDevice();
    try self.createSwapChain();
    try self.createImageViews();
}
```

The order matters:

- image views require swap-chain images,
- swap-chain images require a logical device and surface support,
- therefore `createImageViews` must run after `createSwapChain`.

### Create the image-view description

The C++ code starts with:

```cpp
vk::ImageViewCreateInfo imageViewCreateInfo{
    .viewType = vk::ImageViewType::e2D,
    .format = swapChainSurfaceFormat.format,
    .subresourceRange = {
        vk::ImageAspectFlagBits::eColor,
        0,
        1,
        0,
        1
    }
};
```

The raw C-binding translation uses Vulkan's C field names:

```zig
var image_view_create_info = vk.VkImageViewCreateInfo{
    .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
    .pNext = null,
    .flags = 0,
    .image = null,
    .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
    .format = self.swap_chain_surface_format.format,
    .components = .{
        .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
        .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
        .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
        .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
    },
    .subresourceRange = .{
        .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1,
    },
};
```

The `.image` field is initially `null` because the same structure will be reused
for every swap-chain image. The loop assigns the current image before each
Vulkan call.

The field names intentionally preserve the raw Vulkan C spelling:

```zig
.sType
.pNext
.viewType
.subresourceRange
.aspectMask
.baseMipLevel
```

Do not change these to snake-case names such as `.s_type` or `.image_view_type`.

### Create one image view per swap-chain image

The C++ loop is:

```cpp
for (auto &image : swapChainImages)
{
    imageViewCreateInfo.image = image;
    swapChainImageViews.emplace_back(device, imageViewCreateInfo);
}
```

The raw Vulkan version must provide an output pointer and check the `VkResult`
explicitly:

```zig
fn createImageViews(self: *HelloTriangleApplication) !void {
    if (self.swap_chain_images.len == 0) {
        return error.NoSwapChainImages;
    }

    if (self.swap_chain_image_views.len != 0) {
        return error.ImageViewsAlreadyCreated;
    }

    const image_views = try self.allocator.alloc(
        vk.VkImageView,
        self.swap_chain_images.len,
    );

    var created_count: usize = 0;

    errdefer {
        for (image_views[0..created_count]) |image_view| {
            vk.vkDestroyImageView(self.device, image_view, null);
        }

        self.allocator.free(image_views);
    }

    var image_view_create_info = vk.VkImageViewCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .image = null,
        .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
        .format = self.swap_chain_surface_format.format,
        .components = .{
            .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
        },
        .subresourceRange = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };

    for (self.swap_chain_images, 0..) |image, index| {
        image_view_create_info.image = image;

        const result = vk.vkCreateImageView(
            self.device,
            &image_view_create_info,
            null,
            &image_views[index],
        );

        if (result != vk.VK_SUCCESS) {
            std.log.err("Failed to create image view for swap-chain image {d}", .{
                index,
            });
            return error.FailedToCreateImageView;
        }

        created_count += 1;
    }

    self.swap_chain_image_views = image_views;

    std.log.debug("Created {d} swap-chain image views", .{
        self.swap_chain_image_views.len,
    });
}
```

The ownership transfer happens at the end:

```zig
self.swap_chain_image_views = image_views;
```

Until that point, `errdefer` owns both the allocation and the partially created
Vulkan objects.

### Why the loop uses an index

The C++ source uses a reference to the image and appends a new view to a vector.
Koba already knows the exact number of views because it knows the exact number
of swap-chain images.

Using an indexed loop lets the code write directly into the allocated slice:

```zig
for (self.swap_chain_images, 0..) |image, index| {
    image_view_create_info.image = image;
    // write the resulting handle to image_views[index]
}
```

This avoids a growable `std.ArrayList`. An `ArrayList` would be useful if the
number of items were discovered incrementally, but Vulkan has already provided
the exact image count.

The direct allocation has a clear lifetime:

```zig
const image_views = try self.allocator.alloc(...);
defer or errdefer cleanup;
```

### Destroy image views during cleanup

Image views refer to swap-chain images, so image views must be destroyed before
the swap chain.

Add this cleanup block before `vk.vkDestroySwapchainKHR`:

```zig
fn destroyImageViews(self: *HelloTriangleApplication) void {
    for (self.swap_chain_image_views) |image_view| {
        vk.vkDestroyImageView(self.device, image_view, null);
    }

    if (self.swap_chain_image_views.len != 0) {
        self.allocator.free(self.swap_chain_image_views);
    }

    self.swap_chain_image_views = &.{};
}
```

Then call it from the existing `cleanup()` method:

```zig
fn cleanup(self: *HelloTriangleApplication) void {
    self.destroyImageViews();

    if (self.swap_chain != null) {
        vk.vkDestroySwapchainKHR(self.device, self.swap_chain, null);
        self.swap_chain = null;
    }

    if (self.device != null) {
        vk.vkDestroyDevice(self.device, null);
        self.device = null;
    }

    if (self.surface != null) {
        vk.vkDestroySurfaceKHR(self.instance, self.surface, null);
        self.surface = null;
    }

    if (self.debug_messenger != null) {
        // Keep the existing debug-messenger destruction code here.
    }

    if (self.instance != null) {
        vk.vkDestroyInstance(self.instance, null);
        self.instance = null;
    }

    if (self.window) |window| {
        sdl.SDL_DestroyWindow(window);
        self.window = null;
    }

    sdl.SDL_Quit();
}
```

If the existing `cleanup()` already destroys the swap chain, keep that code and
insert:

```zig
self.destroyImageViews();
```

immediately before it.

The important order is:

```text
destroy image views
destroy swap chain
destroy logical device
```

### Complete image-view additions

The following is the complete image-view-specific portion to merge into the
existing `HelloTriangleApplication`:

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

    fn initVulkan(self: *HelloTriangleApplication) !void {
        try self.createInstance();
        try self.setupDebugMessenger();
        try self.createSurface();
        try self.pickPhysicalDevice();
        try self.createLogicalDevice();
        try self.createSwapChain();
        try self.createImageViews();
    }

    fn createImageViews(self: *HelloTriangleApplication) !void {
        if (self.swap_chain_images.len == 0) {
            return error.NoSwapChainImages;
        }

        if (self.swap_chain_image_views.len != 0) {
            return error.ImageViewsAlreadyCreated;
        }

        const image_views = try self.allocator.alloc(
            vk.VkImageView,
            self.swap_chain_images.len,
        );

        var created_count: usize = 0;

        errdefer {
            for (image_views[0..created_count]) |image_view| {
                vk.vkDestroyImageView(self.device, image_view, null);
            }

            self.allocator.free(image_views);
        }

        var image_view_create_info = vk.VkImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = null,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = self.swap_chain_surface_format.format,
            .components = .{
                .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        for (self.swap_chain_images, 0..) |image, index| {
            image_view_create_info.image = image;

            const result = vk.vkCreateImageView(
                self.device,
                &image_view_create_info,
                null,
                &image_views[index],
            );

            if (result != vk.VK_SUCCESS) {
                std.log.err("Failed to create image view for swap-chain image {d}", .{
                    index,
                });
                return error.FailedToCreateImageView;
            }

            created_count += 1;
        }

        self.swap_chain_image_views = image_views;
    }

    fn destroyImageViews(self: *HelloTriangleApplication) void {
        for (self.swap_chain_image_views) |image_view| {
            vk.vkDestroyImageView(self.device, image_view, null);
        }

        if (self.swap_chain_image_views.len != 0) {
            self.allocator.free(self.swap_chain_image_views);
        }

        self.swap_chain_image_views = &.{};
    }
};
```

This snippet is intended to be merged into the existing `src/main.zig` rather
than used as a second application architecture. Keep the existing
initialization, surface, physical-device, logical-device, swap-chain, and
cleanup implementations in the same struct.

---

## Recap & What's Next

This lesson added image views to Koba's Vulkan setup.

The important ideas were:

- A swap-chain image is storage; an image view describes how Vulkan accesses
  that storage.
- Every swap-chain image needs a corresponding image view.
- The image-view format must match `swap_chain_surface_format.format`.
- Color swap-chain images use `VK_IMAGE_ASPECT_COLOR_BIT`.
- Identity component swizzles preserve the original red, green, blue, and alpha
  channels.
- Image views must be explicitly destroyed because raw Vulkan bindings do not
  provide RAII.
- Image views must be destroyed before their swap chain.
- `errdefer` handles the case where only some image views were created
  successfully.
- The allocator-owned slice remains available for later framebuffer creation.

The next rendering step is to create a **render pass** or configure dynamic
rendering, then create one framebuffer per swap-chain image view. That will
connect these image views to actual rendering commands so Koba can begin drawing
into the window.
