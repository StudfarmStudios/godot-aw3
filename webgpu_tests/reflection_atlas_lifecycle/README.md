# Reflection atlas lifecycle

This small native Forward+ scene renders a lit sphere with one reflection probe,
then deletes its scene and exits. The runner exercises two cases:

- `once`: 24 rendered frames using `UPDATE_ONCE`, followed by teardown.
- `switch`: the same initial frames, then eight `UPDATE_ALWAYS` frames before
  teardown. Changing update mode recreates the atlas for real-time filtering.

Both cases read back the 160×120 viewport and render three teardown frames. They
exercise renderer resource ownership through actual scene rendering, without
SSAO, SSIL, SDFGI, SSR, DOF, particles, or temporal upscaling.

```sh
python3 webgpu_tests/reflection_atlas_lifecycle/run_native.py \
  --engine /absolute/path/to/godot --driver metal \
  --output /tmp/reflection-atlas-lifecycle
```

The runner copies the project to the output directory, bounds each process to
90 seconds, records the engine/fixture hashes, and saves both logs and
`results.json`. Use `--driver webgpu`, `vulkan`, or `d3d12` for another available
backend. A real rendering window is required; do not use the headless dummy
renderer. Completion markers alone cannot pass: nonzero exit, timeout, missing
markers, warnings, validation errors, and resource leaks all fail the gate.
The viewport PNG in Godot's user directory is diagnostic, not an image-quality
assertion.

## Recorded native regression

[The four-run result](results/metal-macos-arm64.json) uses Apple M1 Ultra Metal 4.0.
The committed project and script are byte-identical to the privately executed
fixture. Before the fix, the ordinary case leaked seven textures; switching
leaked fourteen. The diagnostic identifies one 256×256, six-layer color cubemap
and six dependent views per atlas allocation. After the fix, both cases exit
cleanly with no warnings, errors, or leaked RIDs.

| Frozen editor SHA256 prefix | Once | Switch |
| --- | --- | --- |
| `ab2b1f0ba03b` (diagnostic, before fix) | 7 leaked textures | 14 leaked textures |
| `862617c897f8` (fixed) | Pass | Pass |

The old cleanup omitted the color cubemap in both pinned comparison forks.
`LightStorage::_reflection_atlas_clear()` now frees that owner; RenderingDevice
recursively frees its views and dependent framebuffers. The diagnostic editor
adds logging only; no diagnostic instrumentation remains in production.
This evidence covers native Metal ownership. Acceptance on a rebuilt browser
artifact is tracked separately and is not inferred from these native runs.
