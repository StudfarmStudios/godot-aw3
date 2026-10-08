# Forward+ MSAA and depth-of-field regression

This real-renderer scene has **153 checks and 27 captures per mode**. Three opaque checkerboards lie at known near/focus/far distances; a separate slanted white quad measures geometric MSAA coverage. It requests MSAA off/2x/4x/8x, switches DOF on and off, resizes to odd dimensions, tests HDR and SDR output, switches orthographic/perspective projection, and uses hexagon/box/circle bokeh. A compute probe reads the actual rendered depth at the three object centers. DOF checks require near/far contrast reduction and preserved focus; disabling DOF must recover the exact original pixels.

```sh
python3 webgpu_tests/msaa_dof_integration/run_native.py /absolute/path/to/engine --output /private/tmp/msaa-dof
```

Default modes are native Metal, WebGPU, forced capability fallbacks, omitted `Float32Filterable`, and both omissions. The depth probe uses distinct shader contracts for hardware depth attachments and resolved R32F textures. Renderer metadata records requested and effective sample counts. Offscreen drawing, a bounded pipeline gate, and a render-thread metadata handoff ensure complete frames without pixel-driven retries. The runner rejects engine errors and incomplete/failed runs. Pixel differences against Metal are diagnostic; different effective MSAA counts can legitimately differ at edges.

## Recorded negative controls

`results/baseline-macos-arm64.json` records engine SHA `67c9e7d81941c96e1218cd3d7a0e222af17b283a1d94a54e69bdb9dda428e136`, Apple M1 Ultra / macOS 26.5.2. All runs exited normally with zero engine errors, but the numerical oracles found:

| Mode | Checks | Failure |
| --- | ---: | --- |
| Metal | 149/153 | Requested 8x resolves half the correct depth; focus blurs |
| WebGPU | 152/153 | MSAA-off focus blurs |
| Forced fallbacks | 152/153 | Same MSAA-off failure |
| Float32 filtering omitted | 120/153 | 24 resolved-depth samples become zero and all nine focus checks fail |
| Both omissions | 120/153 | Same missing-filtering failures |

All nine geometric coverage checks pass in every mode. WebGPU maps requested 2x/4x/8x to effective 4x. Native/fallback images otherwise match Metal exactly in the tested passing DOF configurations; the broken Metal 8x case is explicitly not a quality reference.

## Source corrections and current result

- `BokehDOF` appends a blur-size shader variant with the established `godot_depth_source` marker, selected for an actual depth attachment. Resolved R32F retains the ordinary float variant. Both compute and raster shaders support the distinction, with no extra rendering pass. Four GLSL/Tint first-pass variants compile, including preserved depth texture types (`results/shader-translation.json`). Only Forward+ compute has a real-renderer fixture here; raster DOF is translation-checked.
- Metal now advertises the same supported-sample mask it already uses internally to clamp texture and pipeline creation. This lets the common renderer supply the actual sample count to depth resolves instead of dividing four physical samples by eight.
- The WebGPU driver now derives exact-fetch contracts from original SPIR-V, preserving stage and specialization unions and actual filtered sampling. It retains the real R32F input for unfilterable bindings and re-evaluates original textures and samplers when uniform sets move between shaders. Compute DOF reads the invocation's depth texel directly, exactly matching its former pixel-center sampling; raster filtering remains unchanged. No extra rendering pass is added. The focused `sampled_texture_filtering` fixture checks these contracts independently.

`results/corrected-macos-arm64.json` records the final engine SHA `e6d26dd46c9871a75b75e62b5cac42dd2bbc7b0fe727a67414cf7a56bc4fdfa9`: **153/153 in all five modes**, zero engine errors and clean exits. All four WebGPU modes match native Metal exactly in 24 of 27 captures. The three requested-2x captures have different effective sample counts (Metal 2x, WebGPU 4x); their maximum image mean absolute difference is 0.000265. The near/far blur, focused detail, effective depth, geometric coverage and exact DOF-reset oracles all pass.

No browser coverage, Firefox/Windows/D3D12 result, broad quality parity or performance improvement is claimed.
