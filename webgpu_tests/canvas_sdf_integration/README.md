# Canvas SDF visual regression

This scene renders actual `LightOccluder2D` distance fields into an HDR 2D SubViewport. It checks signed masks, numerical distances and two well-defined exterior normals; moving and concave occluders; 100%, 50% and 25% SDF resolution; an odd viewport resize; and a clipped occluder with 200% oversize. Each mode has **36 checks and nine image captures**.

```sh
python3 webgpu_tests/canvas_sdf_integration/run_native.py /absolute/path/to/engine --output /private/tmp/canvas-sdf
```

Default modes are native Metal, native WebGPU, `--webgpu-force-fallbacks`, actual omission of `Float32Filterable`, and both omissions together. Explicit offscreen frames and a bounded pending-pipeline/stable-request gate handle asynchronous compilation. Expected pixels never drive warmup. The runner rejects engine errors, failed checks, timeout, wrong backend and nonzero exit. Raw linear float images and PNGs stay in the output directory; result JSON contains numerical differences against Metal. Normal comparisons use only the two exterior points because a normal is not unique on medial axes.

## Evidence and correction

`results/baseline-macos-arm64.json` records engine SHA `67c9e7d81941c96e1218cd3d7a0e222af17b283a1d94a54e69bdb9dda428e136` on Apple M1 Ultra / macOS 26.5.2:

| Mode | Checks | Engine errors |
| --- | ---: | ---: |
| Metal | 36/36 | 0 |
| WebGPU native | 36/36 | 0 |
| Forced fallbacks | 36/36 | 0 |
| Float32 filtering omitted | 24/36 | 0 |
| Both omissions | 24/36 | 0 |

Without float32 filtering, scalar float16 storage is promoted to R32F, then the driver replaces the filtered SDF input with a blank texture. Interiors disappear, distances become zero, and even well-defined exterior normals become NaN. The error-free log is insufficient evidence of correctness.

The correction selects a single SDF output format and matching shader definition in `TextureStorage`: keep native R16_SNORM; use scalar R16F on filterable fallback devices; use filterable RGBA16F only when normalized16 storage and float32 filtering are unavailable. The affected output grows from promoted R32F's four bytes per pixel to eight, with no additional dispatch, copy or texture. Eighteen GLSL/Tint shader variants compile successfully (`results/shader-translation.json`), including all six SDF modes for each output format. `results/corrected-macos-arm64.json` records the rebuilt engine SHA `e6d26dd46c9871a75b75e62b5cac42dd2bbc7b0fe727a67414cf7a56bc4fdfa9`: **36/36 checks in all five modes**, zero engine errors, all normal exits.

Across the corrected modes, the largest distance-image mean absolute error against Metal is 0.000153; the selected normals match exactly. These are bounded macOS native tests, not Firefox/Windows/D3D12 coverage or general image-quality parity.
