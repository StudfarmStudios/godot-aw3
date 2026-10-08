# FSR2 atomic-depth callbacks on the actual GPU

```sh
python3 webgpu_tests/fsr2_atomic_depth/run_native.py /absolute/path/to/godot --output /tmp/fsr2-atomic
python3 webgpu_tests/fsr2_atomic_depth/run_mutation_controls.py /absolute/path/to/godot --output /tmp/fsr2-atomic-controls
```

Requires glslang and a native WebGPU/Dawn build. Shaders include the production
FSR2 callback header; no callback implementation is copied into the test.
144 checks per capability mode exercise conventional and inverted depth,
4,096 competing writers per texel, repeated resets, differing allocated/rendered
extents, exact callback/SSBO values, and out-of-range coordinates that could alias
valid pixels after flattening to a buffer index.

Negative controls modify temporary copies of the headers only. Replacing atomic
updates with ordinary stores fails 24 checks; removing coordinate bounds fails
118. These controls verify numerical failures with clean execution, rather than
counting shader validation errors or timeouts as evidence. Saved results identify
the engine and production-header hashes. Native Dawn/Metal results do not validate
Firefox/Windows/D3D12.
