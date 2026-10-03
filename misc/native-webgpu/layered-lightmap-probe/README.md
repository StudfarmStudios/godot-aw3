# Compressed layered lightmap regression

Run with a visible native window and either `--rendering-driver metal` or
`--rendering-driver webgpu`:

```sh
bin/godot.macos.editor.arm64.mono \
  --path misc/native-webgpu/layered-lightmap-probe \
  --rendering-driver webgpu --rendering-method forward_plus -- --format=bc6
```

Repeat with `--format=bc1` and `--format=rgba8`, and with the Mobile renderer.
The probe creates a 44-layer, 64×64 texture without mipmaps. Layers 0, 5, and 43
light red, green, and blue quads; both ordinary and compressed mesh attributes
are covered. It checks rendered pixels after pipeline compilation and exits
nonzero on failure. No direct lights or ambient illumination can mask a failure.
The BC6H fixture uses fixed blocks rather than the active GPU's texture compressor.

BC6H exercises the compressed HDR format used by Mayhem's baked atlas. BC1 also
exercises row padding: its 128-byte block rows require 256-byte WebGPU staging
rows. RGBA8 is the uncompressed control.

Before the fix, staging layers were separated using pixel rows rather than block
rows. WebGPU's direct multi-layer upload read that padding as texture data, so
layer 0 could pass while later lightmap layers sampled garbage. The old single
layer lightmap probe could not detect this failure.
