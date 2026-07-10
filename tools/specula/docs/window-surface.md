# Window Surface :: Vulkan Documentation Project (Zig 0.16.0 + SDL3 + vulkan-zig)

## Overview

`src/main.zig`'s `App` struct, as of the previous two lessons, opens an SDL3
window, builds a `vk.Instance`-backed proxy, installs a debug messenger, picks a
`vk.PhysicalDevice`, and creates a `vk.Device` with a single graphics queue.
This lesson adds the operation the C++ source calls **`createSurface()`**, and
it slots in _before_ physical-device selection — the revised `initVulkan()` in
the source is:

```c++
void initVulkan() {
    createInstance();
    setupDebugMessenger();
    createSurface();
    pickPhysicalDevice();
    createLogicalDevice();
}
```

That ordering matters: once a surface exists, `createLogicalDevice()`'s
queue-family search is upgraded from "any family with graphics support" to "a
family with graphics support _that can also present to this surface_" — so the
surface has to exist before that search runs.

The C++ source shown for this lesson does something slightly unusual: it
demonstrates the _manual_, platform-specific Win32 path (`glfwGetWin32Window` +
`vk::Win32SurfaceCreateInfoKHR`) as context, then settles on the portable
`glfwCreateWindowSurface()` helper for the actual `createSurface()` body. Since
we're already on SDL3 instead of GLFW, we get the portable path "for free" —
SDL3 has its own single, per-platform-agnostic surface-creation entry point, so
none of the `#define VK_USE_PLATFORM_WIN32_KHR` / `glfwGetWin32Window` machinery
needs translating at all. What _does_ need careful translation is crossing the
boundary between SDL3's raw Vulkan C handles and vulkan-zig's typed `vk.`
handles — that's this lesson's real new idea.

We extend `App` with:

- a `surface: vk.SurfaceKHR` field,
- a `createSurface` method,
- an updated queue-family search inside `createLogicalDevice` that checks
  presentation support as well as graphics support,
- a `deinit` update that destroys the surface.

Everything else (window creation, instance creation, debug messenger,
physical-device selection, logical-device creation) is kept and shown condensed
in the full listing, exactly as the physical-devices and logical-device lessons
did.

## Concepts & Explanations

**1. GLFW's platform dance disappears; SDL3 gives you one call.** The C++
excerpt's `#define VK_USE_PLATFORM_WIN32_KHR` / `glfwGetWin32Window` /
`vk::Win32SurfaceCreateInfoKHR` trio exists only because GLFW makes you reach
into the native window handle yourself if you want to skip its own portable
helper. SDL3 doesn't ask you to do this at all — it exposes one
platform-agnostic "create me a `VkSurfaceKHR` for this window" function, which
is the moral equivalent of `glfwCreateWindowSurface`, the function the source
actually settles on using. There is no Win32-specific code to translate here;
that's a feature, not an omission.

**2. Crossing from SDL3's raw handles into vulkan-zig's typed handles needs
explicit casts.** This is the main new friction point. SDL doesn't depend on any
particular Zig Vulkan binding, so its Vulkan-interop functions speak the plain
Vulkan C ABI: a `VkInstance` in, a `VkSurfaceKHR` out, both opaque pointers.
`vulkan-zig`'s `vk.Instance` and `vk.SurfaceKHR`, on the other hand, are
`enum(usize)` wrappers around those exact same bit patterns. Handing one to the
other means converting the representation, not the value —
`@intFromEnum`/`@enumFromInt` to move between the enum and its backing `usize`,
and `@ptrFromInt`/`@intFromPtr` to move between that `usize` and a raw pointer.
This is the same category of "convert between pointer types" situation flagged
in the previous lesson's `pNext`-chaining discussion, just crossing a package
boundary instead of a struct-chain boundary.

**3. `throw` becomes `try`, and this time there's no manual `if` to write.**
GLFW's `glfwCreateWindowSurface` returns a plain C `int`, so the C++ source has
to check it itself: `if (... != 0) { throw ...; }`. SDL3's own C API already
follows the "return `bool`, call `SDL_GetError()` on failure" convention, and an
idiomatic Zig binding turns that convention into a Zig error union at the call
site. So where GLFW needed an explicit `if`/`throw`, the SDL3 wrapper lets a
single `try` do the same job — one more case of a C-style failure code
collapsing into Zig's built-in error-propagation instead of hand-rolled control
flow.

**4. A surface is a third category of "thing that may or may not need
cleanup."** The physical-devices lesson established that a `vk.PhysicalDevice`
needs no destructor (it's hardware, not a resource your app owns). The
logical-device lesson established that a `vk.Device` _does_ need one, and that
it also owns a dispatch table you must load yourself. A `vk.SurfaceKHR` is a
third case: it needs a destructor (`vkDestroySurfaceKHR`), but it does _not_ own
its own dispatch table — it's destroyed by calling through the _instance_, since
`VK_KHR_surface` is an instance-level extension. So, consistent with the rule
from the physical-devices lesson ("call through the object that owns the
dispatch table"), surface destruction is
`self.instance.destroySurfaceKHR(self.surface, null)`, not some method on the
surface itself.

**5. `&&` becomes `and`, but check the cheap condition first.** The source's
combined predicate is
`(queueFamilyProperties[i].queueFlags & vk::QueueFlagBits::eGraphics) && physicalDevice.getSurfaceSupportKHR(i, *surface)`.
The left side is a pure bitmask test (as covered in the physical-devices lesson:
a packed struct of `bool`s, no masking needed —
`family.queue_flags.graphics_bit`). The right side is an actual Vulkan call with
a `VkResult`, meaning `try` and a real (if cheap) driver round-trip. Rather than
writing `and` between two boolean expressions in one line, it reads more clearly
— and avoids calling the driver for families that were never graphics-capable in
the first place — to `continue` past non-graphics families before ever asking
about presentation support.

**6. `getSurfaceSupportKHR`'s output is still a `Bool32`, not a `bool`.** Just
like `VkPhysicalDeviceFeatures` fields in the physical-devices lesson,
`vkGetPhysicalDeviceSurfaceSupportKHR`'s output parameter is a `VkBool32`.
Because it has a `VkResult` _and_ exactly one output parameter, `vulkan-zig`'s
wrapper folds that output straight into the return value:
`try self.instance.getPhysicalDeviceSurfaceSupportKHR(...)` returns `vk.Bool32`,
which you compare with `== vk.TRUE` — the same flags-vs-features distinction
called out two lessons ago, reappearing in a new spot.

**7. `~0` as a "not found" sentinel is a C idiom; `for...else` replaces the
sentinel entirely.** The source initializes `uint32_t queueIndex = ~0;`, loops
with an explicit `break`, and checks `queueIndex == ~0` afterward to detect "no
match." Zig's `for...else`, already used for the graphics-only search in the
previous lesson, removes the sentinel entirely: the "not found" case _is_ the
`else` branch, checked by the compiler's control-flow rules rather than a magic
unsigned-integer value you have to remember to compare against later.

**8. Creation order and destruction order both have to change together.**
Because `createLogicalDevice`'s queue search now needs `self.surface` to exist,
`createSurface` has to run before `pickPhysicalDevice` and `createLogicalDevice`
in `initVulkan` — matching the source's reordering exactly. Symmetrically,
whatever `deinit`/cleanup method destroys the device and instance now needs a
`destroySurfaceKHR` call added, positioned before the instance is destroyed
(surface destruction doesn't have to happen before or after the device
specifically, but it must happen before the instance goes away, since the
instance owns the dispatch table that knows how to destroy it).

## Code Translation Sections

### The field

```c++
vk::raii::SurfaceKHR surface = nullptr;
```

```zig
surface: vk.SurfaceKHR = .null_handle,
```

Same pattern as `physical_device` in the earlier lesson: no RAII wrapper to
store, just the handle, defaulted to the "nothing created yet" sentinel. Unlike
`physical_device`, though, this handle _does_ get destroyed explicitly later
(Concept #4) — the default here just means "not created yet," not "never needs
cleanup."

### Wiring `createSurface` into `initVulkan`

```c++
void initVulkan() {
    createInstance();
    setupDebugMessenger();
    createSurface();
    pickPhysicalDevice();
    createLogicalDevice();
}

void createSurface() {

}
```

```zig
fn initVulkan(self: *App) !void {
    try self.createInstance();
    try self.setupDebugMessenger();
    try self.createSurface();
    try self.pickPhysicalDevice();
    try self.createLogicalDevice();
}

fn createSurface(self: *App) !void {
    _ = self;
}
```

Same `try`-chain as always; the only change from the previous lesson's
`initVulkan` is the new line, inserted in the same position the source inserts
it — before `pickPhysicalDevice`, per Concept #8.

### Creating the surface

```c++
void createSurface() {
    VkSurfaceKHR       _surface;
    if (glfwCreateWindowSurface(*instance, window, nullptr, &_surface) != 0) {
        throw std::runtime_error("failed to create window surface!");
    }
    surface = vk::raii::SurfaceKHR(instance, _surface);
}
```

```zig
fn createSurface(self: *App) !void {
    const raw_instance: *anyopaque = @ptrFromInt(@intFromEnum(self.instance.handle));

    const raw_surface = try sdl.vulkan.createSurface(self.window, raw_instance, null);

    self.surface = @enumFromInt(@intFromPtr(raw_surface));
}
```

This is the boundary-crossing from Concept #2, made concrete:
`self.instance.handle` is a `vk.Instance` (an `enum(usize)`); SDL's Vulkan
bridge wants a raw `VkInstance` pointer, so we unwrap the enum to its backing
integer and re-interpret that integer as a pointer with `@ptrFromInt`. Going the
other direction, SDL hands back a raw `*anyopaque` surface pointer, which we
turn back into an integer with `@intFromPtr` and re-wrap as a `vk.SurfaceKHR`
with `@enumFromInt`. There's no manual `if (... != 0) throw` to write — per
Concept #3, `sdl.vulkan.createSurface` already returns an error union, so `try`
alone covers the failure path GLFW made you check by hand.

_(The exact name of this function in your installed `@import("sdl3")` binding
may differ — check for whatever wraps `SDL_Vulkan_CreateSurface`. The shape of
the translation — unwrap `vk.Instance`, call into SDL, re-wrap the result as
`vk.SurfaceKHR` — stays the same regardless of the exact name.)_

Note also that this depends on `self.instance`'s dispatch table having
`VK_KHR_surface` (and the platform surface extension) enabled, which is already
true if `createInstance` (Lesson 01) requested SDL's own "instance extensions
this window needs" list when building the instance — nothing to change there,
just worth naming the dependency now that we're finally using it.

### Querying for presentation support

```c++
uint32_t queueIndex = ~0;
for (uint32_t qfpIndex = 0; qfpIndex < queueFamilyProperties.size(); qfpIndex++)
{
  if ((queueFamilyProperties[qfpIndex].queueFlags & vk::QueueFlagBits::eGraphics) &&
      physicalDevice.getSurfaceSupportKHR(qfpIndex, *surface))
  {
    queueIndex = qfpIndex;
    break;
  }
}
if (queueIndex == ~0)
{
  throw std::runtime_error("Could not find a queue for graphics and present -> terminating");
}
```

```zig
self.graphics_family = for (families, 0..) |family, i| {
    if (!family.queue_flags.graphics_bit) continue;

    const supports_present = try self.instance.getPhysicalDeviceSurfaceSupportKHR(
        self.physical_device,
        @intCast(i),
        self.surface,
    );

    if (supports_present == vk.TRUE) break @intCast(i);
} else return error.NoGraphicsPresentQueueFamily;
```

This replaces the graphics-only search from the previous lesson in place —
`families`/`family_count` are still fetched exactly as before with the two-call
enumeration pattern; only the loop body changes. Per Concept #5, the cheap flags
check runs first via `continue`, so the driver call only happens for families
that were already graphics-capable. Per Concept #7, there's no `~0` sentinel to
declare or check — `else return error.NoGraphicsPresentQueueFamily` _is_ the
"not found" path.

We keep the field named `graphics_family` (and, further down, `graphics_queue`)
rather than renaming it to a bare `queue`/`queue_family` as the C++ source does,
since a single queue family that happens to support both graphics and
presentation is a simplification most GPUs allow, not a guarantee — a future
lesson could split this into separate `graphics_family`/`present_family` fields
if that assumption ever needs relaxing, and keeping the existing name avoids
reshuffling every prior lesson's field references for a distinction we aren't
acting on yet.

### Cleanup — destroying the surface

```c++
// no explicit call needed: vk::raii::SurfaceKHR's destructor
// runs automatically when `surface` goes out of scope.
```

```zig
fn deinit(self: *App) void {
    self.device.destroyDevice(null);
    self.instance.destroySurfaceKHR(self.surface, null);
    // ...debug messenger, instance, and window teardown unchanged
    // from earlier lessons...
}
```

There's nothing to translate line-for-line here, because
`vk::raii::SurfaceKHR`'s whole point is that its destructor call is invisible in
the source. Per Concept #4, `vulkan-zig` gives us no such destructor, so this
line has to be added by hand — through `self.instance`, since surfaces don't own
a dispatch table of their own, and before the instance is destroyed, per Concept
#8.

## Full Translated Code

```zig
const std = @import("std");
const sdl = @import("sdl3");
const vk = @import("vulkan");

const apis: []const vk.ApiInfo = &.{
    vk.features.version_1_3,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
    vk.extensions.ext_debug_utils,
};

const BaseDispatch = vk.BaseWrapper;
const InstanceDispatch = vk.InstanceWrapper(apis);
const DeviceDispatch = vk.DeviceWrapper(apis);
const InstanceProxy = vk.InstanceProxy(apis);
const DeviceProxy = vk.DeviceProxy(apis);

const required_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,
};

const App = struct {
    allocator: std.mem.Allocator,
    window: *sdl.Window = undefined,

    vkb: BaseDispatch = undefined,
    instance_dispatch: InstanceDispatch = undefined,
    instance: InstanceProxy = undefined,

    debug_messenger: vk.DebugUtilsMessengerEXT = .null_handle,

    surface: vk.SurfaceKHR = .null_handle,

    physical_device: vk.PhysicalDevice = .null_handle,

    device_dispatch: DeviceDispatch = undefined,
    device: DeviceProxy = undefined,

    graphics_family: u32 = undefined,
    graphics_queue: vk.Queue = undefined,

    fn init(self: *App, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        try self.initWindow();
        try self.initVulkan();
    }

    fn initWindow(self: *App) !void {
        // Translated from Lesson 01: glfwInit / glfwCreateWindow -> SDL3.
        self.window = try sdl.Window.create("Vulkan", 800, 600, .{ .vulkan = true });
    }

    fn initVulkan(self: *App) !void {
        try self.createInstance();
        try self.setupDebugMessenger();
        try self.createSurface();
        try self.pickPhysicalDevice();
        try self.createLogicalDevice();
    }

    /// Condensed from Lesson 01/02: builds `self.instance` and
    /// `self.instance_dispatch` using SDL's required-extension list plus the
    /// validation layer and debug-utils extension.
    fn createInstance(self: *App) !void {
        self.vkb = try BaseDispatch.load(sdl.vulkan.getVkGetInstanceProcAddr());

        const app_info = vk.ApplicationInfo{
            .p_application_name = "Vulkan",
            .application_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
            .p_engine_name = "No Engine",
            .engine_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
            .api_version = @bitCast(vk.API_VERSION_1_3),
        };

        const extensions = try sdl.vulkan.getInstanceExtensions(self.allocator, self.window);
        defer self.allocator.free(extensions);

        const create_info = vk.InstanceCreateInfo{
            .p_application_info = &app_info,
            .enabled_extension_count = @intCast(extensions.len),
            .pp_enabled_extension_names = extensions.ptr,
        };

        const instance_handle = try self.vkb.createInstance(&create_info, null);
        self.instance_dispatch = try InstanceDispatch.load(instance_handle, self.vkb.dispatch.vkGetInstanceProcAddr);
        self.instance = .{ .handle = instance_handle, .wrapper = &self.instance_dispatch };
    }

    /// Condensed from Lesson 02: installs the validation-layer debug
    /// messenger via VK_EXT_debug_utils.
    fn setupDebugMessenger(self: *App) !void {
        const create_info = vk.DebugUtilsMessengerCreateInfoEXT{
            .message_severity = .{ .warning_bit_ext = true, .error_bit_ext = true },
            .message_type = .{ .general_bit_ext = true, .validation_bit_ext = true, .performance_bit_ext = true },
            .pfn_user_callback = debugCallback,
        };
        self.debug_messenger = try self.instance.createDebugUtilsMessengerEXT(&create_info, null);
    }

    fn createSurface(self: *App) !void {
        const raw_instance: *anyopaque = @ptrFromInt(@intFromEnum(self.instance.handle));
        const raw_surface = try sdl.vulkan.createSurface(self.window, raw_instance, null);
        self.surface = @enumFromInt(@intFromPtr(raw_surface));
    }

    fn pickPhysicalDevice(self: *App) !void {
        var device_count: u32 = 0;
        _ = try self.instance.enumeratePhysicalDevices(&device_count, null);

        if (device_count == 0) {
            return error.NoGpuWithVulkanSupport;
        }

        const physical_devices = try self.allocator.alloc(vk.PhysicalDevice, device_count);
        defer self.allocator.free(physical_devices);
        _ = try self.instance.enumeratePhysicalDevices(&device_count, physical_devices.ptr);

        // Condensed from Lesson 03: takes the first enumerated device.
        // A real suitability check (extension support, required features)
        // belongs here; omitted since it isn't this lesson's topic.
        for (physical_devices) |candidate| {
            self.physical_device = candidate;
            break;
        }
    }

    fn createLogicalDevice(self: *App) !void {
        var family_count: u32 = 0;
        self.instance.getPhysicalDeviceQueueFamilyProperties(self.physical_device, &family_count, null);

        const families = try self.allocator.alloc(vk.QueueFamilyProperties, family_count);
        defer self.allocator.free(families);
        self.instance.getPhysicalDeviceQueueFamilyProperties(self.physical_device, &family_count, families.ptr);

        self.graphics_family = for (families, 0..) |family, i| {
            if (!family.queue_flags.graphics_bit) continue;

            const supports_present = try self.instance.getPhysicalDeviceSurfaceSupportKHR(
                self.physical_device,
                @intCast(i),
                self.surface,
            );

            if (supports_present == vk.TRUE) break @intCast(i);
        } else return error.NoGraphicsPresentQueueFamily;

        const queue_priorities = [_]f32{0.5};
        const device_queue_create_info = vk.DeviceQueueCreateInfo{
            .queue_family_index = self.graphics_family,
            .queue_count = 1,
            .p_queue_priorities = &queue_priorities,
        };

        const device_features = vk.PhysicalDeviceFeatures{};

        var extended_dynamic_state_features = vk.PhysicalDeviceExtendedDynamicStateFeaturesEXT{
            .s_type = .physical_device_extended_dynamic_state_features_ext,
            .p_next = null,
            .extended_dynamic_state = vk.TRUE,
        };
        var vulkan_1_3_features = vk.PhysicalDeviceVulkan13Features{
            .s_type = .physical_device_vulkan_1_3_features,
            .p_next = @ptrCast(&extended_dynamic_state_features),
            .dynamic_rendering = vk.TRUE,
        };
        var vulkan_1_1_features = vk.PhysicalDeviceVulkan11Features{
            .s_type = .physical_device_vulkan_1_1_features,
            .p_next = @ptrCast(&vulkan_1_3_features),
            .shader_draw_parameters = vk.TRUE,
        };
        var features2 = vk.PhysicalDeviceFeatures2{
            .s_type = .physical_device_features_2,
            .p_next = @ptrCast(&vulkan_1_1_features),
            .features = device_features,
        };

        const device_create_info = vk.DeviceCreateInfo{
            .p_next = @ptrCast(&features2),
            .queue_create_info_count = 1,
            .p_queue_create_infos = &[_]vk.DeviceQueueCreateInfo{device_queue_create_info},
            .enabled_extension_count = required_device_extensions.len,
            .pp_enabled_extension_names = &required_device_extensions,
        };

        const device_handle = try self.instance.createDevice(self.physical_device, &device_create_info, null);
        self.device_dispatch = try DeviceDispatch.load(device_handle, self.instance.wrapper.dispatch.vkGetDeviceProcAddr);
        self.device = .{ .handle = device_handle, .wrapper = &self.device_dispatch };

        self.graphics_queue = self.device.getDeviceQueue(self.graphics_family, 0);
    }

    fn deinit(self: *App) void {
        self.device.destroyDevice(null);
        self.instance.destroySurfaceKHR(self.surface, null);
        self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
        self.instance.destroyInstance(null);
        self.window.destroy();
    }
};

fn debugCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    msg_type: vk.DebugUtilsMessageTypeFlagsEXT,
    data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(.c) vk.Bool32 {
    _ = severity;
    _ = msg_type;
    _ = user_data;
    if (data) |d| {
        std.log.warn("validation layer: {s}", .{d.p_message orelse ""});
    }
    return vk.FALSE;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app: App = undefined;
    try app.init(gpa.allocator());
    defer app.deinit();
}
```

## Recap & What's Next

`src/main.zig` can now open an SDL3 window, stand up a Vulkan instance and debug
messenger, create a Vulkan surface tied to that window, pick a physical device,
and create a logical device whose single queue is guaranteed (by construction)
to support both graphics commands and presenting to the surface. The two threads
running through this lesson — "cross package boundaries with explicit casts, not
assumptions" and "every resource that gets created gets an explicit, ordered
teardown" — are the same ones from the physical-device and logical-device
lessons, just applied to a handle (`vk.SurfaceKHR`) that, unlike a physical
device, really does need destroying, and that, unlike a logical device, doesn't
own a dispatch table of its own.

With a surface and a present-capable queue in hand, the next natural step — and
the next lesson in this series — is the **swap chain**: querying the surface's
supported formats and present modes, choosing among them, and creating a
`vk.SwapchainKHR` to actually get images onto the screen. Expect the same
two-call enumeration pattern from the physical-devices lesson to reappear
(`getPhysicalDeviceSurfaceFormatsKHR`,
`getPhysicalDeviceSurfacePresentModesKHR`), plus a first real use of
`std.ArrayList` for scoring/ranking format-and-present-mode combinations where
the "obviously best" choice isn't available.
