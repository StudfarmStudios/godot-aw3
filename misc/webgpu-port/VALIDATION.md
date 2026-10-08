# Initial WebGPU compatibility batch — 8 October 2026

The engine remains on Godot 4.7.1. This validates the initial storage-format,
shadow-snapshot, transfer and procedural-gradient changes. It does **not** close
the full port checklist in [STATUS.md](STATUS.md).

## Results

| Check | Result |
| --- | --- |
| Production C++ conversion/remapping helpers, ASan + UBSan | Pass |
| Full native editor build, Dawn/Metal, arm64 | Pass |
| Real RenderingDevice GPU fixture, normal features | 25/25; no validation errors; exit 0 |
| Real RenderingDevice GPU fixture, forced storage fallbacks | 25/25; no validation errors; exit 0 |
| Headless procedural gradients | Pass: 1D/2D, width one, HDR/LDR, immediate changes |
| Existing standalone JavaScript driver models | 327 pass, 0 fail, 0 skip |
| Threaded web/Worker WebGPU driver objects, Emscripten 4.0.20 | Pass; full template/browser execution remains pending |
| Build-time WGSL baker | 185 modules compiled; **10 GLSL and 4 Tint failures remain** |
| Firefox/Windows/D3D12 runtime | Not run on this macOS host |
| End-to-end browser performance and full Forward+ visual matrix | Pending |

Native host: Apple M1 Ultra, macOS 26.5.2, WebGPU Forward+ through Dawn/Metal.
The normal and fallback runs used the same tested executable SHA-256:
`edb67dfe2c9414a6832cc5e52ff6f41fc7d8aad7cb9953e70eec0aa8a1ba40c4`.
The engine version banner identifies the starting commit `c0d51825`; the executable
includes the initial port batch on that base. The executable hash identifies the
exact tested binary.
Machine-readable results are in [results/driver-native-macos-arm64.json](results/driver-native-macos-arm64.json)
and [results/driver-fallback-macos-arm64.json](results/driver-fallback-macos-arm64.json).
Run durations include startup/cache effects and are not performance comparisons.

The forced-fallback run omits tier-1/2 features from native device creation and
uses sampled shadow textures instead of read/write storage bindings. The fixture
checks packed/narrow upload/readback, full shared views, GPU-written data on first
variant adaptation, repeated dispatch without rebinding, restored push constants,
array layers, distinct 3D depth values, a nonzero mip/layer slice, untouched layers,
and compressed BC3 array copies/readback through logical 2×2/1×1 mip tails.

Those tests also exposed and verified fixes for the old compressed readback's zero
row pitch, incorrect 3D copy origins, lost push-constant offsets at pass restarts,
and native Dawn's shutdown deadlock between device release and spontaneous async
pipeline completion. Native completions now use the event pump; compilation stays
asynchronous. Browser completion mode is unchanged.

## CPU conversion performance

The microbenchmark runs the actual production helper against the previously
supported R8 and float32-to-half loops from `c0d51825`. Five rounds alternate
execution order, with 100 iterations of a 1024×1024 one-channel image per sample.
The old half conversion truncates and flushes subnormals; the replacement rounds
to nearest even and preserves them. Both hardware and portable paths are checked
against the compiler's independent binary16 conversion implementation.

| Conversion | Baseline median, ms | New median, ms | Median paired new/baseline ratio |
| --- | ---: | ---: | ---: |
| R8 UNORM → float32 | 0.10860 | 0.11083 | 1.009 |
| float32 → half, native hardware | 0.42447 | 0.05870 | 0.138 |
| float32 → half, portable implementation on native CPU | 0.42245 | 0.38254 | 0.904 |

[Raw measurements](results/texture-conversion-macos-arm64.csv). R8 is around
baseline; this small CPU experiment does not establish an end-to-end improvement.
The portable implementation measured here is the code used without native half
instructions, **not a WebAssembly benchmark**. Packed formats previously lacked a
correct conversion and are not compared against an incorrect baseline.

Snapshot copies occur only for active read/write splits, immediately before a
non-skipped compute dispatch. All active sets share one pass restart. Repeated
binding performs no copies, and CPU uploads are no longer replayed to every
shadow. Each dispatch can write its source, so the next dispatch needs a fresh
snapshot. Copy/restart counters are included in the opt-in `[PERF]` output.
Actual scene bandwidth and frame-time acceptance remain on the checklist.

## Reproduce

Run from the engine checkout; substitute the local Dawn SDK path.

```sh
scons platform=macos target=editor arch=arm64 webgpu=yes \
  dawn_sdk_path=/absolute/path/to/dawn/install/Release \
  module_mono_enabled=no accesskit=no angle=no vulkan=no debug_symbols=no -j8
python3 webgpu_tests/driver_integration/run_native.py bin/godot.macos.editor.arm64
bin/godot.macos.editor.arm64 --headless --path webgpu_tests/driver_integration \
  --script test_gradients.gd

clang++ -std=c++17 -g -O1 -Wall -Wextra -Werror -fsanitize=address,undefined -I. \
  misc/webgpu-port/test_texture_formats.cpp -o /tmp/webgpu-format-tests
/tmp/webgpu-format-tests
clang++ -std=c++17 -O3 -I. -Iplatform/macos \
  misc/webgpu-port/benchmark_texture_formats.cpp -o /tmp/webgpu-format-benchmark
/tmp/webgpu-format-benchmark
node webgpu_tests/driver_unit_tests/run_tests.mjs

# Activate Emscripten first. This checks objects, not a linked export template.
scons platform=web target=template_debug webgpu=yes opengl3=no threads=yes \
  proxy_to_pthread=yes module_mono_enabled=no -j8 \
  bin/obj/drivers/webgpu/rendering_device_driver_webgpu.web.template_debug.wasm32.o \
  bin/obj/drivers/webgpu/rendering_context_driver_webgpu.web.template_debug.wasm32.o
```
