# Texture mip and slice readback

This fixture calls the real native WebGPU driver's synchronous `texture_get_data`.
It checks every mip in RGBA8, promoted R8/RG16F storage textures, and BC3 arrays,
including a view beginning at mip 1/layer 1 and a second read after an upload.
Two volume checks include all depth planes at each mip and a nonzero-mip view.

```sh
python3 webgpu_tests/texture_readback/run_native.py /path/to/godot --output /tmp/readback
```

The previous implementation returned only the base plane of mip zero, ignoring
view offsets. All 18 checks fail numerically on the baseline. The corrected
implementation passes 18 checks in each normal/forced-fallback mode, without
validation errors and with clean exit. Results identify the tested executable.
It packs all copies into one command encoder and one staging-buffer map; row
padding, compressed blocks and promoted format conversion remain per-plane.
Copying all requested mip/depth data necessarily transfers more data than the
incorrect partial read. No browser synchronous-readback capability is claimed.

The larger driver fixture separately tests asynchronous RenderingDevice reads;
these direct driver checks cover the path used by internal renderer operations.
