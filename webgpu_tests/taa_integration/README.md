# TAA velocity history regression

The fixture renders a real Forward+ scene with TAA, moves the camera, and reads
both the current velocity and TAA's previous-velocity texture through a GPU
sampling pass. It checks every component over the complete internal image; these
renderer-owned textures do not need extra CPU-readback flags. Visible output,
logical RG16F history format, extent and nonzero motion are checked too.

```sh
python3 webgpu_tests/taa_integration/run_native.py /path/to/godot
```

The default matrix uses native Metal, native WebGPU and forced WebGPU fallbacks.
Use `--modes native fallback` where the native Metal driver is unavailable.
Each run checks four scenarios, with 16 total oracles:

| Output extent | Scale | Internal/history extent |
| --- | ---: | --- |
| 160×120 | 1.0 | 160×120 |
| 160×120 | 0.5 | 80×60 |
| 160×120 | 1.5 | 240×180 |
| 193×131 | 1.25 | 241×163 |

Rendering uses explicit 1/60-second offscreen frames, a pending-pipeline/stable
request-count gate independent of expected pixels, and compositor metadata
handoff synchronization. The sampled readback runs after the TAA pass; it never
retains RenderData. All current/history velocity components must be finite and
exactly equal, with nonzero camera motion. The runner rejects GPU/engine errors,
timeouts, incomplete checks and abnormal process exits.

## Fixes and evidence

TAA's velocity history is RG16F. The old generic copy shader declares an RGBA16F
output, which WebGPU rejects against this target (physically RG32Float where
RG16F storage is unsupported). CopyEffects now selects a dedicated RG16F output
variant, preserving normal backend format promotion and the compact history
texture. There is no additional pass.

The old velocity copy also used output extent even though both velocity textures
have internal extent. At scales above 1.0 this leaves part of history unwritten;
at smaller scales it dispatches outside both images. TAA now copies internal
extent, matching its allocation and resolve pass.

On Apple M1 Ultra / macOS 26.5.2, corrected binary SHA-256
`d06206f6c8f66ecd6e8708d477c4ed07f2bb3227a835598c69122dfc7bf305ed`
passes **16/16 on all three backends**, without errors. Every velocity component
matches exactly in every scenario.

The earlier `9bff02c4a795126c140e2d280c9f9ca926c5b540178b6c6b1d32564dc1e1f2fb`
binary fails independently on native Metal: 13/16 checks pass, but supersampled
history is incomplete/nonfinite, without engine errors. This isolates the extent
defect from WebGPU's storage-format validation. The same old binary gives 8/16 on
native WebGPU and repeatedly reports the RG32Float/RGBA16Float bind-group
mismatch. Saved baseline errors are deduplicated; no large logs are committed.

`results/` preserves concise hashes, checks and errors. These are native macOS
correctness checks; they do not establish Firefox/Windows/D3D12 coverage, general
TAA image-quality parity or a measured performance improvement. The shader-baker
cold/placeholder fixture separately exercises late TAA activation and cache paths.

The final integration editor (`0ed5f70e77c8124477c15acc89c69e56533deb299c6b2a7ec45e4a2b33ad6a7d`)
repeats all **16/16 checks on Metal, normal WebGPU and forced fallbacks**, with
zero errors. This follows the build-time define separator correction; the local
compiler produces identical TAA SPIR-V before/after that correction. The separate
real-GLSL regression rejects joined definition blocks even on permissive compilers.
See `results/final-macos-arm64.json`.
