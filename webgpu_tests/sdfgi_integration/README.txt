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
  feature; all 32 checks pass. Full scenes with 1/4/8 cascades are pixel-identical
  between normal and combined fallback/no-float32-filterable modes. Initial
  WebGPU/native Metal four-cascade images have 0.09845/255 mean RGB error.
  However, the current incremental-scroll comparison fails at 9.6165/255: the
  near-cascade emissive voxel disappears after camera movement. A full GI rebuild
  at the moved camera restores the image. This is an open integration defect;
  the nonzero-bounce scene PASS alone must not be treated as full validation.

See design.txt for allocation, binding, capability and native-backend contracts.
