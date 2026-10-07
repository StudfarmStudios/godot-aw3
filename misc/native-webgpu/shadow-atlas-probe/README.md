# Shadow atlas regression probe

Run with a real GPU, without `--headless`:

```sh
bin/godot.macos.editor.arm64.mono \
  --path misc/native-webgpu/shadow-atlas-probe \
  --rendering-driver webgpu --rendering-method forward_plus \
  --audio-driver Dummy -- --quadrant=3 --depth=16
```

Repeat with `--quadrant=1 --depth=32`, with `--rendering-method mobile`, and
with `--rendering-driver metal` as a reference. Use a fresh process for each
configuration so the test does not depend on live atlas format reallocation.
The scene is also directly exportable for browser verification.

A point light illuminates a box and floor. Its two dual-paraboloid shadow tiles
are allocated away from the atlas origin. The test checks three rendered states:

- The box casts a dark shadow on the floor.
- Moving the box clears that old shadow while shadows remain enabled.
- Disabling shadows illuminates the same floor region.

Success prints `SHADOW_ATLAS ... PASS` and exits with status 0. An incorrect
pixel or readback timeout exits with status 1. Browser texture readbacks are
flushed between states. Pipeline compilation is allowed to finish before
sampling the image.

This catches both original failures: scissor rectangles clipped against a tile's
size instead of the attachment extent, and a tile clear erasing the whole atlas.
The baseline WebGPU driver leaves the sampled floor equally bright in all three
states, even without validation errors. The test keeps Godot's fast two-pass
point-light shadow path enabled.
