# Particle cull-order regression probe

This deterministic project renders the same particle RIDs through two moving
cameras. It covers view-depth sorting, Z billboard alignment, velocity
billboards, local billboards, and serial versus worker-thread scene culling.
The scene uses fixed seeds and no shader `TIME` input.

Editor custom features select the culling threshold before the renderer is
constructed. Run from the engine checkout root with one feature per process:

```sh
BASELINE=/absolute/path/to/baseline/godot.macos.editor.arm64.mono
CANDIDATE=/absolute/path/to/candidate/godot.macos.editor.arm64.mono
PROBE="$PWD/misc/rendering/particle-cull-order-probe"

env GODOT_EDITOR_CUSTOM_FEATURES=particle_cull_serial \
  "$BASELINE" --path "$PROBE" --rendering-driver metal --fixed-fps 60 -- \
  --output=/tmp/particle-cull-baseline-serial
env GODOT_EDITOR_CUSTOM_FEATURES=particle_cull_threaded \
  "$BASELINE" --path "$PROBE" --rendering-driver metal --fixed-fps 60 -- \
  --output=/tmp/particle-cull-baseline-threaded
env GODOT_EDITOR_CUSTOM_FEATURES=particle_cull_serial \
  "$CANDIDATE" --path "$PROBE" --rendering-driver metal --fixed-fps 60 -- \
  --output=/tmp/particle-cull-candidate-serial
env GODOT_EDITOR_CUSTOM_FEATURES=particle_cull_threaded \
  "$CANDIDATE" --path "$PROBE" --rendering-driver metal --fixed-fps 60 -- \
  --output=/tmp/particle-cull-candidate-threaded

python3 "$PROBE/compare.py" equal \
  /tmp/particle-cull-candidate-serial /tmp/particle-cull-candidate-threaded
python3 "$PROBE/compare.py" equal \
  /tmp/particle-cull-baseline-serial /tmp/particle-cull-candidate-serial
python3 "$PROBE/compare.py" different \
  /tmp/particle-cull-baseline-serial /tmp/particle-cull-baseline-threaded
```

Every run must exit zero and print `PARTICLE_CULL_ORDER_DONE` with 22 captures.
The candidate serial/threaded and baseline-serial/candidate-serial comparisons
must report `PARTICLE_CULL_ORDER_COMPARE PASS ... mismatches=0`. An affected
baseline should make the final positive-control comparison pass with at least
one mismatch. Repeat each configuration and compare repetitions with `equal`
when checking determinism.

The fixture has a 180-second timeout and rejects missing callbacks, incomplete
captures, non-quiescent pipelines, and background-only readbacks.
