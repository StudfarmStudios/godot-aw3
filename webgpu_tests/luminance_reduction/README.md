# Luminance reduction bounds regression

This fixture compiles the actual production `luminance_reduce.glsl` into a local
RenderingDevice and compares GPU results with direct CPU averages of the input
texels. It exercises both sampled and storage-image inputs, immediate exposure
and one-frame adaptation, and 1×1, 3×2, 5×3, 7×7, 8×8 and 13×9 inputs. The last
case includes four workgroups and partial edge tiles. There are 24 checks per
backend; each checks every output tile within an absolute tolerance of 0.00001.

Run from the engine repository:

```sh
python3 webgpu_tests/luminance_reduction/run_native.py /path/to/godot --legacy-control
```

The default matrix uses native Metal, native WebGPU, and WebGPU forced fallbacks.
Use `--modes native fallback` on a host without the Metal driver. Local rendering
devices submit and synchronize before readback; no expected pixel value controls
shader readiness. The runner rejects shader/GPU errors, timeout, incomplete
checks, or an unexpected process exit.

The optional negative control changes only the production bounds predicate in
memory from `all` to the former `any`, then runs native WebGPU. It must complete
all checks without engine errors and fail at least one numeric oracle. This is
an intentional failing shader, not an accepted failure of the corrected shader.

## Recorded evidence

On Apple M1 Ultra / macOS 26.5.2, binary SHA-256
`8102c335e324ebf8c62512e26eb507a63ad63884c4eff1863962aa3cfc2aa09e`:

- Corrected source: 24/24 on Metal, 24/24 on WebGPU, 24/24 on forced fallbacks.
- Legacy predicate: 20 numeric failures, with only the four full 8×8 controls
  passing. Both sampled and storage-image paths fail. There are no engine or
  validation errors; the negative control exits 1 as required.

`results/macos-arm64.json` preserves checks and binary/source hashes. Large logs
and images are deliberately omitted. The companion `fsr2_temporal` fixture
validates the compiled renderer and the visible auto-exposure consequence.

## Cause and scope

An 8×8 workgroup reducing a 3×2 final image must read only six texels. The former
`any(lessThan(pos, source_size))` admits 34 invocations, because either coordinate
can satisfy it. On this WebGPU backend, out-of-bounds accesses replicate edge
values, while native Metal's observed output matches zero for those accesses.
The reduction still divides by six, inflating luminance and darkening exposure.
Requiring `all` coordinates to be in range removes invalid reads without adding
any dispatch or texture. Browser, Windows/D3D12 and Firefox are not covered by
these native macOS tests.
