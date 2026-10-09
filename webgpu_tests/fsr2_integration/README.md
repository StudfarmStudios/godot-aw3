# Forward+ FSR2 smoke fixture

Run a native Godot editor built with WebGPU/Dawn:

```sh
python3 webgpu_tests/fsr2_integration/run_native.py /absolute/path/to/godot --output /tmp/fsr2-results
```

Four real Forward+ viewport phases check eight output-size/color assertions in
normal and forced-fallback capability modes: SDR color changes, HDR, and odd-size
resize. Internal dimensions exceed 64 pixels, so the luminance pyramid spans
multiple SPD workgroups. The runner rejects engine/validation errors, timeouts,
missing checks and unsuccessful shutdown. PNGs and machine-readable results are
written outside the fixture sources.

Frames are driven explicitly, including when the native window is occluded.
Readiness requires the actual asynchronous pipeline queue to drain and compilation
counters to stay stable for 32 rendered frames. Expected pixels never determine
readiness. This smoke test does not establish temporal quality, native-renderer
parity, browser compatibility or Windows/D3D12 behavior.
