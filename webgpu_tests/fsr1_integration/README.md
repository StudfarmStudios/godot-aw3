This fixture runs the engine's built-in FSR1 effect through a real Forward+ 3D viewport. It checks final pixels, the selected scaling mode and the format and dimensions of cached EASU/RCAS textures.

Run with a native editor built with `webgpu=yes` and the Dawn SDK:

```sh
python3 webgpu_tests/fsr1_integration/run_native.py /path/to/godot --output /tmp/fsr1-results
```

Native fixture frames are driven explicitly with `RenderingServer.force_draw(false)` so an occluded application window cannot pause the test. Before sampling each phase, the fixture waits for the engine's pending pipeline count to reach zero and pipeline request counts to stay stable for four completed frames. Pixel expectations do not drive warmup.

The runner requires all 30 checks in both normal and forced-fallback WebGPU modes, a clean exit and no validation or script errors. It saves engine/host metadata, logs and six output images per mode.

Coverage:

- SDR render targets without storage usage, including a color change between frames.
- HDR render targets without storage usage.
- Odd output extents and resize/scaling changes, checking that cached intermediates match the new dimensions.
- Compatible RGBA16F storage targets, checking the direct path does not allocate an RCAS intermediate.
- RGBA8 targets with storage usage, checking format conversion uses an RGBA16F intermediate and raster copy.

The last two cases supply targets through a one-view `XRInterfaceExtension`; no headset or production test hook is required. They test renderer target overrides, not stereo rendering. Intermediate formats are read from the real `RenderSceneBuffersRD` via a compositor callback; pixels come from actual GPU output.

This suite is a correctness regression. It does not benchmark throughput or establish Windows/Firefox/D3D12 compatibility. Solid colors detect missing dispatches, stale results, incorrect channels and uncovered edges, but do not establish FSR edge-reconstruction quality.

Verified on Apple M1 Ultra / macOS 26.5.2 using native Dawn/Metal: all 30 checks passed in both normal and forced-fallback modes with no validation errors and clean exits. The tested engine SHA-256 was `46dc9ae5ce79ead485786b146e960ed19ea5e6c240475836f3a8be773aa90b62`.

The preserved pre-FSR-fix engine (`180d7f82a0f00404fb8fcabc58a9a7609cde1f52c4e9a36a6cd5486385d689d4`) reproduces the disabled normal-variant error and leaves an open compute list that causes subsequent rendering errors. Intermediate candidate runs also demonstrated that ignoring the override target produces black XR-target readbacks and an unnecessary RCAS intermediate.
