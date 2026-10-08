# WebGPU compatibility batches — 8 October 2026

The engine remains on Godot 4.7.1. This records the initial storage-format,
shadow-snapshot, transfer and procedural-gradient changes and subsequent native
feature validation. The first results table is historical; later sections record
the expanded coverage and corrected defects. It does **not** close
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
already resolves depth unconditionally before post-processing. At this checkpoint, DOF's depth typing
and rendered output still needed the feature fixture. The later reduced-capability
renderer section records 153 passing checks in five modes; it does not claim all
possible DOF cases are verified.

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

## Headless export lifetime and native GPU profiling

The baseline 4.7 editor reproduced `Parameter "singleton" is null` in
`EditorNode::is_cmdline_mode()` after headless import and then printed a signal-11
teardown crash. Keeping command-line mode alive after EditorNode destruction fixes
this on 4.7; the existing `window_can_draw()` mode-detection rule is preserved.
One fresh import and three Web `--export-pack` runs now exit cleanly, without errors,
and produce valid `GDPC` packs. [Raw results](results/headless-exports-macos-arm64.json).
This does not validate a complete browser template or a C# application export.

Native GPU profiling had two independent gaps: standalone Dawn `WriteTimestamp`
required an unsafe toggle, and an empty compute pass produced zero counters on the
Apple M1 Ultra. Standard timestamp writes on a cached 1×1 attachment-clear pass
produce nonzero values. Native readback maps use waitable callbacks delivered after
the frame fence and before destroying a query pool. The fixture observes **58 fresh,
ordered samples** across 60 frames, with no validation errors and clean exit.
[Raw result](results/timestamps-macos-arm64.json). Browser timestamp readback stays
disabled; this does not claim browser profiler support. Each native marker adds a
tiny clear pass, so profiling itself has overhead; clear performance measurements
above were collected without this timestamp instrumentation.

Native linking and threaded web driver/context objects pass. The final native
build also repeats all **54 GPU checks in each capability mode**, with no errors
and clean exit: [normal](results/final-native-macos-arm64.json),
[fallback](results/final-fallback-macos-arm64.json). These final tests share binary
SHA-256 `80f1f1c07f8934691aa3159098b375dbde8b4ae7dfc0a660d496a2bb9dd11bcc`.
The full shader/export/font/GI/browser matrix in STATUS.md remains unfinished.

```sh
python3 webgpu_tests/driver_integration/run_headless_exports.py \
  /absolute/path/to/godot --output /tmp/headless-export-results
/absolute/path/to/godot --path webgpu_tests/driver_integration \
  --script test_timestamps.gd --rendering-driver webgpu --rendering-method forward_plus
```

The timestamp fixture requires native TimestampQuery support. Reject engine errors
in the log as well as a nonzero exit code or a failed `TIMESTAMP_TEST` record.

## Logical copies, fonts and upscalers

The completed parallel batch links a native editor and compiles the threaded web
objects for the driver/preprocessor, FSR1, FSR2, texture storage and both text
servers. Final frozen native binary SHA-256:
`46dc9ae5ce79ead485786b146e960ed19ea5e6c240475836f3a8be773aa90b62`.
Native tests use Dawn/Metal on Apple M1 Ultra/macOS 26.5.2. Full web-template and
Firefox/Windows/D3D12 runs are still missing; successful object compilation is not
browser validation. Build-time precompilation still reports 10 GLSL and 4 Tint
failures, tracked under the remaining shader/export bundle.

- **58/58 driver checks per mode**, zero errors and clean exit:
  [normal](results/storage-access-native-macos-arm64.json),
  [fallback](results/storage-access-fallback-macos-arm64.json).
  Four additions exercise RG32F/RG16F/RGBA32F/RGBA16F read/write storage across
  multiple dispatches, and an unused RGBA16F declaration eliminated by Tint.
  The driver now checks read/write support per physical format and recovers the
  storage format from SPIR-V when WGSL no longer contains the declaration.
  Legacy cache metadata is still accepted with a lazy source scan when needed;
  the cache format has not been changed by this fix.
- **FSR1: 30/30 per mode**, zero errors and clean exit:
  [normal](../../webgpu_tests/fsr1_integration/results/native-macos-arm64.json),
  [fallback](../../webgpu_tests/fsr1_integration/results/fallback-macos-arm64.json).
  Actual Forward+ SDR/HDR viewports, color changes and odd extents exercise
  RGBA16F intermediates plus the raster conversion path. A one-view XR override
  supplies a compatible RGBA16F storage target (no RCAS intermediate allocated)
  and an RGBA8 storage target (conversion required). Texture slice routing now
  honors the actual override. The old disabled shader variant produced an error
  and left a compute list open; the new path validates resources before opening it.
- **FSR2 smoke: 8/8 per mode**, zero errors and clean exit:
  [normal](../../webgpu_tests/fsr2_integration/results/native-macos-arm64.json),
  [fallback](../../webgpu_tests/fsr2_integration/results/fallback-macos-arm64.json).
  Four Forward+ SDR/HDR color/resize phases use internal dimensions above 64,
  exercising multiple SPD groups. FSR2 now uses real SSBO depth atomics and a
  separate final luminance dispatch, with numeric SNORM16-table conversion only
  when the backend cannot sample that format. This is not temporal-quality parity;
  motion, disocclusion, exposure and native-reference comparisons were still in progress at this checkpoint and are recorded in the later temporal follow-up.
- **FSR2 atomic callbacks: 144/144 per mode**:
  [normal](../../webgpu_tests/fsr2_atomic_depth/results/native-macos-arm64.json),
  [fallback](../../webgpu_tests/fsr2_atomic_depth/results/fallback-macos-arm64.json).
  These use the unchanged production callback header from the first frozen binary
  (`d1aee005456ccbeec67c0036247b5f898413382b4d675b7d7bfa86d66a958ab1`).
  They cover 4,096 contending writes, both depth directions, six alternating resets,
  differing maximum/render sizes and invalid coordinates that would alias valid
  flattened indices. [Negative controls](../../webgpu_tests/fsr2_atomic_depth/results/mutation-controls-macos-arm64.json)
  fail 24 checks when atomics become ordinary stores and 118 when bounds guards
  are removed. These are numerical failures, not compiler errors or timeouts.
- **Logical-copy lowering: 34 production-pass checks** under ASan/UBSan:
  [results](../../webgpu_tests/spirv_preprocess/results/logical-copy-macos-arm64.json).
  Seventeen valid aggregate cases fail the old opcode substitution; sixteen
  rejection guards and identical-type canonicalization pass. SPIRV-Tools validates
  preserved types/result IDs. Fourteen cases also pass Tint after explicitly
  test-only 1.3 interface normalization. Production version downgrades remain
  deferred to the reviewed Tint bundle because newer aggregate instructions have
  different semantics. Expansion is bounded and failure preserves the original
  module for an explicit unsupported-construct diagnostic.
- **Font atlases: 35/35 checks**, covering both Advanced and Fallback text servers:
  [results](../../webgpu_tests/font_atlas/results/native-macos-arm64.json).
  Tested on the second frozen binary
  (`9f42747715d04c53775e222ec469b32ac5a407b21c0f70ffbab143c96da228bb`);
  the font sources are unchanged in the final binary. Checks cover the first
  visible frame, concurrent producers, mipmaps, freeing a pending cache, replacing
  its extent and LA8/RGBA tint behavior. Immutable snapshots are keyed by texture
  object and drained outside the queue lock. Initial/restored-cache uploads also
  duplicate their image, preserving render-thread ownership. Emoji/SVG/LCD/MSDF
  and browser runs remain unverified.

### Font performance

[Three alternating pairs](../../webgpu_tests/font_atlas/results/benchmark-macos-arm64.json)
measure the Advanced text server, using four warmup and twelve measured batches of
94 glyphs with mipmaps and GPU mip readback. The baseline median was **39.136 ms**,
the candidate median **17.832 ms**; the paired median ratio was **0.4575** (pair
ratios 0.4317, 0.4575, 0.4678). This is a focused glyph-heavy native workload with
exclusive measurement runs, not AW3 startup/frame or Firefox performance. Keeping
LA8 CPU atlases preserves classification and avoids doubling their memory; the
coalesced upload already removes repeated conversion of the whole growing atlas.

### Rendering fixture readiness and limits

FSR1 and FSR2 smoke fixtures explicitly draw offscreen frames, wait on the actual
pipeline queue and require stable compilation counters before sampling. Occluded
native windows can otherwise stall `frame_post_draw`. Expected image values never
drive retries. Font mip validation copies a requested mip into a one-mip temporary
because shared-slice native readback ignored base mip/layer at this checkpoint;
the later readback fixture verifies its correction with 18 checks per mode.
Actual shader specialization now receives the same storage-lowering transformations
as ordinary shader creation, verified by 320 checks per mode; the earlier ordinary
variant-binding checks alone did not establish that contract.

Commands are in each fixture README. GPU test durations include startup/compilation
and are not performance claims. FSR2 adds a tail dispatch for correct inter-group
visibility, and FSR1 adds a copy only when the destination cannot receive its
RGBA16F storage output directly. End-to-end quality/performance acceptance remains
pending the feature and browser matrix.

## Luminance bounds and FSR2 temporal follow-up

The real Forward+ fixture now records 19 linear-float images and checks 90
properties per run: foreground motion, disocclusion, abrupt color changes, an
80× HDR luminance change, bright-to-dim exposure and an odd-size resize/reset.
Two runs each on native Metal, Dawn/Metal WebGPU and forced WebGPU fallback pass
all checks with zero engine errors and clean exit. Every repeated capture is
bit-exact on this host. [Fixture, commands and detailed limits](../../webgpu_tests/fsr2_temporal/README.md).

That comparison found a general luminance-reduction bug: the final 3×2 reduction
admitted 34 invocations because either coordinate could be in range, then divided
by six. Backend out-of-range read behavior changed the result. Requiring both
coordinates to be in range adds no dispatch, allocation or image copy.

- Bright-to-dim mean red: previous WebGPU **0.069619**, corrected **0.363246**,
  reference Metal **0.363013**; corrected forced fallback **0.363244**.
- Mean absolute RGB difference from Metal fell from **0.293394 to 0.000553**.
- The old binary fails the new analytic exposure oracle (89/90), without engine
  errors. The corrected frozen binary is SHA-256
  `8102c335e324ebf8c62512e26eb507a63ad63884c4eff1863962aa3cfc2aa09e`.
- The [production-shader fixture](../../webgpu_tests/luminance_reduction/README.md)
  passes **24/24** on all three backends, covering tiny/odd inputs, multiple
  workgroups, sampled/storage sources and adaptation. Restoring the old predicate
  causes 20 numerical failures; the four full-8×8 controls remain correct.

Saved compact [temporal results](../../webgpu_tests/fsr2_temporal/results/corrected-macos-arm64.json)
and [luminance results](../../webgpu_tests/luminance_reduction/results/macos-arm64.json)
include binary/source identities. Remaining HDR checker transitions have mean
RGB error 0.041 and 99th-percentile error 0.758 on values up to 4; moving edges can
also differ. These results establish bounded motion/history stability and the
specific exposure fix, **not** FSR2 quality parity. Timings from concurrent GPU
correctness runs are not performance measurements. Firefox/Windows/D3D12 and game-scene quality/performance remain unverified.
The later renderer follow-up records completed native DOF/MSAA coverage; current
GI evidence is tracked separately in STATUS.md.

## SPIR-V resource interfaces and vertex access

The adapted Tint bundle accepts SPIR-V 1.4/1.5 interface lists, handles phony
texture/atomic uses, and keeps the original module version. Vertex storage
pointer access is changed structurally in the shared Tint wrapper, including
helper signatures; validation still rejects actual vertex writes. The existing
matrix/vector atomic traversal needs no additional port.

A compiler-generated unsigned image copy exposed another real crash: Tint
assumed every nonzero image mask had a following operand. Matching integer
extension flags now lower safely; Lod/Sample remain, and unsupported semantics
fail with a diagnostic. A prior engine aborts with signal 6 on the new GPU test.

The production translator passes 52 checks spanning SPIR-V 1.0/1.3/1.4/1.5,
including actual OpVariable array initializers. Two additional valid SPIR-V
modules require clean rejection of unsupported sign-extension/volatile behavior.
The real GPU fixture passes 32/32 in each capability mode, checking atomic/matrix
buffers, logical copies, arrays, signed/unsigned narrow integer image reads and
writes, and mip-1 fetches with distinct mip-0 controls. Candidate SHA-256:
`d06206f6c8f66ecd6e8708d477c4ed07f2bb3227a835598c69122dfc7bf305ed`.
See [fixture and results](../../webgpu_tests/tint_translation/README.md).
This native Dawn/Metal evidence does not establish browser/D3D12 compatibility.

## Reduced-capability renderer and resource follow-up

Frozen native candidate `e6d26dd46c9871a75b75e62b5cac42dd2bbc7b0fe727a67414cf7a56bc4fdfa9`
provides the MSAA/DOF and Canvas results below on macOS/Apple M1 Ultra through
Dawn/Metal. Final sampled-contract and SSR checks use
`413b6443bc377c8bf83f06c2344b36f1c4525d3b6b16bf387c70f7ea1e54562d`. `--webgpu-force-fallbacks`
omits storage-format tiers and adapts read/write storage; the independent
`--webgpu-no-float32-filterable` flag omits that actual device feature. Their
combination tests a stricter capability profile without claiming a particular
browser's current feature set.

- [Sampled texture contracts](../../webgpu_tests/sampled_texture_filtering/README.md):
  **72/72 in four modes**, plus 12 CLI specialization/pruning proofs. Fetch-only
  float textures use an unfilterable layout only when original SPIR-V provenance
  establishes that contract across all stages and specialization branches.
  Reused bind groups adapt from original textures and samplers. Negative controls
  catch a wrong texture type, a blank exact fetch and lost linear filtering.
  All checks also pass on the final operand-role snapshot.
- [Literal/ID collisions](../../webgpu_tests/sampled_texture_literals/README.md):
  **12/12 in four modes**. Valid SPIR-V intentionally collides sampled-image
  ID 40 with FMax, composite-index, switch-case and debug-line literals. The old
  no-filter path silently returns zero in all four cases; actual operand roles
  preserve exact data without weakening unknown-use or future-filter guards.
- [MSAA and DOF](../../webgpu_tests/msaa_dof_integration/README.md):
  **153/153 in five modes**, covering hardware/resolved depth, focus, effective
  sample counts and resize. WebGPU images match Metal exactly in 24/27 captures;
  requested 2x uses Metal 2x versus WebGPU 4x, with maximum mean error 0.000265.
- [Canvas SDF](../../webgpu_tests/canvas_sdf_integration/README.md):
  **36/36 in five modes**. The no-normalized16/no-float-filter combination uses
  RGBA16F for filterable distance data; other devices keep the narrower format.
  No extra pass is added. Largest distance mean error is 0.000153; selected
  nonambiguous normals match the native reference.
- [TAA](../../webgpu_tests/taa_integration/README.md): dedicated RG16F history copy
  format and internal-size dispatch fix the full renderer at 1.0/0.5/1.5/odd1.25
  scales. Earlier frozen-binary runs pass 16/16 per reference/native/fallback mode.
- [Readback](../../webgpu_tests/texture_readback/README.md): all requested mips,
  layers and 3D planes are now copied and converted with block-aware pitch;
  18/18 checks pass in both native capability modes. The older binary fails all
  18 checks.
- [Shader specialization](../../webgpu_tests/shader_specialization/README.md):
  capability-aware storage lowering applies to both base and specialized WGSL.
  Earlier runs pass 320 numerical checks per capability mode and 40 CLI shape
  assertions; graphics tests reject unsupported read/write emulation explicitly
  instead of relying on compute-only snapshots.

- [SSR](../../webgpu_tests/ssr_integration/README.md): **20/20 runs**, all **300 scene
  checks and 80 Metal-reference comparisons** pass across half/full resolution,
  odd dimensions and MSAA off/4x. Normal and omitted-filtering reflection energies
  match Metal exactly; storage and combined fallbacks range from 0.998625 to
  1.001855 of reference energy. Earlier no-filter runs retained only 0.7–27%.
  Intermediate GPU probes isolated all-zero HiZ mip levels after a correct base
  level, caused by a literal instruction number being treated as a resource ID.
  Grammar-defined operands fix the general contract; exact nearest/clamp mip-field
  fetches preserve full-size composition. Reflection-color filtering remains.

These are correctness runs, some concurrent, so their durations are not frame
performance measurements. Native SSR and sampled contracts are complete in this
scope. Browser/backend coverage and end-to-end performance remain outstanding.

## Exported shader caches and metadata

The native macOS WebGPU editor with SHA-256
`413b6443bc377c8bf83f06c2344b36f1c4525d3b6b16bf387c70f7ea1e54562d`
and translator/profile
`d375989c9e230ac4456d94d3da5b10bb7471c941585ac53e69f20695e1cd7aa0`
passes the [export/cache fixtures](../../webgpu_tests/shader_baker/README.md):

- Sidecar export translates **1,095/1,095** source modules without failure, covers
  11 named material routes, reloads all records and renders the expected pixels.
- Every metadata record matches production pre-specialization analysis, including
  **26 anisotropic sampler alias changes**. The prior raw-source metadata would
  retain removed sampler bindings. The serializer participates in content identity,
  so old metadata cannot retain a matching WGSC fingerprint.
- WGSC v4 identity, corruption and precedence matrix: **11/11**. Stale/legacy
  identities are rejected; a corrupt later record prevents partial acceptance.
- Existing shader-placeholder fallback matrix: **14/14**, including repeated later
  container failure and malformed inner counts. Private staging completes before
  RID adoption, preserving destination ownership when fallback is needed.
- Four worker-owned local RenderingDevices verify **160/160 GPU values** while
  the main renderer advances 421 frames. Shared cache maps, counters and persistence
  are synchronized; SPIR-V analysis, Tint and GPU work stay outside the cache lock.
  This is concurrency stress evidence, not a ThreadSanitizer proof or a benchmark.

The compact shader container remains version 1 with SMOL-V, GDSC remains version 4,
and WGSC v4 retains analysis wire version 1. Missing image format/scalar metadata
is recovered from source SPIR-V where required. Shader creation remains deferred.
Native baking requires the active WebGPU driver; regeneration from a Vulkan/Metal
editor and equivalent coverage on browser adapters remain future work. Browser
tests use the separate candidate harness; these results do not validate D3D12.

## SDFGI atlases, atomics and retained-voxel scrolling

The [production-kernel and full-scene fixtures](../../webgpu_tests/sdfgi_integration/README.txt)
validate the Godot 4.7 port with native Dawn/Metal executable SHA-256
`59ecacbe71a4a99e4645d992a263c5e6bf13f3b10ea330548e98702cacf23c54`.
All nine scenes pass: 1/4/8 cascades on normal WebGPU, combined storage fallbacks
plus omitted float32 filtering, and native Metal. The two WebGPU feature profiles
produce identical initial and scrolled captures. All three strict Metal-reference
comparisons pass; at four cascades mean RGB error is 0.0902/255 initially and
0.0627/255 after scrolling, maximum channel error 3 and p95=1. Bounce-energy error
is 0.086%. The native Metal path retains its descriptor arrays and packed formats.

The first scroll comparison failed despite nonzero bounce. Main-renderer GPU
readback found 16,912 occupied cells versus Metal's 11,055, while the cleared
facing buffer still contained exactly 11,055. The fallback texture clear had
cleared only z=0 and used queue writes unordered relative to recorded dispatches.
Encoded, padded copies now cover all depth slices and selected mip/layer ranges.
The focused clear matrix passes **153/153** on normal WebGPU, storage fallback
and Metal, including signed/packed formats, SRGB alpha, untouched mip/layer
slices, >4 MiB volumes and clear/read/clear/read ordering in one submission.
The old implementation fails **113/153**, and its scrolled scene mean RGB error
was 9.6165/255. Temporary renderer readback instrumentation was removed.

A lazy immutable 4 MiB zero buffer avoids per-clear 8 MiB CPU uploads; nonzero
upload chunks are bounded by 4 MiB and the actual device buffer limit. Four/eight
cascade atlas slots consume 160/320 MiB before occlusion, probes and scratch
buffers. The fixture records logical allocation counters and rejects wrapped
startup counters; these do not measure physical residency. Performance
results below are bounded native evidence; Firefox/Windows/D3D12 verification remains pending.

## Final web builds and browser lifetime regression

The native candidate `/private/tmp/aw3-webgpu-ordered-clear` has SHA-256
`59ecacbe71a4a99e4645d992a263c5e6bf13f3b10ea330548e98702cacf23c54`.
Its matching CLI and both full web templates use translator/profile identity
`8b6f9216c8a1afd8144b4378d7efd917d0ac6dbec844391027b5e5ece3b46a10`.
Emscripten 4.0.20 builds pass for `target=template_debug webgpu=yes opengl3=no
module_mono_enabled=no module_text_server_fb_enabled=yes dlink_enabled=no`:

| Mode | Flags | Template SHA-256 |
| --- | --- | --- |
| Threaded Worker | `threads=yes proxy_to_pthread=yes` | `47faa306eb541236ff508b2c147b369d4cd1ab31f397eb614fcc628073e183d7` |
| Non-threaded | `threads=no proxy_to_pthread=no` | `6aacb51f295494c9d5f619ef4fd33283022b62da55f379b505b9c4ea7202b05b` |

The non-threaded build exposed pre-existing render-Worker methods compiled without
`THREADS_ENABLED`. All corresponding declarations, definitions and call sites now
require it. CI's WebGL-only jobs also exposed WebGPU-specific overrides outside
`WEBGPU_ENABLED` and a shared window-size notification field inside it. The field
is now shared and the overrides are conditional. The affected display-server,
Web main and OS objects compile with `webgpu=no opengl3=yes threads=no`.
WebGPU jobs in both CI workflows install the strict baker's native dependencies.

The rebind cache now owns each target layout used as a pointer key. This matters
in Emscripten, where a bind group retains its JavaScript layout object but does not
keep that layout's C wrapper address alive. The old threaded `413b64` template
reproduces incompatible-layout errors in stock macOS Chrome (warm load) and
Firefox (cold load) while repeatedly retiring target shaders with the source
uniform set alive and float32 filtering omitted. The corrected native candidate
passes all 64 GPU output cells. Final browser evidence belongs to the browser
fixture's saved results; native success alone is not browser validation.

The CI smoke controller also now rejects an explicit engine FAIL, WebGPU
validation, script errors, console errors and page errors. One mocked success
control exits zero; all five mocked failure controls exit nonzero. These are
controller checks, not GPU coverage. Full repository static hooks pass on the
integration commit, and CI confirms that result.

### SDFGI performance controls and costs

[Raw samples](../../webgpu_tests/sdfgi_integration/results/performance.json) use
three alternating old/current pairs with 240 timed frames, after all other agent
GPU and compiler activity stopped. Every timing region has stable pipeline counts
and drains GPU work. The 128×128 scene includes per-frame handoff and viewport
timestamp instrumentation; these figures are not full-game or browser FPS.

| Current WebGPU configuration | GI disabled, median ms/frame | GI enabled, median ms/frame |
| --- | ---: | ---: |
| 1 cascade | 0.6603 | 0.7567 |
| 4 cascades | 0.6662 | 1.0791 |
| 8 cascades | 0.6684 | 1.7750 |
| 4, combined missing features | 0.6528 | 1.4776 |

The combined-feature four-cascade path costs about 37% more than optional-feature
WebGPU here. The old WebGPU renderer had no working GI-on baseline. Existing
GI-disabled controls have median paired candidate/baseline ratios **0.983** for
WebGPU and **1.006** for Metal, consistent with unchanged cost in this small scene.

Native Metal GI-on performance is **inconclusive**. After the short samples were
bimodal, [three longer 2,400-frame pairs](../../webgpu_tests/sdfgi_integration/results/performance-metal-long.json)
still ranged from **0.657–1.265 ms old** and **0.624–1.345 ms new**. Both binaries
exhibit both timing modes, so these measurements establish neither performance
parity nor a regression. Separately, the final native Metal initial and scrolled
PNG captures are exactly identical to the pre-port binary. Target-browser and
Windows/D3D12 timings remain unverified.
