# Particle sort bounds regression

From the engine checkout, run with a native Metal build:

```sh
./bin/godot.macos.editor.arm64.mono --path misc/rendering/particle-sort-probe --rendering-driver metal --audio-driver Dummy --gpu-abort --script res://probe.gd
```

The probe compiles the production `sort.glsl` and runs the complete block/merge
sequence used by `SortEffects::sort_buffer()`. It checks ascending order, preservation
of key/index pairs, and untouched padding for 54 combinations of particle counts and
input patterns. A passing run exits with status 0 and prints
`SORT_PROBE_DONE cases=54 failures=0`.

The buffer includes allocated canary space up to the rounded dispatch capacity, so
even the original unsigned-underflow regression stays within allocated GPU memory.
Counts such as 1,025, 4,097, and 5,000 expose workgroups wholly beyond the valid data.
Power-of-two counts and partial final workgroups cover the unaffected boundaries.

To confirm the test detects an older shader, append
`-- --sort-source=/absolute/path/to/old-sort.glsl`. The original shader changes
canaries and exits with status 1. Do not reduce the buffer to the unpadded size when
testing a shader that may still contain the bug.
