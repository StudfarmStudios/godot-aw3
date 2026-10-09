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
passes 192/192 checks on macOS arm64 WebGPU. The candidate browser results below
are separate from this saved native baseline.
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
including all-black output and wrong dimensions.

Verified on macOS arm64 with Chrome 155.0.8059.39 and Firefox 155.0.1:

| Runtime / fixture | Browser and mode | Result |
| --- | --- | --- |
| Existing release template baseline / original fixture | Chrome, normal | 192/192, all 12 phases, no runtime errors, exit 0 and post-exit gate passed. |
| Optimized candidate `0f0d368de9563536b5e55909a4c8e7f29540840e` / original fixture | Chrome, normal | 192/192, actual isolated WebGPU Forward+, no runtime errors, exit 0 and post-exit gate passed. |
| Same candidate / original fixture | Chrome, `--fallback` | 192/192, actual isolated WebGPU Forward+, float32-filterable omission confirmed, no runtime errors, exit 0 and post-exit gate passed. |
| Deployed baseline `20f7c82ba6a502e39a6218729060272c574faf21` and candidate / original fixture | Firefox, normal | Both fail at phase 0: all eight colored tiles fail, all eight empty positions pass. No logged runtime/GPU errors; completion and exit gates were not reached. |
| Same baseline and candidate / private continuous-rendering diagnostic | Firefox, normal | Same phase-0 failure on both. Continuous rendering alone is insufficient to resolve it. |

All four Firefox captures are byte-identical opaque-black 96x64 images. The private
diagnostic changed only `RenderingServer.render_loop_enabled = false` to `true`;
phase order, camera, materials, dimensions, two fixed forced settling frames and
pixel/error/exit gates stayed unchanged. It was exported once using the saved
native baseline editor and the identical pack was used for both runtimes. Added
automatic frames were the sole intentional behavior change. The original fixture
and its failures remain intact. No Firefox constrained-feature run followed these
normal-mode failures. This neither establishes an introduced candidate regression
nor provides Firefox rendering acceptance. Visibility/presentation/capture causes
remain unresolved; no Windows or DirectX/D3D12 execution is covered.

Exact SHA-256 identities for the candidate and paired Firefox controls:

```text
candidate index.wasm 5237007e43918e87b9a2b78c8b3a1d768a0dd9a269aa494c84a31db0a2849154
candidate index.js   e3d0167c38624b2b000ce993551497e0a35d8dae29994bff4f3bcc8713de45ce
Firefox baseline index.wasm fa0cefa479b611ddba97f18ad568126ead8d8449656f4dcc6c0894a6ea7d7b1b
Firefox baseline index.js   d76f1875ea01d26e47735982764335dfc9ca815492248291621d76954737ea9a
shared original HTML 38ca0c42c05c9ab43b8e1654761a7c2ceff19c7f38fd24839455f31c8e5b56bc
original fixture PCK 83bf371b3509e7a159948fa334e2225ae85ca05508e09b811d3220a044e50796
continuous diagnostic PCK 9197e76ae7713c7f96c703bb44bdad99ea7f8eca9cd57b41d1250ac0122695ff
all four Firefox PNGs 7bfdad2341592313a5606e000c998871e6047e57d8fed3143f3d4430b0c12a4c
```

Raw candidate Chrome records are preserved in
`/private/tmp/aw3-dynamic-bind-group-browser-current/result.json` (the Chrome record
passes; the combined run remains failed due to its initial Firefox launch timeout)
and `/private/tmp/aw3-dynamic-bind-group-browser-current-fallback/result.json`.
Original Firefox records are in
`/private/tmp/aw3-dynamic-bind-group-browser-{baseline-firefox-01,current-firefox-02}/result.json`.
The private diagnostic's source diff, editor/export hashes, paired results and
cleanup record are in `/private/tmp/aw3-firefox-continuous-diagnostic-20261009/`;
`outcome.json` preserves both failures. No pixel thresholds or acceptance gates
were relaxed; the diagnostic used one run per runtime.
