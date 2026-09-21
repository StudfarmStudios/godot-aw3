# GPU particle frame-order probe

This standalone project probes cross-frame GPU ordering in the continuous
GPUParticles3D path. It creates a procedural approximation of 50 Viper booster
groups: 200 emitters sharing one ParticleProcessMaterial, with four authored
nozzle transforms and four draw resources shared across groups. Each emitter
has 256 slots, a 0.02 amount ratio, 0.2 second lifetime, 2x speed, a 100 Hz
fixed particle step, turbulence, global coordinates, and a distinct fixed seed.

The probe freezes TIME while it warms particle and draw pipelines, waits for
pipeline compilation to quiesce, uses the AW3 harness's clear/stop/restart
sequence on every emitter, and then renders 120 uninterrupted frames. It
performs no intermediate image or AABB readbacks. Only frame 119 is captured;
the AABB digest is collected afterward, so neither can repair ordering before
the measured image.

## Confirmed regression

The probe reproduced the ordering regression on native Metal on an Apple M1
Ultra. Two runs of the `36b1b4513` baseline and two runs of the ordered fix were
stable and identical:

- Image: `94dea953a0126275f9b3f4ac8e91c17d373adcd2ddb1fa17d0f9bc6f71de17a4`
- AABB: `9186b2291be0a02a52d38af22ce07707dff095a4a5baa8456890b224eab8343a`
- Foreground pixels: 1468

The unfenced negative control differed from both:

- Image: `14569f8131215e6d49a4492d8a85b98c7e9acc7eb2ac39f3bea88b257572805b`
- AABB: `e1b75488324196854ea8b8cc5b7cd3f98804e9ea9e3b39d4e4de341a6ce9752a`
- Foreground pixels: 1468

These results establish this as a regression fixture for native Metal on that
machine. Validate other platforms and rendering drivers independently.

Run every engine binary twice on the same backend and machine:

```sh
./bin/godot.macos.editor.arm64.mono \
  --path misc/rendering/particle-frame-order-probe \
  --rendering-driver metal --audio-driver Dummy --fixed-fps 60 \
  --script res://probe.gd -- --output=/tmp/particle-order-baseline-a

./bin/godot.macos.editor.arm64.mono \
  --path misc/rendering/particle-frame-order-probe \
  --rendering-driver metal --audio-driver Dummy --fixed-fps 60 \
  --script res://probe.gd -- --output=/tmp/particle-order-baseline-b
```

Repeat with separate output directories for the unfenced and fixed engines.
First require each engine's two runs to have identical `frame_119_sha256` and
`aabb_after_frame_119_sha256` values in `metadata.json`. Then compare those
values between baseline and candidate runs using the same rendering driver.
The probe exits nonzero if pipeline warmup, readback, image saving, metadata, or
the nonempty-foreground assertion fails.

All five confirmation runs exited successfully but reported one
`ParticlesShaderRD` and one `MaterialStorage::Shader` allocation at process
shutdown, after the completion marker. The diagnostics were identical across
baseline, unfenced, and ordered binaries and are not used as comparison data.
