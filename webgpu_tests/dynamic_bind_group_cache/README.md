# Dynamic bind-group cache

The render driver may skip a non-push-constant dynamic bind only when the resolved
WebGPU group, offset count, and every dynamic offset match the current encoder's
state. Shader switches, new passes/subpasses, and ring-overflow restarts must
invalidate that cache. Push-constant paths retain their existing binding behavior.

Run the extracted production-code checks without building the engine:

```sh
python3 webgpu_tests/dynamic_bind_group_cache/run_state.py \
  --output /private/tmp/aw3-dynamic-bind-group-state
```

The test extracts the actual state fields/helper and all four render-binding
branches. Only WebGPU pointer handles and the API call are replaced by observable
test tokens/state. ASan/UBSan checks cover offset and offset-count changes, first/middle/last
positions in an eight-offset tuple, resolved-group and slot changes, static binds,
shader invalidation, merged/unmerged push constants, PC-to-non-PC transitions,
restart state replay, and new subpasses. The current code passes 65 assertions.
A controlled repeated-state sequence produces 20 binds instead of the baseline's
40 with the same resulting state; this is not an FPS measurement.

Negative controls reject an offset-blind cache and reproduce the baseline's stale
static binding after a new subpass encoder. The ring-overflow case models its
existing restore/invalidate contract; it does not allocate a real GPU ring.
`results/state-macos-arm64.json` records exact production source hashes and results.

Run the real renderer pixel checks with a built engine:

```sh
python3 webgpu_tests/dynamic_bind_group_cache/run_native.py /path/to/engine \
  --output /private/tmp/aw3-dynamic-bind-group-gpu
```

This creates a real Forward+ viewport using dynamic render-pass set 1/binding 2,
which ShaderRD marks dynamically. GDScript's raw RDShaderSPIRV interface does not
expose that metadata, so the fixture uses the production renderer. Eight separate
materials change color and transform over twelve states and switch between warmed
opaque/alpha shader pipelines. Each state uses two fixed completed frames so deferred transform propagation finishes before capture; it checks the complete 3x3 center of every
colored tile and the now-empty alternate position (192 checks). Pipeline readiness
uses pending counts and stable request counts; expected pixels never control
warmup. It runs with a separate render thread, explicit offscreen frames, a bounded
wall-clock timeout, and rejects engine/WebGPU validation errors.

The saved baseline (`8ef30015ed8eca8b87c9285a680a7d814982ae3f795593aa2ee43968046556d4`)
passes 192/192 checks on macOS arm64 WebGPU. The optimized binary rerun is pending.
This fixture verifies rendering, while the extracted test directly verifies tuple
comparison and call elimination. Neither proves a game FPS gain or Windows D3D12
coverage. The project can also be exported unchanged for browser validation.

For a browser, export this project with a threaded WebGPU template and
`html/canvas_resize_policy=0`. The shared `browser_fork_ports/export_candidate.py`
can make a private copy/export with `--threads --canvas-resize-policy 0`.
Then run:

```sh
node webgpu_tests/dynamic_bind_group_cache/pixel_checks.test.mjs
node webgpu_tests/dynamic_bind_group_cache/run_browser.mjs \
  --export=/private/tmp/fixture-export/export \
  --runtime=/private/tmp/candidate/web-baseline \
  --output=/private/tmp/dynamic-bind-group-browser-results \
  --node-modules=/path/to/package.json
```

The dependency package must resolve `puppeteer-core` and `pngjs`. The runner uses
installed Chrome and Firefox by default (`--browser=chrome` selects one), hardware
WebGPU, isolated profiles, and no browser validation suppression. `--fallback`
requests storage fallbacks plus omission of float32 filtering and checks that
omission was acknowledged. The optional runtime directory supplies only
`index.js`, `index.wasm`, and audio worklets; HTML and PCK always come from the
fixture export, with their hashes and runtime hashes recorded in the result.
The runtime WASM size is updated in the served configuration, not in saved files.

Browsers present each phase on a fixed 96x64 canvas, and the runner checks the same
192 color/vacated-position regions in screenshots before advancing with Space.
It requires the actual engine WebGPU/Forward+ banner, actual canvas/viewport and
PNG dimensions, isolated worker support, all twelve phases, no runtime/validation
errors, and exit code zero plus one second without delayed shutdown errors.
No synchronous GPU readback is used on Web. The screenshot oracle has 26 controls,
including all-black output and wrong dimensions. The existing release template baseline passes all 192 checks in Chrome155 on macOS arm64, with actual WebGPU, zero errors, and clean exit. The candidate optimized runtime and Firefox checks remain pending until that runtime is linked and tested.
