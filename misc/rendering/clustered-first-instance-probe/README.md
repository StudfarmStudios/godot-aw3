# Forward Clustered firstInstance probe

Validates the guarded Forward Clustered `firstInstance` and push-constant reuse
path without changing draw order or creating new batches. Static geometry, three
camera poses, captured once render-pipeline compilation goes quiescent.

**The path under test only runs on WebGPU.** `API_TRAIT_FIRST_INSTANCE_INDEX` is
reported by the WebGPU driver alone; Vulkan, D3D12 and Metal fall through to the
base `RenderingDeviceDriver` default of 0, so on those drivers
`RenderForwardClustered::use_first_instance` is false and the old draw path runs
unchanged. Run both: WebGPU exercises the new path, and any other driver is a
regression check that the refactor left the old one alone.

## Coverage

- unique-mesh opaque singleton draws, the eligible case;
- lit singleton casters under a shadow-casting `DirectionalLight3D` — shadow
  passes are not excluded from the fast path, and the receiver puts the shadow
  in the captured image, so a wrong instance offset moves visible geometry
  rather than only disturbing an off-screen depth buffer;
- negative controls: `INSTANCE_ID` singleton draws, an existing same-mesh
  repeated-instance batch, ordered singleton transparent draws, `MultiMesh`, and
  point-size emulation.

The center pose also checks known-color samples, so a blank or displaced control
cannot produce a false exact match. There are no particles, random inputs,
`TIME`, animation, or TAA, and no script depends on wall time.

Not covered: particles, skeletal or blend-shape meshes, indirect draws,
depth-material passes, SDF passes. Those are excluded by the eligibility guards
rather than exercised here.

## Running it

Preserve the pre-change binary as the reference, build the candidate once, then
run two reference and two candidate captures serially per driver. Each run needs
a fixed 60 Hz timestep, Dummy audio and vsync disabled; rendering stays uncapped.
The fixture waits up to 45 s of wall time for three consecutive zero-pending
pipeline polls, then brackets three seconds with its counter markers.

```sh
PROBE=misc/rendering/clustered-first-instance-probe
for name in reference-a reference-b candidate-a candidate-b; do
  case $name in reference-*) BIN=/path/to/reference-godot ;; *) BIN=/path/to/candidate-godot ;; esac
  "$BIN" --path "$PROBE" --rendering-driver webgpu --rendering-method forward_plus \
    --audio-driver Dummy --disable-vsync --fixed-fps 60 \
    -- --output="/tmp/fi-$name"
done
python3 "$PROBE/compare.py" /tmp/fi-reference-a /tmp/fi-reference-b /tmp/fi-candidate-a /tmp/fi-candidate-b
```

Add a `--render-thread separate` candidate run; threaded submission is where a
stale push constant would surface first. Parse-check first with
`--headless --check-only --script res://probe.gd`.

## What must hold

Every run exits zero, logs `CLUSTERED_FIRST_INSTANCE_DONE`, and reports no
renderer, Dawn, validation, timeout or fallback errors. All three PNG hashes,
foreground counts, known-color samples and coverage metadata match exactly
across every run. On WebGPU the candidate's `[PERF]` line must additionally show
nonzero `FI/f` and a lower `PC/f` at an unchanged `draws/f`; on drivers without
the trait `FI/f` stays zero and `PC/f` is unchanged, which is the point.
