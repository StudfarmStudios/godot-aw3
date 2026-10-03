# Deferred shader lifecycle probe

Run with a real GPU from the engine checkout:

```sh
bin/godot.macos.editor.arm64.mono \
  --path misc/native-webgpu/shader-lifecycle-probe \
  --rendering-driver webgpu --rendering-method mobile --audio-driver Dummy --verbose
```

The probe frees a never-used shader. It must not produce an `initializing shader 'unused_lifecycle_probe'`
log entry. It then dispatches a compute shader with a uniform set created before
the pipeline, and again with the pipeline created first. Both GPU readbacks must
print `SHADER_LIFECYCLE_PROBE PASS` with value 42, and the process must exit 0.
The asynchronous readbacks also allow exporting this probe for browser WebGPU.
Run the adjacent lightmap probe for graphics pipeline and lightmap coverage.
