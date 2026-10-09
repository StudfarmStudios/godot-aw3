SDFGI production-contract regression fixtures

Run from the repository root with a native editor built with webgpu=yes. The
Python runners expand the production GLSL sources; they do not keep copies of
the kernel implementation. glslang and spirv-val must be available on PATH.

  python3 webgpu_tests/sdfgi_integration/compile_shaders.py --output /tmp/sdfgi-corpus --tint bin/tint_convert_cli
  python3 webgpu_tests/sdfgi_integration/run_atlas.py ENGINE --output /tmp/sdfgi-atlas
  python3 webgpu_tests/sdfgi_integration/run_facing.py ENGINE --output /tmp/sdfgi-facing
  python3 webgpu_tests/sdfgi_integration/run_occlusion.py ENGINE --output /tmp/sdfgi-occlusion
  python3 webgpu_tests/sdfgi_integration/run_scroll.py ENGINE --output /tmp/sdfgi-scroll
  python3 webgpu_tests/sdfgi_integration/run_voxel_scroll.py ENGINE --output /tmp/sdfgi-voxel-scroll
  python3 webgpu_tests/sdfgi_integration/run_texture_clear.py ENGINE --output /tmp/sdfgi-clear
  python3 webgpu_tests/sdfgi_integration/run_scene.py ENGINE --output /tmp/sdfgi-scene --cascades 4
  python3 webgpu_tests/sdfgi_integration/run_depth_read.py ENGINE --output /tmp/sdfgi-depth
  python3 webgpu_tests/sdfgi_integration/run_normal_lut.py ENGINE --output /tmp/sdfgi-normal-lut

Repeat GPU runners with --fallback to exercise the driver's storage-texture
fallback (tier1/tier2 formats and read/write storage feature disabled in the
recorded focused results; float32-filterable was still supported). The scene runner must use a binary containing the SDFGI allocation,
variant-enabling and limit-reporting changes; compiling a shader from current
source alone does not validate those CPU renderer contracts.

Focused GPU fixtures
  atlas: All cascade counts 1 through 8. Fill actual RGBA16F/RGBA8 atlases
    with per-cascade gradients, test production sampling at 10 interior/edge/
    outside positions per cascade, and run the production per-tile clear pass.
    Clearing one tile must preserve every other tile. 32 checks per mode.
  facing: Extract the exact production fragment atomic block into a compute
    wrapper, issue 4096 competing writers per voxel, alternate all/even facing
    masks across six clears, and inject out-of-bounds coordinates that could
    otherwise alias a valid flattened index. 12 checks per mode. This isolates
    atomic correctness; the scene separately exercises actual fragment raster.
  occlusion: Run the unmodified production propagation kernel for eight octants
    and six empty/solid/wall/sparse/parity cases (196608 values). Compare with an
    independent scalar wavefront implementation within 1/255, including guard
    words. This validates intradispatch reads, not a pre-dispatch image snapshot.
  scroll: Run production packed-buffer scrolling for four signed offsets and
    both source cascade slices, checking all eight channels bit-exactly, untouched
    regions and guards. Eight checks per mode.
  voxel_scroll: Production retained-cell decoding and JFA read after storage
    writes. Covers packed neighbor bits, CPU/GPU-produced dispatch counts, direct
    and indirect dispatch, and post-dispatch count reset. 40 checks per mode.
  scene: Compare a dark room with GI disabled against indirect light from an
    emissive cube with GI enabled, then move the camera far enough to scroll
    cascades and compare against a matching disabled capture. Screenshots and
    strict engine/shader/validation error checks accompany the numerical test.
    Captures wait for pending pipeline count zero and ten unchanged compilation
    count frames; timeout fails explicitly. compare_scenes.py (Pillow) checks
    initial and scrolled image RGB mean error <=1/255 and bounce-energy difference <=5%.
    This catches a silently dark fallback even when the nonzero-bounce test passes.

Negative control
  python3 webgpu_tests/sdfgi_integration/run_facing.py ENGINE --output /tmp/sdfgi-facing-control --non-atomic-control

  The runner replaces atomicOr with load/OR/store only in the generated fixture.
  A successful negative-control report means that numerical checks rejected that
  broken kernel. Current hardware rejected all 12 checks with no engine errors.

Native texture comparison
  python3 webgpu_tests/sdfgi_integration/run_occlusion.py ENGINE --output /tmp/sdfgi-metal --texture-reference
  python3 webgpu_tests/sdfgi_integration/compare_occlusion.py /tmp/sdfgi-occlusion /tmp/sdfgi-metal --output /tmp/sdfgi-occlusion-comparison.json

  This runs the original R8 storage-image kernel through the native Metal driver
  on the same GPU. It does not claim bit-identical cross-backend quantization.
  Empty and solid cases match exactly. Of 32768 values per case, walls differ at
  419 by at most 1/255; sparse geometry differs at 3231 by at most 3/255. Applying
  the original final 4-bit truncation changes 12 wall and 163 sparse values by
  one step. The new final RGBA8 texture retains 8-bit precision rather than the
  original RGBA4 view. An explicit nearest-even quantizer was evaluated and
  worsened agreement, so production retains GLSL packUnorm4x8.

Hardware-depth regression
  The full scene exposed an additional missing explicit depth declaration in
  gi.glsl: ordinary texture2D bound the driver's zero Float fallback instead of
  hardware depth, reconstructing positions outside every cascade. The shader now
  uses AW3's godot_depth_source marker. The corpus explicitly checks that both
  SDFGI and combined variants produce texture_depth_2d at remapped binding 24.
  The depth_read fixture extracts the actual production declaration and fetch
  expression, clears a D32 attachment to 0.75 then 0.25, and reads both exactly
  through the compute shader. --untyped-control reproduces zero for both values.

Best-fit-normal LUT regression
  Baseline WebGPU promotes the renderer's R8 storage LUT to R32F. Its original
  nearest texture() lookup still requested a filtered binding, substituting a
  blank texture without float32-filterable and corrupting normal encoding.
  The production shader now computes clamp(floor(uv*size),0,size-1) and fetches
  mip 0 explicitly, preserving nearest/clamp behavior and existing allocations.
  It also makes the zero lookup coordinate for axis-aligned normals finite.
  run_normal_lut.py extracts the actual production fetch and tests 81 interior,
  boundary and outside coordinates with actual R32F data. Normal mode also
  checks the original nearest GPU lookup (162 checks total); baseline flags
  --fallback --no-float32-filterable pass 81. Adding --legacy-control deliberately
  restores the old lookup and succeeds only if all 81 comparisons reject it.
  The full renderer separately compares normal and baseline-feature images.

Benchmarking
  Coordinate exclusive GPU use before adding --benchmark-frames=120 to the scene
  runner. It disables VSync, drains prior work, samples steady frames after
  pipeline settling, then drains GPU work again. Reports separate elapsed wall
  time and viewport CPU/GPU timing samples; unavailable GPU samples stay empty.
  Scene metrics also retain engine-reported allocation counters. Startup texture
  accounting can wrap; those values are null with the invalid raw value retained,
  not interpreted as meaningful memory deltas. WebGPU video_bytes=0 is an
  unavailable backend counter, not zero device memory consumption.

Recorded results
  results/ stores JSON reports with exact binary/source hashes and commands.
  The focused fixtures pass in normal and forced-fallback modes on native
  Dawn/Metal (macOS 26.5.2, Apple GPU). CPU corpus: 46 SPIR-V validations and
  23 WebGPU Tint translations. These are correctness runs, not performance
  measurements, and do not establish Firefox/Windows/D3D12 runtime support.
  The baseline atlas run additionally omits the actual float32-filterable device
  feature; all 32 checks pass. On native executable SHA-256
  59ecacbe71a4a99e4645d992a263c5e6bf13f3b10ea330548e98702cacf23c54,
  all nine full scenes (1/4/8 cascades, normal WebGPU, combined missing features,
  native Metal) pass. Each combined-feature initial/scrolled image is pixel-
  identical to normal WebGPU. Native-reference strict comparisons pass for all
  three cascade counts; four-cascade mean RGB errors are 0.0902/255 initially
  and 0.0627/255 after scrolling, with maximum channel error 3 and p95=1.
  Bounce-energy error is 0.086%. These bound fidelity in this fixture, not all
  scenes or hardware. Controlled native timings are recorded below.

Ordered full-depth texture clears
  The scene's first incremental-scroll comparison exposed stale 3D scratch
  textures. The driver cleared only z=0, leaving false occluders in later slices;
  queue.writeTexture also could not preserve clears between encoded dispatches.
  Clear commands now encode padded buffer-to-texture copies covering every depth
  slice and selected mip/layer. A lazy, immutable 4 MiB zero buffer avoids a new
  8 MiB CPU upload for every scratch clear. Nonzero uploads and copy chunks are
  bounded by 4 MiB and the actual device buffer limit. Command encoding retains
  each nonzero buffer until use; the code releases rather than prematurely
  destroys it. Physical-format conversion covers signed, packed, SRGB and BGRA
  values, including linear-to-SRGB conversion with alpha unchanged.
  run_texture_clear.py checks 36 formats, fully initialized volume clears,
  nonzero mip/layer slice preservation, repeated clear/read dispatches in one
  submit, and multi-chunk volumes. 153/153 checks pass on normal WebGPU, forced
  storage fallback and native Metal. The old driver fails 113/153. This closes
  the scene's persistent scroll defect rather than masking it with a full rebake.

Controlled performance measurements
  run_performance.py BASELINE CANDIDATE --output DIR --rounds 3 --frames 240
  automates alternating process order for preservation controls, then measures
  the current feature costs. The old binary is SHA 46dc9ae5ce79... and candidate
  SHA 59ecacbe71a4...; full identities and every raw sample are in
  results/performance.json. All other agent GPU/compiler work was stopped.
  Timed regions contain no pipeline compilations, drain queued GPU work, and
  include per-frame handoff and the same viewport timestamp instrumentation.
  This 128x128 synthetic scene is not full-game or browser FPS evidence.

  Median wall milliseconds/frame across three samples:
    Current WebGPU, 1 cascade:  GI off 0.6603 / on 0.7567
    Current WebGPU, 4 cascades: GI off 0.6662 / on 1.0791
    Current WebGPU, 8 cascades: GI off 0.6684 / on 1.7750
    Current baseline features, 4: off 0.6528 / on 1.4776
  The 4-cascade baseline-feature path costs about 37% more than optional-feature
  WebGPU in this scene; read/write storage snapshots remain a portability cost.
  There was no working old WebGPU SDFGI path to use as a feature-on baseline.

  Existing GI-disabled controls: median paired new/old ratios are 0.983 for
  WebGPU and 1.006 for native Metal, consistent with unchanged small-scene cost.
  Native Metal GI-on performance is INCONCLUSIVE. The initial 240-frame samples
  were bimodal; three longer 2400-frame alternating pairs remained bimodal:
  old 0.657–1.265ms, new 0.624–1.345ms. Both binaries exhibit both timing modes,
  so these runs establish neither a regression nor performance parity. Raw
  long samples are in results/performance-metal-long.json. The independently
  checked initial/scrolled native Metal images remain exactly identical to the
  pre-port binary. Browser/D3D12 performance still requires target-hardware runs.

Allocation counters
  Engine-reported logical texture/buffer bytes with GI enabled are:
    1 cascade: 139998428 / 38195612
    4 cascades: 391740772 / 65920844
    8 cascades: 727397252 / 102887820
    Native Metal, 4 cascades: 319942912 / 40755020
  The driver-owned zero buffer adds a lazy 4 MiB outside these resource counters.
  Counters describe this scene's logical allocations, not physical GPU residency.


Renderer contracts (Godot 4.7)

Formats
  WebGPU cannot reinterpret R32_UINT as RGB9E5 or R16_UINT as RGBA4. Store light
  and octahedral probes as decoded RGBA16F; store final occlusion as RGBA8_UNORM.
  SDF and two-channel anisotropy also use RGBA8 on WebGPU: R8/RG8 storage
  otherwise promotes to unfilterable float32 textures on devices without tier1.
  RGBA8 storage plus linear sampling needs no optional float32-filterable feature.
  Shader write declarations and C++ allocations select the same backend branch.
  Preserve the packed/reinterpreted path on other existing 4.7 backends.
  Keep direct-light output images write-only to avoid unnecessary snapshots.

Geometry facing
  WebGPU uses one uint storage buffer, indexed (z * grid_size + y) * grid_size + x.
  Fragment voxelization uses atomicOr, with explicit 3D bounds checks. The scroll,
  occlusion and solid-cell store passes consume that same buffer. Clear it at the
  same cascade boundary as the original geometry-facing texture; no conversion
  pass or duplicate 3D texture is needed. Other backends retain their existing
  image-atomic or NO_IMAGE_ATOMICS path.

Intermediate occlusion
  The original eight read/write R8 storage images are not portable binding arrays.
  More seriously, occlusion propagation reads values written during the same
  dispatch, so read/write texture snapshots are not equivalent.
  WebGPU instead packs four UNORM8 values per uint in one buffer covering all eight
  volumes: index = cascade_octant * grid_size^3 + voxel_index, byte = index % 4.
  This uses 16 MiB at 128^3, the original eight R8 images' payload size. In-dispatch
  propagation uses packed shared memory (4 KiB values +4 KiB geometry facing),
  workgroup barriers and atomic masked byte updates. The final workgroup flush
  writes each packed word once. Scroll uses atomic masked byte updates; store reads
  plain packed words after the preceding dispatch has completed. Values remain
  UNORM8 at each store; native R8 image quantization is not bit-identical to packUnorm4x8.
  Actual same-GPU comparison is recorded in results/occlusion-gpu-comparison.json.

Sampled cascades
  WebGPU packs each of four sampled fields into one 3D atlas. Godot 4.7 accepts
  every cascade count from 1 through 8. One uses a 1x1x1 grid, two use 2x1x1,
  three/four use 2x2x1, and five through eight use 2x2x2. Each tile is 128 cubed.
  Three, five, six and seven cascades have respectively 1, 3, 2 and 1 unused
  tile slots (33%, 60%, 33% and 14% payload overhead). Native drivers
  retain descriptor arrays and packed texture formats. The four WebGPU atlas
  fields total 40 MiB per occupied or padding tile (RGBA8 + RGBA16F + two RGBA8
  fields), versus 22 MiB per native cascade. Four/eight slots use 160/320 MiB
  before probes, final occlusion and scratch buffers. This is a portability cost;
  it is still smaller than R8/RG8-to-float32 promotion on baseline WebGPU.
  Bindings 100, 110, 130 and 140 match CPU uniform creation on both paths.
  Sampling clamps each local coordinate to [0.5,127.5] texels before adding its
  tile offset, preserving the original clamp-to-edge filter at every boundary.
  Stores add the same tile offset. A dedicated clear pass clears only the selected
  cascade's light/aniso tiles; clearing an entire aliased RID would lose neighbors.
  The actual WGSL sampled counts are 5 for integrate, 4 for debug, 6 for SDFGI resolve,
  and 8 for combined resolve. Read/write-image fallback snapshots remain within 16.
  Keep typed integer defaults for gi.glsl's utexture2D voxel-GI input. Its actual
  hardware-depth input uses AW3's explicit godot_depth_source marker, preventing
  substitution of a zero float texture during position reconstruction.

Limits and fallback
  Do not silently reduce requested cascades. Gate before allocations and variant
  enabling on sampled textures 16, storage buffers 8, storage images 8, shared memory
  8 KiB, supported 64-invocation shapes, and actual 3D texture dimension. Eight
  cascades require final occlusion depth 1024; four require 512. Browser main/worker
  setup now requests adapter.maxTextureDimension3D. Native Dawn already requests
  the complete adapter limit structure. A device below the needed dimension gets
  a clear warning and retains ordinary scene lighting. No user cascade clamping.
  Optimized jump-flood workgroups use 4x4x4 on WebGPU (rather than 8x8x8, above the
  minimum 256-invocation limit), with the matching CPU algorithm threshold.

Compatibility
  Preserve AW3's lightmap UBO budget, NO_SUBGROUPS clustering implementation,
  explicit hardware-depth typing, deferred pipeline creation and 4.7 interfaces.
  WebGPU voxelization variants have their own deferred shader group, so enabling
  lightmaps does not compile them. A group can be enabled after versions exist;
  set_variant_enabled cannot be used as a runtime feature toggle.
  The accompanying shader-baking implementation requires an editor running the
  WebGPU driver, ensuring baked capability-dependent defines match this path.
  Cross-driver export is explicitly rejected until target-source regeneration is
  implemented. No 4.8-only define-refresh APIs are imported.
