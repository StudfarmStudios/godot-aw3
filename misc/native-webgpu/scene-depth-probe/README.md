# Scene depth regression probe

This rendered probe checks the actual contents of `hint_depth_texture` with
`texture`, `textureLod`, and `texelFetch`, with MSAA disabled, 2x MSAA, and 4x MSAA.
Two opaque boxes sit at different depths behind a transparent material. That
material classifies the nearest box as red, the farther box as blue, and empty
space as black. An ordinary color texture in the same shader also checks that
depth typing does not change color bindings.

From the engine checkout, run an editor build with a real GPU (not `--headless`):

```sh
bin/godot.macos.editor.arm64.mono \
  --path misc/native-webgpu/scene-depth-probe \
  --rendering-driver webgpu --rendering-method forward_plus \
  --audio-driver Dummy --script scene_depth_probe.gd
```

Repeat with `--rendering-method mobile` for the raster depth-copy/resolve path,
and with `--rendering-driver metal` as a reference. Each run prints nine
`SCENE_DEPTH ... PASS` lines and exits with status 0. A wrong pixel or readback
timeout exits with status 1. The probe accommodates asynchronous WebGPU texture
readback and renders offscreen so its diagnostic colors do not flash in gameplay.

The original WebGPU failure returned zero for every sampled depth: the depth
attachment had been replaced by an empty float texture before the copy/resolve
pass. Checking for validation errors alone would not detect that failure.

When iterating on the SPIR-V translator without changing the engine commit,
remove only this probe's `user://wgsl_cache` before retesting; the disk cache key
includes the commit hash, not uncommitted source edits. Do not clear another
project's cache.
