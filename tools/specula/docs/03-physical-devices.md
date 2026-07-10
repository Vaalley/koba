# Physical Devices and Queue Families :: Vulkan Documentation Project (Zig 0.16.0 + SDL3 + vulkan-zig)

## Overview

Up to this point in the series, `src/main.zig` has grown an `App` struct that:

1. opens an SDL3 window (translated from GLFW),
2. builds a `vk.Instance` (translated from `createInstance()`), and
3. installs a debug messenger (translated from `setupDebugMessenger()`).

This lesson adds the third call in `initVulkan()`: **`pickPhysicalDevice()`**.
The C++ source uses `vulkan.hpp`'s RAII wrappers (`vk::raii::PhysicalDevice`),
`std::ranges` algorithms, and C++ exceptions. None of those exist in Zig, and
that's actually the interesting part of this lesson: Zig's Vulkan bindings
(`@import("vulkan")`, referred to below as `vk`) are a much thinner,
closer-to-the-C-API layer than `vulkan.hpp`. Translating this chapter means
re-introducing, by hand, some of the plumbing that `vulkan.hpp` was quietly
doing for you — most notably the "ask for a count, then ask for the data"
two-call pattern that Vulkan uses for every `enumerate`/`get...Properties` call.

We extend the existing `App` struct in `src/main.zig` with:

- a `physical_device: vk.PhysicalDevice` field,
- `pickPhysicalDevice`, `isDeviceSuitable`, `checkDeviceExtensionSupport`, and
  `checkRequiredFeatures` methods,
- a module-level `required_device_extensions` list, matching the C++ file's
  file-scope `requiredDeviceExtension` vector.

Everything else from earlier lessons (window creation, instance creation, debug
messenger) is kept and shown in the full listing so the file stays compilable
end-to-end, but it's condensed since it isn't this lesson's topic.

## Concepts & Explanations

Before translating line-by-line, here are the ideas that explain _why_ the Zig
code looks different from the C++, not just _how_ to write it.

**1. There is no RAII wrapper for `vk.PhysicalDevice`, and that's fine.** In
`vulkan.hpp`, `vk::raii::PhysicalDevice` is a "smart handle" that lets you write
`physicalDevice.getProperties()`. `vulkan-zig` doesn't generate handle methods
at all — a `vk.PhysicalDevice` is just an opaque handle value (an `enum(usize)`
with `.null_handle` as its zero value). You always call through the object that
_owns_ the dispatch table:
`self.instance.getPhysicalDeviceProperties(physical_device)`. This mirrors
reality anyway: a physical device is never created or destroyed by your
application (it represents real hardware), so there is nothing to manage the
lifetime of — the "RAII" in the C++ version was purely a convenience for
method-call syntax, not resource ownership. This is a likely confusion point if
you're used to `vk.raii`: don't go looking for a `deinit` on `physical_device`,
there isn't one.

**2. `throw std::runtime_error` becomes a named Zig error.** Per the _Error
Union Type_ reference: a function that can fail returns `ErrorSet!T` (or just
`!T` to let Zig infer the error set). Where the C++ throws
`"failed to find GPUs with Vulkan support!"`, Zig returns
`error.NoGpuWithVulkanSupport`. The caller (`initVulkan`, and ultimately `main`)
propagates that with `try`, exactly like the _while/if with Error Unions_ docs
show for `eventuallyErrorSequence()`. No `catch unreachable` here — that idiom
is for cases you've proven can't happen, and "no Vulkan-capable GPU" is a
perfectly real runtime outcome.

**3. Vulkan's two-call enumeration pattern is now explicit.**
`instance.enumeratePhysicalDevices()` in `vulkan.hpp` hides a very common Vulkan
idiom: call once with a `null` output pointer to get a count, allocate storage,
then call again to fill it. `vulkan-zig`'s wrapper functions mirror the C API
almost 1:1, so we write that two-call dance ourselves using
`Allocator.alloc`/`allocator.free` (from the supplied stdlib docs). This is more
visible than the C++ version, but it's also _more honest_ about what's actually
happening on the GPU driver side — and it gives us an explicit
`defer allocator.free(...)` right next to the allocation, satisfying Zig's
philosophy of visible resource lifetimes.

We reach for a plain `[]T` slice here rather than `std.ArrayList`, because
Vulkan tells us the exact required length up front (via the count call).
`ArrayList` earns its keep when you're appending an _unknown_ number of items
incrementally; here we know `n` before we allocate anything, so a single
`alloc`/`free` pair is the simpler, more direct tool. (Where we _do_ need a
growable buffer later, in `createInstance`, note the `.empty` initializer —
default zero-initializing an `ArrayList` struct literal is deprecated in this
Zig version; `.empty` is the supported "empty, no allocation yet" starting
value.)

**4. `std::ranges::any_of` / `all_of` become `for` loops — often a
`for...else`.** Zig has no generic ranges/algorithms library. The idiomatic
replacement for "does any element satisfy this predicate" is a labeled `for`
loop with `break true`, paired with an `else false` clause that runs only if the
loop finished without breaking:

```zig
const supports_graphics = for (families) |family| {
    if (family.queue_flags.graphics_bit) break true;
} else false;
```

This is a direct, one-to-one match for `std::ranges::any_of`. For `all_of`, we
just loop and `return false` (or `continue`'s opposite: bail out) the moment one
element fails the predicate — that's what "stop at the first counter-example"
means.

**5. Bitmask flags are packed structs of `bool`s, not bits you mask.** C++
checks `!!(qfp.queueFlags & vk::QueueFlagBits::eGraphics)`. `vulkan-zig`
represents `Vk*Flags` types as Zig packed structs with one `bool` field per bit,
so the equivalent is just `family.queue_flags.graphics_bit` — no bitwise AND, no
double-negation-to-bool dance. This is _not_ the same thing as
`VkBool32`/`vk.Bool32` fields (used in feature structs like
`shader_draw_parameters: Bool32`), which remain plain `u32` values compared
against `vk.TRUE`/`vk.FALSE`. Mixing these two up is an easy mistake: flags →
`.some_bit : bool`; features/booleans → `Bool32` compared to `vk.TRUE`.

**6. `pNext` feature-chaining is now something _you_ wire up.** `vulkan.hpp`'s
`getFeatures2<A, B, C, D>()` template builds a linked list of structs (via each
struct's `pNext`) for you and lets you `.get<T>()` any member back out.
`vulkan-zig` has no templates, so we build that same linked list by hand: set
each struct's `.s_type` and `.p_next` explicitly, pass the head of the chain to
`getPhysicalDeviceFeatures2`, and read the fields back out of our own local
variables afterward. It's more typing, but it also demystifies what the C++
template was doing — it's _just_ pointer chaining.

**7. Fixed C-string buffers need `std.mem.sliceTo`, not `strcmp`.**
`vk.ExtensionProperties.extension_name` (like
`VkPhysicalDeviceProperties.deviceName`) is a fixed `[256]u8` buffer,
null-padded. Comparing two of these means trimming both at the first `0` byte
and comparing the resulting slices:
`std.mem.eql(u8, std.mem.sliceTo(&ext.extension_name, 0), "VK_KHR_swapchain")`.

**8. Naming conventions shift, but predictably.** Types stay `PascalCase`
(`vk.PhysicalDeviceVulkan13Features`), function/method names stay `camelCase`
minus the `vk` prefix (`getPhysicalDeviceProperties`), and enum members / struct
fields become `snake_case` (`vk::PhysicalDeviceType::eDiscreteGpu` →
`.discrete_gpu`; `deviceType` → `device_type`). `vk::ApiVersion13` becomes the
constant `vk.API_VERSION_1_3`; `vk::KHRSwapchainExtensionName` becomes
`vk.extensions.khr_swapchain.name`.

**9. `std::multimap` scoring vs. a single-pass "best so far".** The "Base device
suitability checks" section builds a full sorted `multimap` of every candidate's
score, then reads the best one off the end. In Zig we don't need the whole
sorted collection — we only ever want the maximum — so a single pass tracking
`best_score`/`best_device` gets the same answer with less machinery. The
trade-off: the C++ version could easily be extended to "try the second-best if
the best fails later," while the single-pass version throws that information
away. For this lesson (and for the tutorial's own final version, which drops
scoring entirely in favor of a strict suitability predicate) that trade-off is
worth it. If you needed the ranked list, you'd collect `.{score, device}` pairs
into a slice and `std.sort.block`/`std.mem.sort` it — more like the `ArrayList`
you'd reach for when the final size isn't known ahead of time.

## Code Translation Sections

### Selecting a physical device — wiring `pickPhysicalDevice` into `initVulkan`

```c++
void initVulkan()
{
    createInstance();
    setupDebugMessenger();
    pickPhysicalDevice();
}

void pickPhysicalDevice()
{
}
```

```zig
fn initVulkan(self: *App) !void {
    try self.createInstance();
    try self.setupDebugMessenger();
    try self.pickPhysicalDevice();
}

fn pickPhysicalDevice(self: *App) !void {
    _ = self;
}
```

Because `createInstance` and `setupDebugMessenger` can now fail (they return
`!void`, same as before), and `pickPhysicalDevice` will too, `initVulkan` just
chains `try` calls — a Zig error union bubbles up automatically, the same way a
C++ exception would propagate up the call stack, but visibly, in the function
signature.

### Selecting a physical device — the field

```c++
vk::raii::PhysicalDevice physicalDevice = nullptr;
```

```zig
physical_device: vk.PhysicalDevice = .null_handle,
```

As covered in Concepts (#1), there's no RAII wrapper to hold — just the handle
itself, defaulted to the "no device chosen yet" sentinel value.

### Selecting a physical device — enumerating and the empty check

```c++
auto physicalDevices = instance.enumeratePhysicalDevices()

if (physicalDevices.empty())
{
    throw std::runtime_error("failed to find GPUs with Vulkan support!");
}
```

```zig
var device_count: u32 = 0;
_ = try self.instance.enumeratePhysicalDevices(&device_count, null);

if (device_count == 0) {
    return error.NoGpuWithVulkanSupport;
}

const physical_devices = try self.allocator.alloc(vk.PhysicalDevice, device_count);
defer self.allocator.free(physical_devices);
_ = try self.instance.enumeratePhysicalDevices(&device_count, physical_devices.ptr);
```

This is the two-call pattern from Concepts (#3) made explicit: the first call
(output pointer `null`) only fills in `device_count`; we allocate exactly that
many slots, then call again to fill them. `.empty()` becomes
`device_count == 0`, and `throw` becomes `return error.NoGpuWithVulkanSupport` —
an error name we're free to choose, unlike C++'s free-text message.

### Selecting a physical device — naive "take the first one" draft

```c++
for (physicalDevice : physicalDevices)
{
    break;
}
```

```zig
for (physical_devices) |candidate| {
    self.physical_device = candidate;
    break;
}
```

A direct, unconditional translation of the placeholder loop — no suitability
check yet, matching the source at this stage of the tutorial.

### Base device suitability checks — properties and features

```c++
auto deviceProperties = physicalDevice.getProperties();
auto deviceFeatures = physicalDevice.getFeatures();
```

```zig
const properties = self.instance.getPhysicalDeviceProperties(physical_device);
const features = self.instance.getPhysicalDeviceFeatures(physical_device);
```

Both `vkGetPhysicalDeviceProperties` and `vkGetPhysicalDeviceFeatures` are plain
"fill this struct" calls with no `VkResult` — they cannot fail — so
`vulkan-zig`'s wrappers return the struct directly rather than an error union.
No `try` needed here, unlike the `enumerate*` calls above.

### Base device suitability checks — the first (discrete GPU + geometry shader) predicate

```c++
bool isDeviceSuitable(vk::raii::PhysicalDevice const & physicalDevice)
{
    auto deviceProperties = physicalDevice.getProperties();
    auto deviceFeatures = physicalDevice.getFeatures();

    if (deviceProperties.deviceType == vk::PhysicalDeviceType::eDiscreteGpu && deviceFeatures.geometryShader) {
        return true;
    }

    return false;
}
```

```zig
fn isDeviceSuitableDraft(self: *App, physical_device: vk.PhysicalDevice) bool {
    const properties = self.instance.getPhysicalDeviceProperties(physical_device);
    const features = self.instance.getPhysicalDeviceFeatures(physical_device);

    return properties.device_type == .discrete_gpu and features.geometry_shader == vk.TRUE;
}
```

Note `features.geometry_shader == vk.TRUE`, not a bare `bool` — per Concepts
(#5), `VkPhysicalDeviceFeatures` fields are `Bool32`, distinct from the
packed-bool `*Flags` types we'll meet next. This draft predicate is shown for
teaching continuity with the source; it gets replaced below.

### Base device suitability checks — the scored `pickPhysicalDevice`

```c++
std::multimap<int, vk::raii::PhysicalDevice> candidates;

for (const auto& pd : physicalDevices)
{
    auto deviceProperties = pd.getProperties();
    auto deviceFeatures = pd.getFeatures();
    uint32_t score = 0;

    if (deviceProperties.deviceType == vk::PhysicalDeviceType::eDiscreteGpu) {
        score += 1000;
    }
    score += deviceProperties.limits.maxImageDimension2D;

    if (!deviceFeatures.geometryShader)
    {
       continue;
    }
    candidates.insert(std::make_pair(score, pd));
}

if (!candidates.empty() && candidates.rbegin()->first > 0)
{
    physicalDevice = candidates.rbegin()->second;
}
else
{
    throw std::runtime_error("failed to find a suitable GPU!");
}
```

```zig
fn pickPhysicalDeviceScored(self: *App, physical_devices: []const vk.PhysicalDevice) !void {
    var best_score: u32 = 0;
    var best_device: vk.PhysicalDevice = .null_handle;

    for (physical_devices) |candidate| {
        const properties = self.instance.getPhysicalDeviceProperties(candidate);
        const features = self.instance.getPhysicalDeviceFeatures(candidate);

        if (features.geometry_shader != vk.TRUE) continue;

        var score: u32 = 0;
        if (properties.device_type == .discrete_gpu) score += 1000;
        score += properties.limits.max_image_dimension_2d;

        if (score > best_score) {
            best_score = score;
            best_device = candidate;
        }
    }

    if (best_device == .null_handle) return error.NoSuitableGpu;
    self.physical_device = best_device;
}
```

As discussed in Concepts (#9), we skip building a sorted `multimap` and just
track the running maximum. `continue` on a missing feature is identical in both
languages — Zig kept that one unchanged. This function is shown for teaching
parity with the source's narrative; the tutorial itself replaces it with a
stricter, non-scored predicate next, and so does our final file.

### API version check

```c++
bool supportsVulkan1_3 = physicalDevice.getProperties().apiVersion >= vk::ApiVersion13;
```

```zig
const supports_vulkan_1_3 = properties.api_version >= vk.API_VERSION_1_3;
```

`vk::ApiVersion13` is a `vulkan.hpp` convenience constant; its `vulkan-zig`
counterpart is `vk.API_VERSION_1_3`, an already-packed version integer (same
encoding `VK_API_VERSION_1_3` uses in the C headers).

### Queue family check

```c++
auto queueFamilies = physicalDevice.getQueueFamilyProperties();
bool supportsGraphics =
    std::ranges::any_of(queueFamilies, [](auto const &qfp) { return !!(qfp.queueFlags & vk::QueueFlagBits::eGraphics); });
```

```zig
var family_count: u32 = 0;
self.instance.getPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, null);

const families = try self.allocator.alloc(vk.QueueFamilyProperties, family_count);
defer self.allocator.free(families);
self.instance.getPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, families.ptr);

const supports_graphics = for (families) |family| {
    if (family.queue_flags.graphics_bit) break true;
} else false;
```

Two things stack up here: the two-call pattern again
(`vkGetPhysicalDeviceQueueFamilyProperties` has no `VkResult`, so no `try`, but
it _is_ a count-then-fill call), and the `for...else` translation of `any_of`
from Concepts (#4)/(#5). This chapter only asks "does _any_ queue family support
graphics" — finding _which index_ is next lesson's job (logical device +
queues), so we deliberately don't store an index yet, matching the given source
exactly.

### Required extension check

```c++
std::vector<const char*> requiredDeviceExtension = {vk::KHRSwapchainExtensionName};

auto availableDeviceExtensions = physicalDevice.enumerateDeviceExtensionProperties();
bool supportsAllRequiredExtensions =
  std::ranges::all_of( requiredDeviceExtension,
                       [&availableDeviceExtensions]( auto const & requiredDeviceExtension )
                       {
                           return std::ranges::any_of( availableDeviceExtensions,
                                                       [requiredDeviceExtension]( auto const & availableDeviceExtension )
                                                       { return strcmp( availableDeviceExtension.extensionName, requiredDeviceExtension ) == 0; } );
                       } );
```

```zig
const required_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,
};

fn checkDeviceExtensionSupport(self: *App, physical_device: vk.PhysicalDevice) !bool {
    var extension_count: u32 = 0;
    _ = try self.instance.enumerateDeviceExtensionProperties(physical_device, null, &extension_count, null);

    const available = try self.allocator.alloc(vk.ExtensionProperties, extension_count);
    defer self.allocator.free(available);
    _ = try self.instance.enumerateDeviceExtensionProperties(physical_device, null, &extension_count, available.ptr);

    for (required_device_extensions) |required| {
        const required_name = std.mem.sliceTo(required, 0);

        const found = for (available) |ext| {
            const available_name = std.mem.sliceTo(&ext.extension_name, 0);
            if (std.mem.eql(u8, available_name, required_name)) break true;
        } else false;

        if (!found) return false;
    }

    return true;
}
```

This is `all_of` wrapping `any_of`: the outer `for` returns `false` the moment
one required extension is missing (short-circuiting, like `all_of` does), and
the inner `for...else` is the `any_of` from before. `strcmp(...) == 0` becomes
`std.mem.eql(u8, ...)` over two `sliceTo`-trimmed views of the fixed `[256]u8`
name buffers (Concepts #7).

### Required feature check

```c++
auto features                 = physicalDevice.template getFeatures2<vk::PhysicalDeviceFeatures2,
                                                                     vk::PhysicalDeviceVulkan11Features,
                                                                     vk::PhysicalDeviceVulkan13Features,
                                                                     vk::PhysicalDeviceExtendedDynamicStateFeaturesEXT>();
bool supportsRequiredFeatures = features.template get<vk::PhysicalDeviceVulkan11Features>().shaderDrawParameters &&
                                features.template get<vk::PhysicalDeviceVulkan13Features>().dynamicRendering &&
                                features.template get<vk::PhysicalDeviceExtendedDynamicStateFeaturesEXT>().extendedDynamicState;
```

```zig
fn checkRequiredFeatures(self: *App, physical_device: vk.PhysicalDevice) bool {
    var extended_dynamic_state: vk.PhysicalDeviceExtendedDynamicStateFeaturesEXT = .{
        .s_type = .physical_device_extended_dynamic_state_features_ext,
        .extended_dynamic_state = vk.FALSE,
    };
    var vulkan_1_3_features: vk.PhysicalDeviceVulkan13Features = .{
        .s_type = .physical_device_vulkan_1_3_features,
        .p_next = &extended_dynamic_state,
        .dynamic_rendering = vk.FALSE,
    };
    var vulkan_1_1_features: vk.PhysicalDeviceVulkan11Features = .{
        .s_type = .physical_device_vulkan_1_1_features,
        .p_next = &vulkan_1_3_features,
        .shader_draw_parameters = vk.FALSE,
    };
    var features2: vk.PhysicalDeviceFeatures2 = .{
        .s_type = .physical_device_features_2,
        .p_next = &vulkan_1_1_features,
        .features = std.mem.zeroes(vk.PhysicalDeviceFeatures),
    };

    self.instance.getPhysicalDeviceFeatures2(physical_device, &features2);

    return vulkan_1_1_features.shader_draw_parameters == vk.TRUE and
        vulkan_1_3_features.dynamic_rendering == vk.TRUE and
        extended_dynamic_state.extended_dynamic_state == vk.TRUE;
}
```

Where the C++ template builds and queries a `StructureChain` for you, Zig has us
build the linked list ourselves (Concepts #6): each struct's `.p_next` points at
the next one, ending with `features2` at the head, which is what we hand to the
driver. After the call, the driver has written its answers into
`extended_dynamic_state`, `vulkan_1_3_features`, and `vulkan_1_1_features` — the
same local variables we set up, since they're linked by pointer, not copied. We
initialize the queried-for `bool32` fields to `vk.FALSE` mostly for clarity (the
driver overwrites them); the `s_type` fields, however, are load-bearing — Vulkan
uses them to identify each link in the chain.

### The complete function

```c++
bool isDeviceSuitable( vk::raii::PhysicalDevice const & physicalDevice )
{
  bool supportsVulkan1_3 = physicalDevice.getProperties().apiVersion >= vk::ApiVersion13;
  auto queueFamilies    = physicalDevice.getQueueFamilyProperties();
  bool supportsGraphics = std::ranges::any_of( queueFamilies, []( auto const & qfp ) { return !!( qfp.queueFlags & vk::QueueFlagBits::eGraphics ); } );
  auto availableDeviceExtensions = physicalDevice.enumerateDeviceExtensionProperties();
  bool supportsAllRequiredExtensions = /* ... */;
  auto features = /* getFeatures2 chain */;
  bool supportsRequiredFeatures = /* ... */;
  return supportsVulkan1_3 && supportsGraphics && supportsAllRequiredExtensions && supportsRequiredFeatures;
}

void pickPhysicalDevice()
{
  std::vector<vk::raii::PhysicalDevice> physicalDevices = instance.enumeratePhysicalDevices();
  auto const devIter = std::ranges::find_if( physicalDevices, [&]( auto const & physicalDevice ) { return isDeviceSuitable( physicalDevice ); } );
  if ( devIter == physicalDevices.end() )
  {
    throw std::runtime_error( "failed to find a suitable GPU!" );
  }
  physicalDevice = *devIter;
}
```

```zig
fn isDeviceSuitable(self: *App, physical_device: vk.PhysicalDevice) !bool {
    const properties = self.instance.getPhysicalDeviceProperties(physical_device);
    const supports_vulkan_1_3 = properties.api_version >= vk.API_VERSION_1_3;

    var family_count: u32 = 0;
    self.instance.getPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, null);
    const families = try self.allocator.alloc(vk.QueueFamilyProperties, family_count);
    defer self.allocator.free(families);
    self.instance.getPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, families.ptr);

    const supports_graphics = for (families) |family| {
        if (family.queue_flags.graphics_bit) break true;
    } else false;

    const supports_all_extensions = try self.checkDeviceExtensionSupport(physical_device);
    const supports_required_features = self.checkRequiredFeatures(physical_device);

    return supports_vulkan_1_3 and supports_graphics and supports_all_extensions and supports_required_features;
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

    const properties = self.instance.getPhysicalDeviceProperties(self.physical_device);
    std.log.info("selected physical device: {s}", .{std.mem.sliceTo(&properties.device_name, 0)});
}
```

`std::ranges::find_if` over the device list becomes a plain `for` loop that sets
`self.physical_device` and `break`s as soon as `isDeviceSuitable` returns `true`
— since Zig doesn't have iterators to compare against `.end()`, we just check
the sentinel `.null_handle` afterward, the same trick used for "was nothing
chosen" throughout this lesson. Note `isDeviceSuitable` is now `!bool`, not
`bool`: it can fail (allocation failure, or a `VkResult` error from
`enumerateDeviceExtensionProperties`), and that failure needs to propagate —
`try self.isDeviceSuitable(candidate)` does exactly that, per the _Error Union
Type_ rules on combining a fallible call inside a boolean expression context.

## Full Translated Code

The following extends the existing `src/main.zig`. Earlier-lesson plumbing
(`createInstance`, `setupDebugMessenger`, the SDL3/Vulkan loader glue) is kept
but condensed, since this lesson's focus is `pickPhysicalDevice` and its
helpers; adjust loader/dispatch details to match your exact `vulkan-zig` package
version if they differ.

```zig
const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl3");
const vk = @import("vulkan");

const window_title = "Vulkan";
const window_width: c_int = 800;
const window_height: c_int = 600;

const enable_validation_layers = builtin.mode == .Debug;
const validation_layer_name: [*:0]const u8 = "VK_LAYER_KHRONOS_validation";

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
const Instance = vk.InstanceProxy(apis);

/// Device extensions every physical device we accept must support.
/// Mirrors the file-scope `requiredDeviceExtension` vector from the C++ source.
const required_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,
};

const App = struct {
    allocator: std.mem.Allocator,
    window: *sdl.SDL_Window,

    vkb: BaseDispatch,
    instance: Instance,
    instance_dispatch: *InstanceDispatch,
    debug_messenger: vk.DebugUtilsMessengerEXT = .null_handle,

    physical_device: vk.PhysicalDevice = .null_handle,

    fn init(allocator: std.mem.Allocator) !App {
        if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) {
            return error.SdlInitFailed;
        }

        const window = sdl.SDL_CreateWindow(
            window_title,
            window_width,
            window_height,
            sdl.SDL_WINDOW_VULKAN,
        ) orelse return error.WindowCreationFailed;

        return .{
            .allocator = allocator,
            .window = window,
            .vkb = undefined,
            .instance = undefined,
            .instance_dispatch = undefined,
        };
    }

    fn deinit(self: *App) void {
        if (self.debug_messenger != .null_handle) {
            self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
        }
        if (self.instance.handle != .null_handle) {
            self.instance.destroyInstance(null);
        }
        self.allocator.destroy(self.instance_dispatch);
        sdl.SDL_DestroyWindow(self.window);
        sdl.SDL_Quit();
    }

    fn initVulkan(self: *App) !void {
        try self.createInstance();
        try self.setupDebugMessenger();
        try self.pickPhysicalDevice();
    }

    // -- Carried over from the instance-creation lesson; condensed here. --
    fn createInstance(self: *App) !void {
        self.vkb = try BaseDispatch.load(sdl.SDL_Vulkan_GetVkGetInstanceProcAddr());

        var sdl_extension_count: u32 = undefined;
        const sdl_extensions = sdl.SDL_Vulkan_GetInstanceExtensions(&sdl_extension_count) orelse
            return error.NoSdlVulkanExtensions;

        var extensions: std.ArrayList([*:0]const u8) = .empty;
        defer extensions.deinit(self.allocator);
        for (sdl_extensions[0..sdl_extension_count]) |ext| {
            try extensions.append(self.allocator, ext);
        }
        if (enable_validation_layers) {
            try extensions.append(self.allocator, vk.extensions.ext_debug_utils.name);
        }

        const layers: []const [*:0]const u8 = if (enable_validation_layers)
            &.{validation_layer_name}
        else
            &.{};

        const app_info: vk.ApplicationInfo = .{
            .p_application_name = window_title,
            .application_version = vk.makeApiVersion(0, 1, 0, 0),
            .p_engine_name = "No Engine",
            .engine_version = vk.makeApiVersion(0, 1, 0, 0),
            .api_version = vk.API_VERSION_1_3,
        };

        const instance_handle = try self.vkb.createInstance(&.{
            .p_application_info = &app_info,
            .enabled_layer_count = @intCast(layers.len),
            .pp_enabled_layer_names = layers.ptr,
            .enabled_extension_count = @intCast(extensions.items.len),
            .pp_enabled_extension_names = extensions.items.ptr,
        }, null);

        self.instance_dispatch = try self.allocator.create(InstanceDispatch);
        self.instance_dispatch.* = try InstanceDispatch.load(instance_handle, self.vkb.dispatch.vkGetInstanceProcAddr);
        self.instance = Instance.init(instance_handle, self.instance_dispatch);
    }

    // -- Carried over from the debug-messenger lesson; condensed here. --
    fn setupDebugMessenger(self: *App) !void {
        if (!enable_validation_layers) return;

        self.debug_messenger = try self.instance.createDebugUtilsMessengerEXT(&.{
            .message_severity = .{ .warning_bit_ext = true, .error_bit_ext = true },
            .message_type = .{ .general_bit_ext = true, .validation_bit_ext = true, .performance_bit_ext = true },
            .pfn_user_callback = debugCallback,
        }, null);
    }

    // -- New in this lesson --

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

        const properties = self.instance.getPhysicalDeviceProperties(self.physical_device);
        std.log.info("selected physical device: {s}", .{std.mem.sliceTo(&properties.device_name, 0)});
    }

    fn isDeviceSuitable(self: *App, physical_device: vk.PhysicalDevice) !bool {
        const properties = self.instance.getPhysicalDeviceProperties(physical_device);
        const supports_vulkan_1_3 = properties.api_version >= vk.API_VERSION_1_3;

        var family_count: u32 = 0;
        self.instance.getPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, null);
        const families = try self.allocator.alloc(vk.QueueFamilyProperties, family_count);
        defer self.allocator.free(families);
        self.instance.getPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, families.ptr);

        const supports_graphics = for (families) |family| {
            if (family.queue_flags.graphics_bit) break true;
        } else false;

        const supports_all_extensions = try self.checkDeviceExtensionSupport(physical_device);
        const supports_required_features = self.checkRequiredFeatures(physical_device);

        return supports_vulkan_1_3 and supports_graphics and supports_all_extensions and supports_required_features;
    }

    fn checkDeviceExtensionSupport(self: *App, physical_device: vk.PhysicalDevice) !bool {
        var extension_count: u32 = 0;
        _ = try self.instance.enumerateDeviceExtensionProperties(physical_device, null, &extension_count, null);

        const available = try self.allocator.alloc(vk.ExtensionProperties, extension_count);
        defer self.allocator.free(available);
        _ = try self.instance.enumerateDeviceExtensionProperties(physical_device, null, &extension_count, available.ptr);

        for (required_device_extensions) |required| {
            const required_name = std.mem.sliceTo(required, 0);

            const found = for (available) |ext| {
                const available_name = std.mem.sliceTo(&ext.extension_name, 0);
                if (std.mem.eql(u8, available_name, required_name)) break true;
            } else false;

            if (!found) return false;
        }

        return true;
    }

    fn checkRequiredFeatures(self: *App, physical_device: vk.PhysicalDevice) bool {
        var extended_dynamic_state: vk.PhysicalDeviceExtendedDynamicStateFeaturesEXT = .{
            .s_type = .physical_device_extended_dynamic_state_features_ext,
            .extended_dynamic_state = vk.FALSE,
        };
        var vulkan_1_3_features: vk.PhysicalDeviceVulkan13Features = .{
            .s_type = .physical_device_vulkan_1_3_features,
            .p_next = &extended_dynamic_state,
            .dynamic_rendering = vk.FALSE,
        };
        var vulkan_1_1_features: vk.PhysicalDeviceVulkan11Features = .{
            .s_type = .physical_device_vulkan_1_1_features,
            .p_next = &vulkan_1_3_features,
            .shader_draw_parameters = vk.FALSE,
        };
        var features2: vk.PhysicalDeviceFeatures2 = .{
            .s_type = .physical_device_features_2,
            .p_next = &vulkan_1_1_features,
            .features = std.mem.zeroes(vk.PhysicalDeviceFeatures),
        };

        self.instance.getPhysicalDeviceFeatures2(physical_device, &features2);

        return vulkan_1_1_features.shader_draw_parameters == vk.TRUE and
            vulkan_1_3_features.dynamic_rendering == vk.TRUE and
            extended_dynamic_state.extended_dynamic_state == vk.TRUE;
    }
};

fn debugCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(.c) vk.Bool32 {
    _ = message_severity;
    _ = message_types;
    _ = p_user_data;
    if (p_callback_data) |data| {
        std.log.debug("validation layer: {s}", .{data.p_message});
    }
    return vk.FALSE;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try App.init(allocator);
    defer app.deinit();

    try app.initVulkan();
}
```

## Recap & What's Next

We extended `initVulkan()` with `pickPhysicalDevice()`, which now:

- enumerates physical devices with Vulkan's explicit two-call pattern
  (`allocator.alloc`/`allocator.free`, mirroring `Allocator`'s documented
  contract instead of relying on a `std::vector`'s destructor),
- picks the first candidate for which `isDeviceSuitable` returns `true`,
- and returns named errors (`error.NoGpuWithVulkanSupport`,
  `error.NoSuitableGpu`) instead of throwing, propagated with `try` the same way
  earlier lessons' `createInstance`/`setupDebugMessenger` already do.

Along the way we replaced C++-only conveniences with plain Zig idioms: no RAII
handle wrapper (just a bare `vk.PhysicalDevice`), no `std::ranges` algorithms
(`for...else` instead), no template-generated `pNext` chains (hand-wired structs
instead), and packed-bool `*Flags` fields instead of bitmask arithmetic.

`self.physical_device` is now populated, but we still only know _that_ some
queue family supports graphics — not _which index_ it is. The next lesson
("Logical device and queues") will re-run a very similar
`getPhysicalDeviceQueueFamilyProperties` two-call query, this time capturing the
winning index, and use it to create a `vk.Device` and retrieve a `vk.Queue` —
reusing every pattern introduced here: the count-then-fill loop, the
`for...else` search, and error-union propagation all the way up through
`initVulkan`.
