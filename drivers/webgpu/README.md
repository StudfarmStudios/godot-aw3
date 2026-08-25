# WebGPU Rendering Driver for Godot 4.6

A `RenderingDeviceDriver` / `RenderingContextDriver` implementation targeting
WebGPU via Emscripten's **emdawnwebgpu** port in browsers or native **Dawn** on
macOS. This enables Godot's Forward+ and Mobile renderers to use one WebGPU
driver in both environments.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  Godot RenderingDevice (servers/rendering/)             │
│    ↕ RenderingDeviceDriver interface                    │
├─────────────────────────────────────────────────────────┤
│  RenderingDeviceDriverWebGPU   (this driver)            │
│    • Buffers, Textures, Samplers, Pipelines, Draw calls │
│    • Push constant ring buffer emulation (group 3)      │
│    • Subpass flattening (each subpass → render pass)     │
│    • SPIR-V → WGSL translation (Tint, linked in)        │
├─────────────────────────────────────────────────────────┤
│  RenderingContextDriverWebGPU                           │
│    • Browser: import JS device, use HTML canvas         │
│    • macOS: request Dawn Metal device, use CAMetalLayer │
│    • Swap chain management via WGPUSurfaceTexture       │
├─────────────────────────────────────────────────────────┤
│  emdawnwebgpu (web) / Dawn Metal backend (macOS)        │
│    • WebGPU C API → browser WebGPU or native Metal      │
└─────────────────────────────────────────────────────────┘
```

### Files

| File | Lines | Purpose |
|------|-------|---------|
| `rendering_device_driver_webgpu.cpp/h` | ~5250 | Main driver: buffers, textures, pipelines, draw, compute |
| `rendering_context_driver_webgpu.cpp/h` | ~290 | Device bootstrap, surface/swap chain management |
| `rendering_shader_container_webgpu.cpp/h` | ~210 | Shader container format (SPIR-V storage + Tint WGSL conversion) |
| `webgpu_objects.h` | ~320 | GPU object wrappers (WGBuffer, WGTexture, WGShader, etc.) |
| `spirv_preprocess.cpp/h` | ~1700 | SPIR-V preprocessing passes before Tint conversion |
| `tint_wrapper.cpp/h` | ~55 | C++20 isolation wrapper for Tint API |
| `pixel_formats_webgpu.h` | ~710 | Godot DataFormat → WGPUTextureFormat mapping table |

## Key Design Decisions

### Push Constant Emulation
WebGPU has no push constants. Emulated via a **256 KB ring buffer** (read-only
storage, binding 120 in group 3) with 256-byte aligned slots and dynamic
offsets. Each draw advances the ring offset; dirty-state tracking skips
unchanged data. Bind group created once and reused with dynamic offsets.

### Subpass Flattening
WebGPU has no subpasses. Each Godot subpass becomes a separate
`WGPURenderPassEncoder`. Attachment load/store ops are set per-pass based on
Godot's subpass configuration.

### Shader Translation
GLSL → SPIR-V (glslang, at build time) → WGSL (Tint, linked in as C++).
SPIR-V is preprocessed in C++ before Tint conversion: combined image-samplers
are split into separate texture + sampler bindings, push constant blocks are
rewritten to storage buffer references at binding 120, and various other
fixups (depth image flags, position Y negation, point size stripping) are
applied. Tint is compiled as a thirdparty C++20 library via a thin wrapper
(`tint_wrapper.cpp`) that isolates its C++20 headers from the Godot build. Its
C++ namespace is renamed to `godot_tint` at compile time so native Dawn's own
Tint snapshot cannot collide with Godot's patched vendored copy in a static
macOS build.

### Barrier No-ops
WebGPU tracks resource hazards automatically. All barrier/sync commands are
no-ops.

### Pipeline Scheduling and Fences
Godot submits WebGPU calls from its render/main thread on both browser and
native builds. Deferred pipelines use WebGPU's asynchronous creation API, so
Dawn performs compilation on its workers while the renderer keeps its fallback
pipeline active. Pipeline wrappers are synchronized because native callbacks
can arrive from those workers. Native queue fences wait on Dawn futures;
browser fences are driven by browser event processing.

### Mobile Tonemapping
WebGPU cannot consume Vulkan `subpassInput` tonemap variants. When WebGPU is the
active rendering-device API, the Mobile renderer omits those variants and uses
the sampled-texture tonemap path. The selection is made at runtime so a macOS
binary containing both drivers keeps the subpass path when Metal is selected.

### Buffer Mapping
WebGPU buffer mapping is asynchronous. Driver uses a **shadow buffer** pattern:
maintains a CPU-side copy, flushes to GPU via `wgpuQueueWriteBuffer()` on
unmap. Buffer reads use `wgpuBufferMapAsync` with callbacks.

### Bind Group Layout (BGL) Rebinding
When a shader's expected BGL doesn't match the uniform set's BGL (e.g., due to
specialization constant variants or merged push constant layouts), the driver
creates **adapted bind groups** on-the-fly using the shader's layout. A cache
prevents redundant re-creation.

## Known Limitations

- **Max 4 bind groups** (WebGPU spec) — Godot uses sets 0–3, with set 3 shared
  between material uniforms and push constant ring buffer.
- **No 3-component texture formats** — RGB8, RGB16F, RGB32F are unsupported as
  texture formats in WebGPU. The driver maps these to RGBA equivalents.
- **No multi-draw-indirect** — Each indirect draw is dispatched individually.
- **No subgroup operations** — `LIMIT_SUBGROUP_IN_SHADERS` reports 0.
- **Mobile renderer auto-selected** — Forward+ requires ≥48 sampled textures
  per stage; most WebGPU implementations report 16, so the mobile renderer is
  used automatically.
- **Timestamp queries** — Optional; depend on the `timestamp-query` device
  feature. Graceful fallback to dummy results when unavailable.
- **Synchronous readback** — Not available in WebGPU. Timestamp and buffer
  readbacks use async callbacks with shadow buffers.

## Build Instructions

```bash
# Prerequisites: Emscripten 5.x with emdawnwebgpu port
source /path/to/emsdk/emsdk_env.sh

# Build web template (debug, no threads, WebGPU only)
scons platform=web target=template_debug dlink_enabled=yes webgpu=yes opengl3=no threads=no -j$(nproc)

# Build web template (release)
scons platform=web target=template_release dlink_enabled=yes webgpu=yes opengl3=no threads=no -j$(nproc)

# Build with both WebGPU and WebGL2 support
scons platform=web target=template_debug dlink_enabled=yes webgpu=yes opengl3=yes threads=no -j$(nproc)

# Build macOS editor with native Dawn installed as a static SDK
scons platform=macos target=editor webgpu=yes \
    dawn_sdk_path=/path/to/dawn/install -j$(sysctl -n hw.logicalcpu)

# Build a macOS release export template with native Dawn
scons platform=macos target=template_release webgpu=yes \
    dawn_sdk_path=/path/to/dawn/install -j$(sysctl -n hw.logicalcpu)
```

The build flag `webgpu=yes` enables `WEBGPU_ENABLED`. Web builds add
`--use-port=emdawnwebgpu` to compile and link flags. macOS builds require
`dawn_sdk_path` (or `DAWN_SDK_PATH`) to point at a Dawn CMake install containing
`include/webgpu/webgpu.h` and `lib/libwebgpu_dawn.a`; the normal Metal driver
remains the default.

## Project Settings

The rendering driver is selected via project settings:

- `rendering/renderer/rendering_method.web` — `forward_plus`, `mobile`, or
  `gl_compatibility` (default)
- `rendering/rendering_device/driver.web` — `webgpu` (used when rendering
  method is `forward_plus` or `mobile`)
- `rendering/rendering_device/driver.macos` — `webgpu`, `metal`, or `vulkan`

On macOS, `--rendering-driver webgpu` is convenient for per-run selection
without changing the project setting.

When `gl_compatibility` is selected, the existing WebGL 2.0 / GLES3 path is
used instead.

## Browser Compatibility

| Platform | Browser | Status |
|----------|---------|--------|
| macOS | Chrome 113+ | 100% — all demos and benchmarks pass |
| macOS | Safari 18+ | 100% — all demos and benchmarks pass |
| macOS | Firefox | 100% — all demos and benchmarks pass |
| Android | Chrome | 99% — minor edge cases |
| iOS | Safari | Mostly — some limitations |

The HTML export shell automatically detects WebGPU availability and shows a
clear error message if the browser doesn't support it.
