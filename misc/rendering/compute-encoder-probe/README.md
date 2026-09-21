# RenderingDevice compute encoder regression probe

This project checks the command and resource transitions affected by reusing a
native Metal compute encoder for independent RenderingDevice compute lists in
one render-graph dependency level. It is a correctness probe, not a benchmark.

From the engine checkout, run the native Metal build without an opt-in feature
flag (encoder reuse is expected to be the production default):

```sh
./bin/godot.macos.editor.arm64.mono --path misc/rendering/compute-encoder-probe --rendering-driver metal --audio-driver Dummy --gpu-abort --script res://probe.gd
```

Run the same API-level checks on native WebGPU with:

```sh
./bin/godot.macos.editor.arm64.mono --path misc/rendering/compute-encoder-probe --rendering-driver webgpu --audio-driver Dummy --gpu-abort --script res://probe.gd
```

A passing run exits with status 0 and prints:

```text
COMPUTE_ENCODER_PROBE_DONE failures=0 independent_lists=128
```

The probe submits one command graph containing:

- 128 mutually independent compute lists, alternating two pipelines and using
  a different storage buffer, uniform buffer, uniform set, and push constant in
  every list. Exact output and four canary words per list are checked.
- A tracked read/write chain on one storage buffer. Three dispatches are split
  by `compute_list_add_barrier()`, followed by another dependent logical list.
- A compute-write, partial `buffer_copy()`, compute-read/write sequence. Prefix
  and suffix canaries on both buffers prove that the blit boundary and offsets
  are honored.
- Separate texture-write and texture-read compute lists using an `R32_UINT`
  storage image. Both texture readback and a shader-produced buffer copy of the
  texels are checked exactly.

These cases exercise state rebinding while an encoder may remain open, tracked
dependencies that force later render-graph levels, and blit/group boundaries
that must close the encoder. They also run on WebGPU, where barriers are API
no-ops and resource ordering is provided by WebGPU itself. This probe creates a
local RenderingDevice and calls `compute_pipeline_create()` directly; that path
is synchronous on native WebGPU. It does not use `compute_pipeline_is_valid()`
as a readiness test (that method only checks RID ownership). Results are
retrieved with the asynchronous buffer and texture readback APIs in a second
local-device submission, because native WebGPU readback cannot be made
synchronous by `RenderingDevice.sync()` alone.

Run Metal API and GPU shader validation together with:

```sh
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 MTL_SHADER_VALIDATION_REPORT_TO_STDERR=1 \
./bin/godot.macos.editor.arm64.mono --path misc/rendering/compute-encoder-probe \
  --rendering-driver metal --audio-driver Dummy --gpu-validation --gpu-abort --script res://probe.gd
```

The corrected driver passes both validations, including storage-image writes.
The unmodified baseline reports missing `MTLResourceUsage` write declarations
for resources accessed through argument buffers; shader validation suppresses
those writes and the texture checks fail. The candidate declares the actual
compute resource usage in Barriers mode as well as HazardTracking mode.

One Metal path cannot be reached from this GDScript probe: growth of the 512 KiB
transient argument-buffer ring requires a dynamic persistent uniform/storage
buffer. `BUFFER_CREATION_DYNAMIC_PERSISTENT_BIT` is deliberately unavailable to
GDScript, and the RenderingDevice documentation exposes the corresponding
dynamic uniform types only for RIDs received from native code. Covering ring
growth needs a native RenderingDevice unit/integration test or a production
scene that already owns such a buffer. The many ordinary uniform sets here test
binding changes and residency calls, but ordinary sets use persistent argument
buffers and do not allocate from that transient ring.

The probe verifies GPU-visible results and canaries. It does not count native
encoders, inspect Metal residency declarations, prove performance improvement,
or replace deterministic visual testing of the renderer.
