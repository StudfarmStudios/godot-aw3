# WebGPU compatibility and feature ports

Implement the applicable fixes from the 2026-10-08 AW3 comparison of
Shane-Gadsby/godotwebgpu. Keep the engine on **Godot 4.7.1**; upgrading to 4.8 is
explicitly deferred until a stable release. This file tracks the full scope,
including unfinished work, across implementation batches.

Performance is an acceptance criterion: keep existing performance or improve it,
allowing measured small costs for meaningful fidelity improvements. Avoid
unnecessary texture copies, pass restarts, eager work, and hot-loop overhead.

Reference report: [AW3 comparison](https://github.com/StudfarmStudios/aw3/blob/6a8d774dd31e7fd74c94ec59d7cf47a23c94a5d3/docs/gameclient/webgpu-fork-comparison-2026-10-08.md).
Source fork: `470f89e78eece1c7a73285345e2ca39b8f8706ad`.
Starting AW3 engine: `c0d51825faad2c1a773f4e21c34e74b60c53da21`.

## Work remaining

| Report findings | Work | Status / evidence |
| --- | --- | --- |
| 1–3, 7–8 | Capability-aware packed/narrow storage formats, matching WGSL and views, complete upload/readback conversions | Implemented; ASan/UBSan production helper tests pass. 25 native GPU checks pass in each capability mode; browser runtime pending |
| 4 | Bind uniform sets against the requested shader, preserving lazy layout initialization | Implemented; native GPU variant and push-constant checks pass; browser runtime pending |
| 5–6 | GPU-written shadow refresh, variant adaptation, first-use ordering and mip/layer correctness | Implemented at dispatch, one restart for all active sets; no CPU shadow replay. Native 2D/array/3D/slice checks pass; browser runtime pending |
| 9–10 | Effective MSAA count and format-converting resolve | Implemented; requested 2/4/8, native/promoted RG16F resolve and nonzero destination mip/layer pass in both native modes. Full renderer AA matrix/browser pending |
| 11 | Block-aligned compressed texture copies; preserve array stride fix | Implemented; native compressed array/mip-tail GPU copy and readback checks pass; browser runtime pending |
| 12 | Partial color/stencil clears; preserve depth-region clears and batched submissions | Implemented; mixed HDR/float/integer targets, sparse masks, depth/stencil probes, MSAA and ring exhaustion pass natively. Browser pending |
| 14–16 | SDFGI formats, cascade bindings, typed defaults and correct atomic fallback | Pending |
| 17 | FSR2 capability variants and atomic-buffer fallbacks without last-writer-wins depth reduction | Pending |
| 18–19 | FSR1 destination fallback and Canvas SDF format fallback | Canvas SDF implemented and compiled. FSR1 pending |
| 20–22, 24 | Logical-copy lowering, reviewed SPIR-V normalization/Tint fixes, structural vertex-access transform | Pending |
| 27–31 | Export baking, target capabilities, coverage, subprocess conversion, combined cache metadata and cache preference | Pending |
| 35–36 | Atlas upload coalescing and glyph classification, retaining immutable render-thread snapshots | Pending |
| 37–38 | CPU gradient regeneration and compressed-texture readback | Gradients implemented/tested. Finding 38 correction: disk-backed `CompressedTexture2D::get_image()` is already identical in our base; no additional port needed |
| 45–49 | Feature fixtures, actual-driver regressions, browser/backend metadata, CI integration | Production C++ format tests and initial RenderingDevice GPU fixture added. Full matrix/CI pending |
| 58 | Headless export teardown fix, adapted to 4.7 if applicable | Pending |

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

## Initial batch validation

See [VALIDATION.md](VALIDATION.md) for commands, measured performance and limits.
Production CPU helpers pass ASan/UBSan; 25 actual GPU checks pass in each of the
normal and forced-fallback native Dawn/Metal modes (50 total), with zero
validation errors and clean shutdown. Headless gradient checks and the existing
327 JavaScript driver-model checks pass. Native editor linking and threaded web
WebGPU driver object compilation passed; the full web template/browser run is
still pending. The build-time shader baker reports 10 GLSL and 4 Tint failures,
which remain part of the shader/export work above, not passing coverage.

Additional issues found by the new fixture were fixed in this batch:

- 3D transfer origins now use the depth offset rather than the array-layer field.
- Compressed readback retains RenderingDevice's block-aware staging row pitch.
- Push-constant ring offsets survive snapshot pass restarts without a new bind.
- Native Dawn pipeline completion uses the event pump to avoid a device-mutex
  deadlock during shutdown. Compilation stays asynchronous; browser callback
  delivery is unchanged. The fixture requires clean process exit.

No Firefox/Windows/D3D12 runtime result or end-to-end performance comparison is
available yet. The remaining rows above still represent required work.

### Additional validation findings

Native GPU timestamp capture currently calls Dawn's restricted standalone
`WriteTimestamp`, which rejects commands unless unsafe APIs are enabled. Found
while preparing the clear benchmark; use standard pass timestamp writes and test
this before claiming native GPU profiler support. Browser timestamp readback stays
disabled under the existing compatibility constraint. The accepted clear timings
use a local device with `submit()`/`sync()`, not invalid timestamp results.
