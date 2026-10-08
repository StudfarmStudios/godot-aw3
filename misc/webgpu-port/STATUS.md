# WebGPU compatibility and feature ports

Implement the applicable fixes from the 2026-10-08 AW3 comparison of
Shane-Gadsby/godotwebgpu. Keep the engine on **Godot 4.7.1**; upgrading to 4.8 is
explicitly deferred until a stable release. This file tracks the full scope,
including unfinished work, across implementation batches.

Performance is an acceptance criterion: keep existing performance or improve it,
allowing measured small costs for meaningful fidelity improvements. Avoid
unnecessary texture copies, pass restarts, eager work, and hot-loop overhead.

Reference report: [AW3 comparison](https://github.com/StudfarmStudios/aw3/blob/3efbae88867bda7db50ce321840cf61a31a64c3c/docs/gameclient/webgpu-fork-comparison-2026-10-08.md).
Source fork: `470f89e78eece1c7a73285345e2ca39b8f8706ad`.
Starting AW3 engine: `c0d51825faad2c1a773f4e21c34e74b60c53da21`.

## Implementation and verification status

| Report findings | Work | Status / evidence |
| --- | --- | --- |
| 1–3, 7–8 | Capability-aware packed/narrow storage formats, matching WGSL and views, complete upload/readback conversions | Implemented; ASan/UBSan production helper tests pass. 25 native GPU checks pass in each capability mode; browser runtime pending |
| 4 | Bind uniform sets against the requested shader, preserving lazy layout initialization | Implemented; native GPU variant and push-constant checks pass. Browser target-layout retirement regression reproduces on the old template and passes all 64 cells per corrected threaded run; all eight corrected nonthreaded runs also pass clean shutdown |
| 5–6 | GPU-written shadow refresh, variant adaptation, first-use ordering and mip/layer correctness | Implemented at dispatch, one restart for all active sets; no CPU shadow replay. Native 2D/array/3D/slice checks pass; browser runtime pending |
| 9–10 | Effective MSAA count and format-converting resolve | Implemented; requested 2/4/8, native/promoted RG16F resolve and nonzero destination mip/layer pass in both native modes. 153 renderer checks pass on Metal and four WebGPU capability modes, including combined missing features; browser pending |
| 11 | Block-aligned compressed texture copies; preserve array stride fix | Implemented; native compressed array/mip-tail GPU copy and readback checks pass; browser runtime pending |
| 12 | Partial color/stencil clears; preserve depth-region clears and batched submissions | Implemented; mixed HDR/float/integer targets, sparse masks, depth/stencil probes, MSAA and ring exhaustion pass natively. Browser pending |
| 14–16 | SDFGI formats, cascade bindings, typed defaults and correct atomic fallback | Implemented on 4.7 with four cascade atlases and real buffer atomics. All nine 1/4/8-cascade native scenes pass; normal and combined missing-feature images are identical, and strict Metal-reference comparisons pass before/after scrolling. Fixed the revealed full-depth/ordered texture-clear bug; 153 clear checks pass per native profile. Stable GI-off controls and feature costs measured; native GI-on performance inconclusive due bimodal timings. Browser verification pending; see SDFGI fixture README |
| 17 | FSR2 capability variants and atomic-buffer fallbacks without last-writer-wins depth reduction | Implemented; 144 atomic-callback checks and 8 Forward+ smoke checks per native capability mode. 90 temporal/quality probes per run across Metal and both WebGPU modes, two runs each; deterministic captures. Exposure regression fixed; edge/HDR differences remain, no full quality-parity claim |
| 18–19 | FSR1 destination fallback and Canvas SDF format fallback | Implemented; 30 FSR1 renderer checks per native mode cover SDR/HDR, resize and direct/conversion XR targets. Canvas SDF passes 36 numerical/visual checks in five native capability modes, including no float32 filtering, plus threaded/nonthreaded Chrome/Firefox cold/warm visual checks. FSR1 coverage remains native |
| 20–22, 24 | Logical-copy lowering, reviewed SPIR-V normalization/Tint fixes, structural vertex-access transform | Implemented: 34 preprocessor sanitizer/validator checks; 52 translation checks across SPIR-V 1.0/1.3/1.4/1.5; two clean semantic rejection guards; 32 numerical GPU checks per native mode. Retain existing initialized-array, matrix traversal and depth behavior; reject blanket operand stripping and generic subgroup emulation. Browser pending |
| 27–31 | Export baking, target capabilities, coverage, subprocess conversion, combined cache metadata and cache preference | Implemented: native WebGPU editor baker, material traversal, transactional live-placeholder replacement, packaged-cache preference, isolated batch conversion, explicit target profile and WGSC v4 source identity. Export sidecar and runtime metadata match 1,095/1,095, including 26 anisotropic alias changes; cache matrix 11/11; placeholder matrix 14/14; concurrent cache stress 160/160. Threaded/nonthreaded Chrome/Firefox cold/warm packaged-seed, identity, persistence and disk-cache correctness checks pass. Cross-driver source regeneration and browser startup performance remain unverified |
| 35–36 | Atlas upload coalescing and glyph classification, retaining immutable render-thread snapshots | WebGPU upload coalescing implemented; 35 checks across Advanced/Fallback text servers, including immutable snapshots, mipmaps, replacement/freeing and LA8/RGBA tint. Keep LA8 CPU atlas and current classification; direct RGBA would double memory without a demonstrated additional benefit. Additional 53/53 checks pass with both text servers, covering actual bitmap emoji, authored SVG glyphs, LCD and MSDF. Threaded/nonthreaded Chrome/Firefox cold/warm mask/LCD/MSDF, SVG tint and added-glyph pixel checks pass |
| 37–38 | CPU gradient regeneration and compressed-texture readback | Gradients implemented/tested. Finding 38 correction: disk-backed `CompressedTexture2D::get_image()` is already identical in our base; no additional port needed |
| 45–49 | Feature fixtures, actual-driver regressions, browser/backend metadata, CI integration | Production C++ helpers, GPU regressions and browser fixtures added. All 16 corrected macOS Chrome/Firefox runs pass threaded/nonthreaded, normal/omitted-filtering and cold/warm checks, with clean shutdown and two nonzero-exit probes. Integrated platform/build checks are tracked on [PR #31](https://github.com/StudfarmStudios/godot-aw3/pull/31/checks); Windows/D3D12 unverified |
| 61 | SSR storage format and hardware/resolved depth contract | Implemented; all 278 build-time modules compile/translate. 20 native renderer runs pass 300 checks and 80 strict Metal-reference comparisons across half/full resolution, odd dimensions, MSAA and four WebGPU capability profiles; no-float-filter HiZ/literal-ID and nearest mip-field contracts corrected. Threaded/nonthreaded Chrome/Firefox reflection checks pass both device-feature modes, cold and warm |
| 58 | Headless export teardown lifetime | Implemented on 4.7. Baseline import reproduces null-singleton error/crash; fixed import plus three Web pack exports pass with clean shutdown |

## Constraints and preserved behavior

- Findings 13 and 23: do not import unnecessary compute-pass splitting or generic
  single-lane subgroup emulation. Use the WebGPU usage rules and preserve the
  existing source-level `NO_SUBGROUPS` cluster algorithm.
- Findings 25–26, 32–34, 39–44: preserve explicit depth typing, stencil guards,
  deferred/async shader compilation, compact caches, Worker/render-thread and C#
  integration, native Dawn, upload/draw optimizations, and lightmap fixes.
- Findings 50–51 describe shared limits, not fixes supplied by the other fork.
  Do not silently claim that these ports solve synchronous browser readback,
  device-loss recovery, general binding arrays, multiview or VRS.
- Findings 52–57: 4.8-only interface/build/migration work is deferred. Equivalent
  correctness requirements for new 4.7 features still apply.
- Findings 59–60: Box3D and unrelated editor preferences are outside the rendering
  fix scope. Do not change the project's physics backend.

## Verification requirements

Test production C++ helpers and shader translation where possible rather than
relying solely on the JavaScript driver models. Build the native Dawn and web
paths, run resource/binding regressions, and exercise Forward+ features against a
reference renderer. Preserve the AW3-specific regressions called out above.
Record unavailable browser/hardware coverage explicitly; a macOS Dawn run is not
Firefox/Windows/D3D12 verification. Completion requires the full applicable scope
and evidence for its runtime contracts, not just successful compilation.

## Setup

Created an isolated worktree from the current `origin/aw-web-export`. Ran `rsync`
with the main checkout's LFS file list as instructed; this engine checkout has no
tracked LFS files. The main engine checkout remains untouched.

## Initial batch validation (historical)

The earlier shader-baker failures below are resolved: the current strict bake
converts **278/278 modules**, with zero GLSL/Tint failures. Earlier outstanding
readback, specialization, cache, Canvas and glyph coverage is superseded by the
status table and each fixture's saved results. Windows/D3D12 and end-to-end
browser performance validation remain open.

See [VALIDATION.md](VALIDATION.md) for commands, measured performance and limits.
Production CPU helpers pass ASan/UBSan; 25 actual GPU checks pass in each of the
normal and forced-fallback native Dawn/Metal modes (50 total), with zero
validation errors and clean shutdown. Headless gradient checks and the existing
327 JavaScript driver-model checks pass. Native editor linking and the full threaded WebGPU template build passed;
browser execution and the non-threaded template remain pending. That initial build reported 10 GLSL and 4 Tint failures; the current strict
bake resolves all of them (278/278 modules).

Additional issues found by the new fixture were fixed in this batch:

- 3D transfer origins now use the depth offset rather than the array-layer field.
- Compressed readback retains RenderingDevice's block-aware staging row pitch.
- Push-constant ring offsets survive snapshot pass restarts without a new bind.
- Native Dawn pipeline completion uses the event pump to avoid a device-mutex
  deadlock during shutdown. Compilation stays asynchronous; browser callback
  delivery is unchanged. The fixture requires clean process exit.

No Firefox/Windows/D3D12 runtime result or end-to-end performance comparison is
available yet. The current table and final validation sections supersede this historical batch. Backend and performance coverage limits remain explicit.

### Additional validation findings

Native GPU timestamp capture now uses standard pass timestamp writes. Standalone
Dawn `WriteTimestamp` required an unsafe toggle; empty compute passes then returned
zero on this Metal host. A cached 1×1 attachment-clear pass produces real values.
Native map callbacks are waited after the frame fence and before pool destruction;
58 fresh, ordered samples pass without validation errors. Browser timestamp
readback remains disabled under the existing compatibility constraint. Profiling
adds one tiny clear pass per marker; accepted clear benchmarks use local-device
`submit()`/`sync()` instead, without that instrumentation.

## Parallel feature batch (historical)

Logical copies, FSR1, FSR2 buffer atomics/two-dispatch luminance reduction, and font
upload coalescing are now implemented. New FSR2 coverage also exposed two driver
bugs: read/write storage support is format-specific even when the WGSL language
feature exists, and eliminated storage-image declarations still need their real
format in the bind-group layout. Both fixes retain supported-format fast paths.
The resource fixture now passes **58 checks in each native capability mode**.

The native editor links, and threaded web objects compile for the driver,
preprocessor, both upscalers, texture storage and both text servers. This is not a
complete web-template build: the existing baker still reports 10 GLSL and 4 Tint
failures. Detailed native evidence, negative controls and performance results are
in VALIDATION.md. At this checkpoint, shared-slice mip readback and storage lowering for SPIR-V-
specialized shader modules remained open. Later native fixtures close these
contracts with 18 readback checks and 320 specialization checks per mode; see
VALIDATION.md. The earlier ordinary shader-variant tests alone did not establish
those contracts.

### Auto-exposure follow-up

Reference-renderer testing exposed an unrelated luminance reduction error shared
by FSR2 and bilinear upscaling: `any(lessThan(...))` admitted lanes outside one
coordinate. Changing it to `all` fixes the inflated average without a new pass.
The production shader passes 24 numeric checks per backend; restoring the old
predicate fails 20 while full-workgroup controls pass. FSR2 temporal tests now
check 90 properties over 19 captures, with two exact repeated runs per backend.
This establishes bounded scene evidence, not full quality parity or browser
verification. See VALIDATION.md for the before/after exposure comparison.

## Final sampled contracts and SSR

The final native snapshot `413b6443bc377c8bf83f06c2344b36f1c4525d3b6b16bf387c70f7ea1e54562d`
passes 72 sampled-contract checks and 12 literal-collision checks in each of four
capability modes. SPIRV-Tools operand metadata prevents literals from being
mistaken for descriptor IDs while preserving conservative unknown-use and
stage/specialization contracts. SSR passes all 20 configurations and all 80
Metal-reference energy comparisons, including actual float32-filter omission.
Canvas SDF, MSAA/DOF, TAA, FSR1 and bounded FSR2 temporal coverage are recorded in
VALIDATION.md; these feature fixes are complete in native scope. Browser/backend
coverage and end-to-end performance remain separate acceptance work.
