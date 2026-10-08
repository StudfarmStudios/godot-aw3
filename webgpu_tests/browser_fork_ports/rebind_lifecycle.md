# Bind-group-layout cache-key lifetime regression

`project/rebind_lifecycle.gd` keeps one source uniform set alive while creating,
dispatching, and freeing 64 compatible target shaders. Alternating target shaders
use an exact texel fetch or filtered sample. With float32 filtering omitted,
these produce distinct WebGPU layout contracts even though their Godot uniform
shapes match. Six completed frames between target lifetimes allow deferred
RenderingDevice destruction to run.

Each dispatch compares actual GPU sample values with the expected result and
writes one green or red cell. The browser harness checks all 64 cell centers on
a 512×32 strip before advancing `BROWSER_REBIND_READY`, then validates exact
created/retired/dispatch counts in `BROWSER_REBIND_RESULT`. Render callbacks defer
signal emission to the main thread. The browser path never requests synchronous
GPU readback. The existing font, Canvas SDF, SSR, and DOF phases follow unchanged.

The defect was a borrowed `WGPUBindGroupLayout` C pointer used as the rebind-cache
key. Emdawn's bind group retains the JavaScript layout but does not retain that C
wrapper. Freeing the target shader could recycle the wrapper address and select
an incompatible old bind group. The fix retains each inserted key and releases
it with its cache entry; ordinary source-layout and cache-hit paths are unchanged.

The old threaded template (`b1c5969aa35661be4fcfb5d0876c84a28ee6e41e42c0a78f35afa24599968c57`,
exported with native engine `413b6443bc377c8bf83f06c2344b36f1c4525d3b6b16bf387c70f7ea1e54562d`)
reproduced the failure on macOS with float32 filtering omitted:

- Chrome cold launch passed all 64 green cells. Its warm launch rejected an
  incompatible bind-group layout during the next lifetime sequence.
- Firefox cold launch rejected a Filtering sampler layout receiving a
  NonFiltering sampler layout during the lifetime sequence.

This is a discriminating browser negative control; passing native Dawn alone
would miss the C-wrapper lifetime defect. The fixed native engine
`59ecacbe71a4a99e4645d992a263c5e6bf13f3b10ea330548e98702cacf23c54` passed all 64 GPU cells,
resource counts, and cleanup with `--render-thread separate` and float32 filtering
omitted. The fixed nonthreaded template also passed all 64 cells and lifetime
counts on Chrome 154.0.8037.98 and Firefox 155.0.1, on cold and warm launches in
both normal and omitted-filtering modes (eight runs, 512 cells). These complete
browser runs still fail a separate Emscripten `runtimeKeepalivePop` shutdown
assertion; the evidence preserves that failure instead of claiming an overall
pass. Fixed threaded coverage remains pending. No Firefox/Windows/D3D12 result is
implied. Compact identities and results are in
`results/rebind-lifecycle-controls.json`.

Native smoke command:

```sh
/absolute/engine --path webgpu_tests/browser_fork_ports/project \
  --rendering-method forward_plus --rendering-driver webgpu \
  --render-thread separate --disable-vsync -- \
  --rebind-native-only --webgpu-no-float32-filterable
```
