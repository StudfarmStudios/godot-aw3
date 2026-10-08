# Forward+ screen-space reflection regression

The scene reflects an emissive red cube in a metallic floor. It tests sharp and rough reflections, even and odd viewport dimensions, half/full SSR resolution, and MSAA off/4x. The default matrix has **20 runs**, each with fifteen source/reflection/stability checks: native Metal plus WebGPU normal, forced storage fallbacks, omitted float32 filtering and both omissions.

```sh
python3 webgpu_tests/ssr_integration/run_native.py /absolute/path/to/engine --output /private/tmp/ssr
```

Explicit offscreen frames and a bounded pipeline-readiness gate precede captures. The runner rejects shader/engine validation errors and incomplete runs. Nonzero reflections alone are insufficient: all eighty WebGPU phase comparisons must retain **95–105%** of native Metal's integrated red reflection energy at matching resolution and MSAA. Expected pixels never control warmup.

`--debug-buffers` additionally fetches the real HiZ and reflection mip chains, normal/roughness, mip-selection field, final resolve and history into a readback SSBO. This avoids changing production textures' usage flags. Raw RGBA32F buffers and metadata stay in the output directory; debug captures are optional and are not performance measurements.

## Evidence and corrections

`results/baseline-macos-arm64.json` records SHA `e6d26dd46c9871a75b75e62b5cac42dd2bbc7b0fe727a67414cf7a56bc4fdfa9`. Normal and forced-storage paths are within 0.2% of Metal. Omitted-filtering paths retain only 0.7–27% of reflection energy despite clean engine logs. Intermediate capture isolated identical HiZ mip 0 and normals, followed by all-zero HiZ mip 1 and later levels.

The driver previously mistook GLSL `FMax`'s literal instruction number 40 for sampled-image ID 40, retaining a filtered layout and substituting a blank R32F depth source. Grammar-defined ID operands correct this general analysis defect; `sampled_texture_literals` separately proves extended-instruction, composite-index, switch-case and debug-line collisions. Unknown resource operations remain conservative. Full-size reflection composition now explicitly fetches the single-level mip-selection field with the exact previous nearest/clamp semantics, so promoted R32F needs no optional filtering feature. Reflection-color filtering remains unchanged.

The renderer also distinguishes actual hardware depth from resolved scalar depth in SSR downsample, HiZ and resolve shaders, selecting the appropriate source contract. `results/corrected-macos-arm64.json` records SHA `413b6443bc377c8bf83f06c2344b36f1c4525d3b6b16bf387c70f7ea1e54562d`: **20/20 runs**, all **300 scene checks and 80 reference comparisons** pass, with no engine errors and clean exits. Normal and omitted-filtering energy ratios are exactly 1.0; forced storage and combined fallbacks range from 0.998625 to 1.001855. Optional intermediate probes separately confirm identical HiZ and reflection data between normal and omitted-filtering modes.

This is bounded native macOS/Dawn-Metal image evidence, not browser, Firefox/Windows/D3D12 coverage or broad quality/performance parity.
