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

## MSAA follow-up

The next batch adds 18 real GPU checks (43 total in each mode), covering requested
2×/4×/8× counts, reported effective counts, equal-format and promoted RG16F color
resolves, 7×3 workgroup edges, and a destination at mip 1/layer 1 with untouched
neighbor data. Both native modes pass with no validation errors and clean exit.
Native editor linking and the six affected WebAssembly driver/renderer objects
pass. Tested binary SHA-256:
`180d7f82a0f00404fb8fcabc58a9a7609cde1f52c4e9a36a6cd5486385d689d4`.

Raw results: [normal](results/msaa-native-macos-arm64.json) and
[fallback](results/msaa-fallback-macos-arm64.json). Runtime durations are startup
measurements, not performance comparisons. Full Forward+ depth/GI/velocity and
runtime MSAA toggling remain in the renderer/browser matrix.

An API-wide supported-count mask preserves other backends' existing behavior and
makes the allocated count visible to RenderingDevice and renderer resolve loops.
Unlike a maximum-only clamp, it handles WebGPU's missing 2× count. Matching formats
still use the existing native resolve; promoted float formats use a cached compute
pipeline, one dispatch and no intermediate texture. Slice offsets are supplied
once by RenderingDevice, fixing the old double offset. Resolve dimension validation
now rejects a mismatch in any dimension.

The source fork's extra DOF pre-pass resolve was not copied: our final MSAA stage
already resolves depth unconditionally before post-processing. DOF's depth typing
and rendered output still need the feature fixture; this is not a claim that all
DOF cases are verified.

## Partial attachment clears

54/54 checks pass in **each** native capability mode, with zero validation errors
and clean exit. Native linking and threaded web driver/context object compilation
pass. The new cases cover mixed RGBA8, HDR RGBA16F, R32F, R32U and R32I
attachments; sparse clear masks; complete neighbor preservation; depth-only atlas
clears; stencil and depth probes after a combined clear; 4× MSAA; and more than
2048 consecutive partial clears, exercising upload-ring wraparound. Before the
fix, nine of the first ten new cases failed (the old depth-only path passed).
The baseline failure run was limited to 20 seconds and terminated after printing
its failed results; it is evidence of the pixel regressions, not clean teardown.

Tested binary SHA-256:
`14a27a10f7b5c290deea6479808590f7ccd43daef2f61fb3024883fc2b945c55`.
Raw results: [normal](results/clears-native-macos-arm64.json) and
[fallback](results/clears-fallback-macos-arm64.json).

The added path clears all selected attachments in **one draw in the existing
pass**. Color data occupies a slot in the existing batched upload ring; no
per-clear GPU buffer, bind group, or extra submission is created. Ring exhaustion
uses the existing flush/submit rule before beginning the next pass. Depth values
come from viewport depth range, so neither clear colors nor depth values create
new pipeline cache entries. The depth-only atlas path retains its uniform-free
draw. Partial store operations preserve neighboring pixels even when the pass's
ordinary store operation would discard the attachment.

### Clear performance experiment

[Raw alternating measurements](results/clear-benchmark-macos-arm64.json).
A local RenderingDevice records 128 tile clears per batch into a 512×512 target,
then `submit()`/`sync()` waits for GPU completion. Each trial warms 30 batches and
measures 120. Five trials alternate baseline/candidate order. This measures CPU
recording, encoding, submission and GPU completion without surface presentation;
it is not an isolated GPU timestamp or a game-frame benchmark.

- Depth baseline median across trials: **7.587 ms** per 128-clear batch.
- Depth candidate median: **7.580 ms**, paired median ratio **0.998**.
- Correct HDR color clearing: **9.656 ms** per batch (three trials). The previous
  color path erased neighboring pixels, so it is not a valid quality-equivalent
  performance baseline.

Individual depth trials vary from roughly 7.5 to 9.5 ms on this host. The result
is around baseline, not evidence of an end-to-end speedup. Browser/Windows timing
and actual scene impact remain unmeasured. The first frame-timed experiment was
presentation-limited, and the timestamp experiment hit a pre-existing Dawn API
validation error; neither was used in these measurements.

```sh
python3 webgpu_tests/driver_integration/run_clear_benchmark.py \
  /absolute/path/to/baseline /absolute/path/to/candidate \
  --output /tmp/clear-benchmark/results.json
```
