# Logical Device and Queues :: Vulkan Documentation Project (Zig 0.16.0 + SDL3 + vulkan-zig)

## Overview

`src/main.zig` currently has an `App` struct that opens an SDL3 window, builds a
`vk.Instance`-backed proxy, installs a debug messenger, and (from the previous
lesson) picks a `vk.PhysicalDevice`. This lesson adds the fourth call in
`initVulkan()`: **`createLogicalDevice()`**.

The C++ source keeps using `vulkan.hpp`'s RAII wrappers — `vk::raii::Device` and
`vk::raii::Queue` — plus a `vk::StructureChain` template to enable a handful of
Vulkan 1.1/1.3/extension features. As with physical devices, none of that
machinery exists in `vulkan-zig`. What's different this time is that a _logical_
device really is a resource your application creates and must destroy (unlike a
physical device, which just represents hardware). So this lesson is where the
"no RAII, do it by hand" theme from the previous lesson stops being a curiosity
and starts mattering for correctness: we're responsible for loading the device's
own dispatch table and for destroying it in the right order during cleanup.

We extend `App` with:

- `device_dispatch` / `device` fields (the device-level equivalent of the
  `instance_dispatch` / `instance` pair you already have),
- `graphics_family` and `graphics_queue` fields,
- a `createLogicalDevice` method,
- reuse (not redefinition) of the `required_device_extensions` list from the
  previous lesson.

Everything from earlier lessons is included in the Full Translated Code so the
file stays compilable end-to-end, condensed where it isn't this lesson's topic —
exactly the approach the physical-devices lesson took.

## Concepts & Explanations

**1. A logical device _does_ need a destructor — but `vk.Device` still has no
RAII wrapper.** Contrast this with `vk.PhysicalDevice` from the last lesson: a
physical device represents real hardware and is never created or destroyed by
your app, so there was truly nothing to manage. A logical device is the opposite
— you call `vkCreateDevice`, the driver allocates real state, and you _must_
call `vkDestroyDevice` before the instance goes away. `vulkan-zig` still gives
you no RAII smart handle for this, though, so the responsibility for calling the
destructor at the right time, in the right order, moves explicitly into your own
`deinit` method. This is the direct trade-off for not having
`vk::raii::Device`'s destructor run automatically: more typing, but the lifetime
is visible in the source instead of hidden in a class.

**2. Device-level functions need their own dispatch table, loaded through the
instance's.** This is the part `vk::raii::Device`'s constructor was hiding. Real
Vulkan has _two_ families of function pointers: instance-level (fetched via
`vkGetInstanceProcAddr`) and device-level (fetched via `vkGetDeviceProcAddr`,
which itself is one of the special functions loaded at the instance level,
precisely to bootstrap this). Just as you loaded `InstanceDispatch` from
`self.vkb`'s dispatch table back when you created the instance, you now load
`DeviceDispatch` from `self.instance`'s dispatch table, using the freshly
returned `vk.Device` handle:

```zig
self.device_dispatch = try DeviceDispatch.load(device_handle, self.instance.wrapper.dispatch.vkGetDeviceProcAddr);
self.device = .{ .handle = device_handle, .wrapper = &self.device_dispatch };
```

`self.device` is then the object that "owns the dispatch table" for device-level
calls — the same rule from the physical-devices lesson, just one level down:
call through the object that owns the table, not the bare handle.

**3. This is exactly why `App` methods take `self: *App`, not `App` by value.**
`self.instance.wrapper` and (now) `self.device.wrapper` are pointers back _into_
the `App` struct itself (`&self.instance_dispatch`, `&self.device_dispatch`). If
`init` built an `App` and then `return`ed it by value, the struct would be
_copied_ to the caller's storage, and those saved pointers would now point at
the old, dead location. That's why `App.init` takes `self: *App` and writes into
storage the caller already owns (a stack variable in `main` that lives for the
program's duration), rather than constructing and returning a value. This is a
genuinely easy mistake in Zig (nothing stops you from writing the by-value
version, it just silently corrupts pointers at runtime) — worth remembering any
time a struct stores a pointer to one of its own fields.

**4. `std::ranges::find_if` + `std::distance` becomes a `for...else` with an
index capture.** The previous lesson introduced `for...else` for "does any
element match" as a direct swap for `std::ranges::any_of`. Finding the graphics
queue family is the same idiom, extended to also capture _which_ index matched,
using Zig's `for (slice, 0..) |item, i|` form:

```zig
self.graphics_family = for (families, 0..) |family, i| {
    if (family.queue_flags.graphics_bit) break @intCast(i);
} else return error.NoGraphicsQueueFamily;
```

`std::distance(begin, it)` disappears entirely — the index just comes along for
free from the iteration, so there's nothing to "compute" after the fact. The
`else` branch here is a `return`, which is allowed even though it doesn't
produce a `u32`: `return` is a `noreturn` expression, so it satisfies any
expected type, the same way `unreachable` or `@panic` would.

**5. Single-item pointers to arrays satisfy Vulkan's "pointer + count" struct
fields — no slices.** `vk::DeviceQueueCreateInfo::pQueuePriorities` and
`vk::DeviceCreateInfo::ppEnabledExtensionNames` are C-style
`pointer`-plus-separately-tracked-`count` pairs, not slices. Per the supplied
_Type Coercion: Slices, Arrays and Pointers_ reference (test `"*[N]T to
[*]T"`),
a `*const [N]T` coerces directly to `[*]const T`, with the array length simply
"becoming" the count you already know at compile time:

```zig
const queue_priorities = [_]f32{0.5};
const device_queue_create_info = vk.DeviceQueueCreateInfo{
    .queue_family_index = self.graphics_family,
    .queue_count = 1,
    .p_queue_priorities = &queue_priorities, // *[1]f32 -> [*]const f32
};
```

The same coercion is why
`.pp_enabled_extension_names = &required_device_extensions` works below:
`required_device_extensions` is a fixed-size array, and its address coerces
straight into the many-pointer field Vulkan expects.

**6. The `pNext` chain from the last lesson gets _built_, this time, not just
described.** `checkRequiredFeatures` (previous lesson) already built a
`vk.PhysicalDeviceFeatures2` → `Vulkan11Features` → `Vulkan13Features` →
`ExtendedDynamicStateFeaturesEXT` chain to _query_ support.
`createLogicalDevice` builds the _same shape_ of chain again, but to _request_
those features when creating the device — this mirrors the C++ source directly:
`vulkan.hpp`'s `vk::StructureChain` is used once for querying (in the
suitability check, not shown in this lesson's source excerpt) and once for
enabling (here). Because each `pNext` field is typed as an opaque pointer
(`?*anyopaque`), and each concrete feature struct is a distinct, unrelated Zig
type, linking them requires an explicit `@ptrCast` at each step — this is
exactly the "convert between pointer types" case called out in the supplied
_Explicit Casts_ reference. Also note these locals must be `var`, not `const`:
even though we only _read_ `queue_priorities`/`features2` here, `&x` on a
`const` still type-checks, but keeping the whole chain `var` matches the fact
that the _query_ version of this same chain (in `checkRequiredFeatures`) is
written to by the driver — consistency between the two call sites matters more
than strict `const`-correctness on this particular request-only chain.

**7. `vk.PhysicalDeviceFeatures{}` relies on the type's own defaults — check
that assumption before reusing it elsewhere.**
`vk::PhysicalDeviceFeatures deviceFeatures;` in C++ default-constructs every
field to `false`. The Zig equivalent, `vk.PhysicalDeviceFeatures{}`, only works
because `vulkan-zig`'s generated struct declares `= vk.FALSE` (or equivalent) as
the default value for every `Bool32` field — an empty struct literal always just
fills in whatever defaults the _type's author_ chose. Contrast this with the
`ArrayList` case flagged in the previous lesson: its default zero-initialized
layout is _not_ safe (there's no meaningful "empty" bit pattern for its capacity
bookkeeping), which is exactly why `.empty` exists as an explicit, documented
starting value instead. Same `.{}` syntax, opposite safety story — always worth
checking which one you're looking at.

**8. Retrieving a queue is a "no `VkResult`" call, just like
`getPhysicalDeviceProperties` was.** `vkGetDeviceQueue` fills in a handle and
cannot fail (an invalid family/index is a programming error caught by validation
layers, not a runtime error path), so its `vulkan-zig` wrapper returns
`vk.Queue` directly:

```zig
self.graphics_queue = self.device.getDeviceQueue(self.graphics_family, 0);
```

No `try`, matching the rule from the previous lesson: only wrap calls that
actually carry a `VkResult` (like `createDevice`) in `try`.

## Code Translation Sections

### Introduction — the field

```c++
vk::raii::Device device = nullptr;
```

```zig
device_dispatch: DeviceDispatch = undefined,
device: DeviceProxy = undefined,
```

Two fields instead of one, per Concepts (#2): the dispatch table
(`device_dispatch`) and the handle-plus-dispatch-pointer pairing that lets us
call methods on it (`device`). Both default to `undefined` rather than a
sentinel handle, because unlike `vk.PhysicalDevice.null_handle`, there's no
meaningful "empty" `DeviceProxy` — it's only ever valid after
`createLogicalDevice` runs, same as the `instance`/`instance_dispatch` pair you
already have from the instance-creation lesson.

### Introduction — wiring `createLogicalDevice` into `initVulkan`

```c++
void initVulkan() {
    createInstance();
    setupDebugMessenger();
    pickPhysicalDevice();
    createLogicalDevice();
}

void createLogicalDevice() {

}
```

```zig
fn initVulkan(self: *App) !void {
    try self.createInstance();
    try self.setupDebugMessenger();
    try self.pickPhysicalDevice();
    try self.createLogicalDevice();
}

fn createLogicalDevice(self: *App) !void {
    _ = self;
}
```

Same `try`-chain pattern as before — each step can fail, and `!void` lets the
failure bubble all the way up to `main` without any explicit propagation code.

### Specifying the queues to be created — finding the graphics family

```c++
std::vector<vk::QueueFamilyProperties> queueFamilyProperties = physicalDevice.getQueueFamilyProperties();
auto graphicsQueueFamilyProperty = std::ranges::find_if(queueFamilyProperties, [](auto const &qfp) { return (qfp.queueFlags & vk::QueueFlagBits::eGraphics) != static_cast<vk::QueueFlags>(0); });
auto graphicsIndex = static_cast<uint32_t>(std::distance(queueFamilyProperties.begin(), graphicsQueueFamilyProperty));
vk::DeviceQueueCreateInfo deviceQueueCreateInfo { .queueFamilyIndex = graphicsIndex };
```

```zig
var family_count: u32 = 0;
self.instance.getPhysicalDeviceQueueFamilyProperties(self.physical_device, &family_count, null);

const families = try self.allocator.alloc(vk.QueueFamilyProperties, family_count);
defer self.allocator.free(families);
self.instance.getPhysicalDeviceQueueFamilyProperties(self.physical_device, &family_count, families.ptr);

self.graphics_family = for (families, 0..) |family, i| {
    if (family.queue_flags.graphics_bit) break @intCast(i);
} else return error.NoGraphicsQueueFamily;
```

The two-call enumeration pattern from the previous lesson reappears exactly
as-is (`getPhysicalDeviceQueueFamilyProperties` has no `VkResult`, so no `try`,
but it's still count-then-fill). The `find_if` + `distance` pair collapses into
the single `for...else` loop described in Concepts (#4).

### Specifying the queues to be created — adding a priority

```c++
float queuePriority = 0.5f;
vk::DeviceQueueCreateInfo deviceQueueCreateInfo { .queueFamilyIndex = graphicsIndex, .queueCount = 1, .pQueuePriorities = &queuePriority };
```

```zig
const queue_priorities = [_]f32{0.5};
const device_queue_create_info = vk.DeviceQueueCreateInfo{
    .queue_family_index = self.graphics_family,
    .queue_count = 1,
    .p_queue_priorities = &queue_priorities,
};
```

Per Concepts (#5), we spell the single priority as a one-element array rather
than a lone `f32`, so that `&queue_priorities` coerces straight into the
many-pointer field Vulkan wants — no manual pointer arithmetic, no `@ptrCast`.

### Specifying used device features

```c++
vk::PhysicalDeviceFeatures deviceFeatures;
```

```zig
const device_features = vk.PhysicalDeviceFeatures{};
```

An empty struct literal, relying on `vulkan-zig`'s generated defaults (all
`Bool32` fields default to `vk.FALSE`) — see Concepts (#7) for why this is safe
here specifically.

### Enabling additional device features

```c++
vk::StructureChain<vk::PhysicalDeviceFeatures2,
                   vk::PhysicalDeviceVulkan11Features,
                   vk::PhysicalDeviceVulkan13Features,
                   vk::PhysicalDeviceExtendedDynamicStateFeaturesEXT>
    featureChain = {
        {},
        {.shaderDrawParameters = true},
        {.dynamicRendering = true},
        {.extendedDynamicState = true}
    };
```

```zig
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
```

The template's implicit list becomes four ordinary local variables, linked
back-to-front (the innermost struct, `extended_dynamic_state_features`, is built
first so its address is available when the next struct up needs it in its
`p_next`). See Concepts (#6) for why `@ptrCast` is required at each link and why
these must be `var`.

### Specifying device extensions

```c++
std::vector<const char*> requiredDeviceExtension = {
    vk::KHRSwapchainExtensionName};
```

Not retranslated here — this is the `required_device_extensions` array
introduced at module scope in the previous lesson
(`vk.extensions.khr_swapchain.name`), and this lesson reuses it directly in
`vk.DeviceCreateInfo` below rather than declaring it a second time.

### Creating the logical device

```c++
vk::DeviceCreateInfo deviceCreateInfo{
    .pNext = &featureChain.get<vk::PhysicalDeviceFeatures2>(),
    .queueCreateInfoCount = 1,
    .pQueueCreateInfos = &deviceQueueCreateInfo,
    .enabledExtensionCount = static_cast<uint32_t>(requiredDeviceExtension.size()),
    .ppEnabledExtensionNames = requiredDeviceExtension.data()
};

device = vk::raii::Device(physicalDevice, deviceCreateInfo);
```

```zig
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
```

`featureChain.get<vk::PhysicalDeviceFeatures2>()` — the template's way of
retrieving "the head of the chain" — is just `&features2`, since we built the
chain ourselves and already have a name for its head. `.get<T>()` had no other
job here; it wasn't extracting anything computed, just handing back a pointer we
already control directly in Zig. The `vk::raii::Device` constructor's real job —
calling `vkCreateDevice` _and_ loading a device-level dispatch table — becomes
the two lines after `try
self.instance.createDevice(...)`, per Concepts (#2).

### Retrieving queue handles

```c++
vk::raii::Queue graphicsQueue = nullptr;
```

```zig
graphics_family: u32 = 0,
graphics_queue: vk.Queue = .null_handle,
```

Same "no RAII wrapper" pattern as `vk.PhysicalDevice`: a queue is owned by the
device that provides it, and there's no separate destroy call for it (destroying
the device implicitly retires all of its queues), so a plain handle with a
`.null_handle` default is all we need — closer in spirit to `vk.PhysicalDevice`
than to `vk.Device`.

### Retrieving queue handles

```c++
graphicsQueue = vk::raii::Queue(device, graphicsIndex, 0);
```

```zig
self.graphics_queue = self.device.getDeviceQueue(self.graphics_family, 0);
```

Per Concepts (#8), `vkGetDeviceQueue` cannot fail, so this is a direct
value-returning call — no `try`.

## Full Translated Code

```zig
const std = @import("std");
const sdl = @import("sdl3");
const vk = @import("vulkan");

const enable_validation_layers = @import("builtin").mode == .Debug;
const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};

const required_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,
};

const apis: []const vk.ApiInfo = &.{
    vk.features.version_1_0,
    vk.features.version_1_1,
    vk.features.version_1_3,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
    vk.extensions.ext_debug_utils,
};

const BaseDispatch = vk.BaseWrapper(apis);
const InstanceDispatch = vk.InstanceWrapper(apis);
const DeviceDispatch = vk.DeviceWrapper(apis);
const InstanceProxy = vk.InstanceProxy(apis);
const DeviceProxy = vk.DeviceProxy(apis);

const App = struct {
    allocator: std.mem.Allocator,
    window: *sdl.Window,

    vkb: BaseDispatch,
    instance_dispatch: InstanceDispatch,
    instance: InstanceProxy,
    debug_messenger: vk.DebugUtilsMessengerEXT = .null_handle,

    physical_device: vk.PhysicalDevice = .null_handle,

    device_dispatch: DeviceDispatch = undefined,
    device: DeviceProxy = undefined,
    graphics_family: u32 = 0,
    graphics_queue: vk.Queue = .null_handle,

    pub fn init(self: *App, allocator: std.mem.Allocator) !void {
        // Writing through `self` (a pointer the caller already placed in
        // stable storage) instead of returning `App` by value is required:
        // `self.instance.wrapper` and `self.device.wrapper` end up pointing
        // back into this same struct, and a by-value return would copy
        // those pointers' target out from under them. See Concepts (#3).
        self.* = .{
            .allocator = allocator,
            .window = undefined,
            .vkb = undefined,
            .instance_dispatch = undefined,
            .instance = undefined,
        };
        try self.initWindow();
        try self.initVulkan();
    }

    pub fn deinit(self: *App) void {
        self.device.destroyDevice(null);
        if (enable_validation_layers) {
            self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
        }
        self.instance.destroyInstance(null);
        self.window.destroy();
        sdl.quit();
    }

    fn initWindow(self: *App) !void {
        try sdl.init(.{ .video = true });
        self.window = try sdl.Window.create("Vulkan", 800, 600, .{ .vulkan = true, .resizable = true });
    }

    fn initVulkan(self: *App) !void {
        try self.createInstance();
        try self.setupDebugMessenger();
        try self.pickPhysicalDevice();
        try self.createLogicalDevice();
    }

    fn createInstance(self: *App) !void {
        self.vkb = try BaseDispatch.load(sdl.vulkan.getVkGetInstanceProcAddr());

        const app_info = vk.ApplicationInfo{
            .p_application_name = "Vulkan Tutorial",
            .application_version = vk.makeApiVersion(0, 1, 0, 0),
            .p_engine_name = "No Engine",
            .engine_version = vk.makeApiVersion(0, 1, 0, 0),
            .api_version = vk.API_VERSION_1_3,
        };

        var extension_count: u32 = 0;
        const sdl_extensions = try sdl.vulkan.getInstanceExtensions(&extension_count);

        var layer_names: []const [*:0]const u8 = &.{};
        if (enable_validation_layers) {
            layer_names = &validation_layers;
        }

        const instance_create_info = vk.InstanceCreateInfo{
            .p_application_info = &app_info,
            .enabled_extension_count = extension_count,
            .pp_enabled_extension_names = sdl_extensions,
            .enabled_layer_count = @intCast(layer_names.len),
            .pp_enabled_layer_names = layer_names.ptr,
        };

        const instance_handle = try self.vkb.createInstance(&instance_create_info, null);
        self.instance_dispatch = try InstanceDispatch.load(instance_handle, self.vkb.dispatch.vkGetInstanceProcAddr);
        self.instance = .{ .handle = instance_handle, .wrapper = &self.instance_dispatch };
    }

    fn setupDebugMessenger(self: *App) !void {
        if (!enable_validation_layers) return;

        const create_info = vk.DebugUtilsMessengerCreateInfoEXT{
            .message_severity = .{ .warning_bit_ext = true, .error_bit_ext = true },
            .message_type = .{ .general_bit_ext = true, .validation_bit_ext = true, .performance_bit_ext = true },
            .pfn_user_callback = debugCallback,
        };

        self.debug_messenger = try self.instance.createDebugUtilsMessengerEXT(&create_info, null);
    }

    fn debugCallback(
        severity: vk.DebugUtilsMessageSeverityFlagsEXT,
        msg_type: vk.DebugUtilsMessageTypeFlagsEXT,
        data: *const vk.DebugUtilsMessengerCallbackDataEXT,
        user_data: ?*anyopaque,
    ) callconv(.c) vk.Bool32 {
        _ = severity;
        _ = msg_type;
        _ = user_data;
        std.log.warn("validation layer: {s}", .{data.p_message});
        return vk.FALSE;
    }

    fn pickPhysicalDevice(self: *App) !void {
        var device_count: u32 = 0;
        _ = try self.instance.enumeratePhysicalDevices(&device_count, null);
        if (device_count == 0) return error.NoGpuWithVulkanSupport;

        const physical_devices = try self.allocator.alloc(vk.PhysicalDevice, device_count);
        defer self.allocator.free(physical_devices);
        _ = try self.instance.enumeratePhysicalDevices(&device_count, physical_devices.ptr);

        for (physical_devices) |candidate| {
            if (try self.isDeviceSuitable(candidate)) {
                self.physical_device = candidate;
                break;
            }
        }

        if (self.physical_device == .null_handle) return error.NoSuitableGpu;
    }

    fn isDeviceSuitable(self: *App, physical_device: vk.PhysicalDevice) !bool {
        if (!try self.checkDeviceExtensionSupport(physical_device)) return false;

        var family_count: u32 = 0;
        self.instance.getPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, null);
        const families = try self.allocator.alloc(vk.QueueFamilyProperties, family_count);
        defer self.allocator.free(families);
        self.instance.getPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, families.ptr);

        const supports_graphics = for (families) |family| {
            if (family.queue_flags.graphics_bit) break true;
        } else false;

        return supports_graphics and self.checkRequiredFeatures(physical_device);
    }

    fn checkDeviceExtensionSupport(self: *App, physical_device: vk.PhysicalDevice) !bool {
        var extension_count: u32 = 0;
        _ = try self.instance.enumerateDeviceExtensionProperties(physical_device, null, &extension_count, null);

        const available = try self.allocator.alloc(vk.ExtensionProperties, extension_count);
        defer self.allocator.free(available);
        _ = try self.instance.enumerateDeviceExtensionProperties(physical_device, null, &extension_count, available.ptr);

        for (required_device_extensions) |required| {
            const found = for (available) |ext| {
                if (std.mem.eql(u8, std.mem.sliceTo(&ext.extension_name, 0), std.mem.sliceTo(required, 0))) break true;
            } else false;
            if (!found) return false;
        }
        return true;
    }

    fn checkRequiredFeatures(self: *App, physical_device: vk.PhysicalDevice) bool {
        var extended_dynamic_state_features = vk.PhysicalDeviceExtendedDynamicStateFeaturesEXT{
            .s_type = .physical_device_extended_dynamic_state_features_ext,
            .p_next = null,
        };
        var vulkan_1_3_features = vk.PhysicalDeviceVulkan13Features{
            .s_type = .physical_device_vulkan_1_3_features,
            .p_next = @ptrCast(&extended_dynamic_state_features),
        };
        var vulkan_1_1_features = vk.PhysicalDeviceVulkan11Features{
            .s_type = .physical_device_vulkan_1_1_features,
            .p_next = @ptrCast(&vulkan_1_3_features),
        };
        var features2 = vk.PhysicalDeviceFeatures2{
            .s_type = .physical_device_features_2,
            .p_next = @ptrCast(&vulkan_1_1_features),
            .features = .{},
        };

        self.instance.getPhysicalDeviceFeatures2(physical_device, &features2);

        return vulkan_1_1_features.shader_draw_parameters == vk.TRUE and
            vulkan_1_3_features.dynamic_rendering == vk.TRUE and
            extended_dynamic_state_features.extended_dynamic_state == vk.TRUE;
    }

    fn createLogicalDevice(self: *App) !void {
        var family_count: u32 = 0;
        self.instance.getPhysicalDeviceQueueFamilyProperties(self.physical_device, &family_count, null);
        const families = try self.allocator.alloc(vk.QueueFamilyProperties, family_count);
        defer self.allocator.free(families);
        self.instance.getPhysicalDeviceQueueFamilyProperties(self.physical_device, &family_count, families.ptr);

        self.graphics_family = for (families, 0..) |family, i| {
            if (family.queue_flags.graphics_bit) break @intCast(i);
        } else return error.NoGraphicsQueueFamily;

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
};

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    // `app` lives here, on main's stack frame, for the rest of the
    // program — its address never changes after `init` runs, which is
    // required for the self-referential dispatch-table pointers set up
    // inside `init` (see Concepts #3).
    var app: App = undefined;
    try app.init(allocator);
    defer app.deinit();

    std.log.info("Vulkan logical device and graphics queue ready.", .{});
}
```

## Recap & What's Next

This lesson took the "there's no RAII, so do the plumbing by hand" lesson from
physical device selection and applied it to a resource that actually _has_ a
lifetime: the logical device. Concretely, we:

- added `device_dispatch`/`device` fields and loaded a device-level dispatch
  table from the instance's, mirroring exactly how the instance's own dispatch
  table was loaded from the base dispatch;
- replaced `std::ranges::find_if` + `std::distance` with a `for...else` that
  captures an index, extending last lesson's `any_of` pattern;
- reused the _shape_ of the `pNext` feature chain from `checkRequiredFeatures`
  to actually _enable_ those features this time, wiring `s_type`/`p_next` by
  hand and leaning on `@ptrCast` at each link;
- reused, rather than redeclared, the `required_device_extensions` list from the
  physical-devices lesson;
- retrieved the graphics queue with a plain, un-`try`'d call, since
  `vkGetDeviceQueue` can't fail;
- and — the one genuinely new wrinkle — had to change `App.init`'s shape
  (pointer receiver, no by-value return) specifically because self-pointers into
  `instance_dispatch`/`device_dispatch` can't survive a struct copy.

Known limitations carried forward from the C++ source at this point in the
tutorial: we assume the graphics queue family can also present to a surface, and
we haven't created a `VkSurfaceKHR` at all yet — that's the very next topic in
the series (window surface creation), followed shortly after by the swap chain,
both of which will need `self.graphics_family` and `self.device` exactly as
built here.
