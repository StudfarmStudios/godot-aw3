# Primitive mesh readback regression

Run with a rendered native engine, once per driver:

```sh
bin/godot.macos.editor.arm64.mono --path misc/rendering/primitive-mesh-probe --rendering-driver webgpu --audio-driver Dummy --script res://probe.gd
bin/godot.macos.editor.arm64.mono --path misc/rendering/primitive-mesh-probe --rendering-driver metal --audio-driver Dummy --script res://probe.gd
```

The first CPU read of a newly generated primitive must contain usable vertices
and indexed triangles. The old WebGPU path returned zero-filled buffers while
its asynchronous readback was pending; callers that cached that first result
permanently lost their geometry. Repeating the read can mask the failure.

The probe checks eight primitive types, isolation from caller mutations,
immediate property updates, preservation of earlier snapshots, flipped normals
and winding, and generated UV2. Failures produce a nonzero exit status. A
passing run prints `PRIMITIVE_MESH_PROBE_DONE checks=54 failures=0`.

PrimitiveMesh retains its final generated arrays on the CPU, before uploading
them. Reads duplicate array wrappers while their packed storage uses copy-on-write.
This avoids GPU readback on every renderer and refreshes alongside geometry
updates. It does not make GPU-computed buffers synchronously readable on WebGPU.
