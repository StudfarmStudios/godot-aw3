# Particle visual parity probe

This deterministic fixture exercises the production GPU particle command chain:

- 1,025 view-depth-sorted 3D particles (sort fill, merge sort, sorted instance copy).
- A collision-triggered 3D sub-emitter.
- 3D ribbon trail simulation and history copies.
- Index-order 3D particles with TAA, camera motion, and emitter motion to request motion vectors.
- 2D particle simulation and instance copies.

Every system is visible for 90 warm-up frames before its fixed seed is restarted.
The probe freezes both simulation and its `SubViewport` during readback, and drains
two stale transfers before accepting an image. This is intentional: native WebGPU
texture readback completes on a later frame.

Run each engine twice first to prove that its own output is stable, then compare the
baseline and candidate `metadata.json` SHA-256 maps:

```sh
./bin/godot.macos.editor.arm64 --path misc/rendering/particle-visual-probe \
  --rendering-driver metal --fixed-fps 60 -- \
  --output=/tmp/particle-metal-baseline-a

./bin/godot.macos.editor.arm64 --path misc/rendering/particle-visual-probe \
  --rendering-driver metal --fixed-fps 60 -- \
  --output=/tmp/particle-metal-baseline-b

./bin/godot.macos.editor.arm64 --path misc/rendering/particle-visual-probe \
  --rendering-driver webgpu --fixed-fps 60 -- \
  --no-taa \
  --output=/tmp/particle-webgpu-baseline-a

python3 misc/rendering/particle-visual-probe/compare.py \
  /tmp/particle-metal-baseline-a /tmp/particle-metal-baseline-b
```

Use the same commands and distinct output directories for the candidate binary.
The test expects the same machine, GPU, rendering driver, and 640×480 viewport.
First require baseline A and B to have identical hashes. Then require candidate A
and B to be internally identical, and finally compare baseline to candidate per
backend. Inspect the PNGs whenever a hash differs; a backend's images are compared
only with the same backend.

The full fixture remains the default on Metal. On the current unmodified native
WebGPU baseline, the full fixture aborts in Tint with an unhandled
`OpImageTexelPointer` instruction. TAA requests motion vectors, which enables the
forward-clustered advanced shader group; that group also compiles an unused SDF
variant containing image atomics, which WebGPU does not support. `--no-taa` is the
narrow isolation run for that existing renderer issue. It preserves all particle
systems, rigid collision, sub-emission, trails, sorting, and 2D simulation while
metadata records TAA and motion vectors as excluded coverage.
The browser WebGPU path has not been run with this fixture.

Before accepting each capture, the probe requires at least 64 pixels whose RGB
color differs materially from the top-left background pixel. It stops scanning
as soon as the threshold is met. This makes an empty or all-background renderer
result fail closed instead of producing a successful set of identical images.

The fixture exits `0` after writing ten `frame-NNN.png` images and
`metadata.json`, or `2` after a blank image, readback, or file error. Do not use
`--write-movie`: the probe's own readback state machine is what makes
selected-frame labels reliable on WebGPU.
