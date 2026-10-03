# Lightmap shader regression probe

This scene attaches a synthetic red lightmap to a white mesh. It needs no baked
assets or importer cache. With no direct or ambient lighting, its center pixel
must be red: checking the pixel also catches a missing lightmap binding.

Run with a real GPU from the engine checkout:

```sh
bin/godot.macos.editor.arm64.mono \
  --path misc/native-webgpu/lightmap-probe \
  --rendering-driver webgpu --rendering-method forward_plus --audio-driver Dummy
```

Repeat with `--rendering-method mobile`, and with `--rendering-driver metal` as a
reference. Each run prints `LIGHTMAP_PROBE PASS` and exits with status 0. A wrong
pixel or a texture-readback timeout exits with status 1. The scene can also be
exported with a WebGPU template for the browser; it waits for async readbacks.

Previously, rendering the first lightmapped mesh enabled Forward+'s advanced
shader group, including the unused SDF voxelization variants. Their image
atomics caused Tint to abort on `OpImageTexelPointer` before any lightmap pixels
could be drawn. WebGPU now skips both the specialized and uber SDF variants.
The metadata array also uses a uniform buffer on WebGPU so lightmap variants
stay within the ten-storage-buffer limit (previously eleven).

This does not add WebGPU SDFGI support. Native Metal/Vulkan still compile their
SDF variants.
