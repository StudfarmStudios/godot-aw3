# Candidate browser regressions

Run the actual installed Chrome and Firefox with fresh temporary profiles. The
runner does not force WebGPU, disable its sandbox, or substitute SwiftShader.
`probe.mjs` records each browser version, adapter limits, isolation and Worker
prerequisites before testing the engine. macOS results do **not** validate
Windows/D3D12 or Firefox's Windows backend.

Prepare the small fixture (Python `fontTools` required):

```sh
python3 webgpu_tests/browser_fork_ports/prepare_project.py --output /tmp/browser-fixture
python3 webgpu_tests/browser_fork_ports/export_candidate.py /path/to/editor \
  --template /path/to/exact/template.zip --project /tmp/browser-fixture \
  --output /tmp/browser-threaded --threads --bake --tint-cli /path/to/matching/tint_convert_cli
node webgpu_tests/browser_fork_ports/run_browser.mjs \
  --export=/tmp/browser-threaded/export --output=/tmp/browser-threaded-results \
  --node-modules=/path/to/project/package.json
```

The Node package anchor must resolve `puppeteer-core` (tested with 25.4.0) and
`pngjs`. It is explicit because these fixtures do not install or change the
workspace dependencies. Repeat export with a fresh output directory and the
non-threaded template, omitting `--threads`. `--bake` requires a native WebGPU
editor and matching CLI; it packages compact GDSC caches and a WGSC v4 sidecar.
The exporter copies the fixture, forces `.web=forward_plus` and the WebGPU driver,
uses the supplied custom template directly and fails on import/export errors.
It never modifies global export-template installations.

The browser server uses COOP/COEP, records real console errors and observed
Workers, then runs cold/warm loads in one isolated profile. A preceding lifecycle
gate verifies 64 green GPU oracle cells while target shaders are repeatedly
created and freed with a persistent source uniform set; CPU creation/retirement
counts must also match. Repeat with `--no-float32-filterable` to omit that engine
device feature and exercise differing target bind-group layouts. This does not
change browser preferences. Six visual phases then wait for
engine pipeline work to settle, announce readiness, and stop until the browser
captures a screenshot and sends Space. Checks cover mask/LCD/MSDF font rendering,
SVG color modulation after adding a new glyph, Canvas SDF inside/outside sign,
SSR off/on reflected pixels, and near/focus/far DOF contrast. Browser font checks
prove visible updated glyphs; exact first-frame/upload ownership guarantees are
covered by the separate native font fixture. Fonts load through exported resource
remaps and must contain both requested glyphs before the pixel test runs.

No synchronous engine readback is assumed: the browser screenshots the displayed
canvas. The fixture's shader bake, runtime fingerprint, packaged seed load,
persisted WGSC v4 header/fingerprint and warm disk-cache load are checked. Results
include logs, screenshots and hashes of the supplied editor/template/export.
Observed Worker creation plus a known `proxy_to_pthread=yes` template establishes
the intended Worker test configuration; it is not timing evidence or a benchmark.
After controlled engine quit, the runner requires exit code 0 and keeps the page
and error listeners alive for one additional second to catch late GPU callbacks.

Browser executable paths can be supplied with `--firefox-bin=/absolute/path/to/firefox`
and `--chrome-bin=/absolute/path/to/chrome`; macOS installations are the defaults. For the
local macOS run its installed updater interrupted the first launch; a temporary
copy of the installed Firefox app with `DisableAppUpdate` set only in that copy
avoids modifying the installed browser or the user's profile. No WebGPU prefs
are changed in either case. Chrome/Firefox are closed after testing and only
owned temporary profiles are removed.

`export_candidate.py` is also used by CI to export the general shader-coverage
fixture without baking, using the built template. The CI software/browser smoke
job and manual external demo diagnostics are separate from hardware evidence.

For a Windows hardware run, copy each complete exported output directory,
including its sibling `export-result.json`, to the Windows machine. No native
editor or shader translator is needed to run an already exported fixture. With
installed browsers and a package anchor resolving the dependencies above, run
these PowerShell commands, substituting the actual paths:

```powershell
node webgpu_tests/browser_fork_ports/probe.mjs --output=C:/results/gpu-capabilities --node-modules=C:/tests/package.json --chrome-bin="C:/Program Files/Google/Chrome/Application/chrome.exe" --firefox-bin="C:/Program Files/Mozilla Firefox/firefox.exe"
node webgpu_tests/browser_fork_ports/run_browser.mjs --export=C:/exports/threaded/export --output=C:/results/threaded --node-modules=C:/tests/package.json --chrome-bin="C:/Program Files/Google/Chrome/Application/chrome.exe" --firefox-bin="C:/Program Files/Mozilla Firefox/firefox.exe"
```

Repeat the second command for the non-threaded export and a new result directory.
Keep the probe JSON, complete engine/browser logs and screenshots together. Record
the Windows version/build, GPU model/driver and exact browser versions. Capture
Firefox's `about:support` graphics information from the same browser version with
a fresh profile and the same default settings, and save its text or screenshot
alongside the results. Record the WebGPU backend only if that evidence explicitly
identifies it; otherwise label it **unknown**. `navigator.gpu`, a successful draw,
and an adapter name alone do not establish D3D12. Do not force WebGPU preferences
or count a skipped/unsupported browser as a pass. Windows/D3D12 remains unverified
until that hardware run and its backend evidence exist.

Recorded macOS hardware evidence (Chrome 154 / Firefox 155):

- [Corrected threaded matrix](results/threaded-macos-arm64-3525.json): all eight
  runs pass across both browsers, normal/omitted float32 filtering and cold/warm
  loads. Each observes eight Workers and passes the same rendering, cache and
  delayed-shutdown checks as the non-threaded matrix below.
- [Corrected non-threaded matrix](results/nonthreaded-macos-arm64-3525.json): all
  eight runs pass across both browsers, normal/omitted float32 filtering and
  cold/warm loads. Every run passes the 64-cell lifetime oracle, six visual phases,
  matching packaged/persisted WGSC checks and exit 0 with a full second of late
  callback observation. Firefox also lacks float32 blending on this machine;
  its capability warning and the expected font-atlas format-conversion warnings
  are retained in the results.
- [Nonzero exit probe](results/nonthreaded-exit7-macos-arm64-3525.json): a private
  fixture requests `SceneTree.quit(7)` after 60 frames. Chrome and Firefox both
  report `onExit(7)` with no errors during the following second. The result
  includes the small private fixture's source and exact exported artifacts.
- [Threaded 59ec matrix](results/threaded-macos-arm64-59ec.json): all eight runs
  pass across both browsers, normal/omitted float32 filtering and cold/warm loads.
  This includes the 64-cell bind-group lifetime oracle, all six visual phases,
  matching WGSC identity/seed persistence, observed Workers and controlled exit 0.
- [Non-threaded shutdown control](results/nonthreaded-shutdown-negative-macos-arm64-59ec.json):
  rendering and cache checks pass, but forced runtime shutdown causes keepalive
  counter assertions after cleanup. These runs remain marked failed. The reduced
  capability run records runtime and shutdown errors separately; GPU validation
  errors are never ignored.
- [Natural-shutdown fence control](results/nonthreaded-fence-negative-macos-arm64-2c6d.json):
  the subsequent non-threaded build passes all cold rendering/cache checks in
  both browsers, then aborts in the fence callback's `free` before `onExit`.
  Multiple queue-work callbacks can retain one reused fence; this result remains
  failed and later matrix runs were stopped pending an ownership fix.

The corrected matrices use native editor `a3962882...`, translator/profile
`3525def0...`, threaded template `4000e673...` and non-threaded template
`ee654100...`. The historical 59ec snapshots
use editor `59ecacbe...` and profile `8b6f9216...`; full artifact hashes are in each
result file. Each result remains pinned to its tested export and is not relabeled
to match later builds. An earlier template also reproduces an incompatible
bind-group layout on Firefox cold and Chrome warm runs, documented in the
[lifetime regression](rebind_lifecycle.md).

The separate [Emscripten 4.0.11 release controls](results/emscripten-4.0.11-closure-controls-macos-arm64.json)
use the uploaded `e8ad329993` CI artifact, whose Wasm hash is `13275ca1...` and
profile remains `3525def0...`. Both stock browsers reject the original
Closure-compiled wrapper because it renames browser WebGPU properties. Adding
the reference fork's WebGPU externs fixes that boundary, then exposes a second
failure: a quoted internal `importJsDevice` call does not match its renamed
emdawn helper. A diagnostic copy with the rebuilt wrapper and that one emitted
module call corrected passes all 20 visual/cache checks and 64 lifetime cells
per browser, but times out awaiting controlled shutdown. These runs remain
**failed**; they do not establish final-source or complete 4.0.11 acceptance.
All six cold controls retain their original template hashes and errors. They
cover neither threading, warm loads, omitted capabilities nor performance.

The [Closure regression controls](results/closure-regression-controls.json)
record six public-wrapper cases and two actual compiler cases. Test the actual
separately compiled wrapper, then compile the production import body with the
installed emdawn helper and its browser externs:

```sh
GODOT_ENGINE_WRAPPER=/path/to/godot.web.template_release.wasm32.nothreads.engine.js \
  node --test platform/web/js/engine/webgpu-device.test.mjs
GODOT_CLOSURE_COMPILER=/path/to/emscripten/node_modules/.bin/google-closure-compiler \
  node --test platform/web/js/engine/webgpu-import.test.mjs
```

The import test locates the installed emdawn port under that Emscripten SDK's
`cache/ports/emdawnwebgpu`; `GODOT_EMDAWN_LIBRARY` can override its library path.
It proves the old quoted call fails after Closure and the corrected dot call
uses the same renamed helper. CI runs both gates after WebGPU builds and enables
Closure for the candidate browser smoke; a missing compiled wrapper is a failure.
