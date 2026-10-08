# Production WebGPU driver regressions

This project calls Godot's real RenderingDevice, translates GLSL through the
engine, records GPU work and compares asynchronous readback bytes. It complements
the standalone JavaScript models; it does not replace the Forward+ scene matrix.

Run a native editor built with `webgpu=yes` and Dawn:

```sh
python3 webgpu_tests/driver_integration/run_native.py /absolute/path/to/godot
```

The runner executes normal capabilities and forced fallbacks, saves logs and JSON
in `artifacts/`, and rejects validation errors, missing callbacks, renderer
fallbacks and partial results. A real window/GPU is required. On macOS this uses
Dawn/Metal; it is **not** a Firefox/Windows/D3D12 test.

`-- --webgpu-force-fallbacks` disables tier-1/tier-2 use and read/write storage
textures in the driver. Native Dawn additionally omits tier-1/tier-2 from its
device request, so unsupported-format validation is exercised on capable hardware.
The argument is test-only and should not be included in ordinary game launches.

Current cases:

- Packed RGB10A2 UNORM/UINT and RG11B10 float uploads/readbacks and shared views.
- Narrow signed/unsigned integer and half-float promotion and reverse conversion.
- GPU write followed by first-use read/write layout adaptation.
- Repeated dispatch with no intervening bind, and redundant set binding.
- 2D, array and distinct 3D depth values; a nonzero mip/layer slice; untouched layers.
- Push constants retained through snapshot pass restarts.
- Compressed BC3 array copies/readback through 2×2 and 1×1 mip tails.
- Requested 2×/4×/8× MSAA counts and native/promoted RG16F resolves.
- MSAA resolve into mip 1/layer 1, preserving other mips and layers.
- Partial clears of mixed integer/float/HDR targets and sparse attachment masks.
- Neighboring atlas regions, depth-only clears, depth/stencil probes, and MSAA.
- Shared upload-ring wraparound with more than 2048 partial clears.

`test_gradients.gd` separately verifies procedural gradient readback with the
headless renderer, including width one, HDR, LDR and immediate parameter changes.

CPU helper tests and the conversion microbenchmark live in
`misc/webgpu-port/`. Browser export/runner integration and additional renderer
fixtures are tracked in `misc/webgpu-port/STATUS.md`.

`benchmark_clears.gd` and `run_clear_benchmark.py` measure submission plus GPU
completion on a local device, with alternating baseline/candidate runs. See
`misc/webgpu-port/VALIDATION.md` for measured results and limitations.

`run_headless_exports.py ENGINE --output DIRECTORY` checks import and three Web
pack exports, including teardown errors and pack headers. `test_timestamps.gd`
checks fresh, ordered native GPU readbacks on a Dawn adapter supporting
TimestampQuery; browser timestamp readback is intentionally not enabled.
