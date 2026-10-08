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
Workers, then runs cold/warm loads in one isolated profile. Six phases wait for
engine pipeline work to settle, announce readiness, and stop until the browser
captures a screenshot and sends Space. Checks cover mask/LCD/MSDF font rendering,
SVG color modulation after adding a new glyph, Canvas SDF inside/outside sign,
SSR off/on reflected pixels, and near/focus/far DOF contrast. Browser font checks
prove visible updated glyphs; exact first-frame/upload ownership guarantees are
covered by the separate native font fixture.

No synchronous engine readback is assumed: the browser screenshots the displayed
canvas. The fixture's shader bake, runtime fingerprint, packaged seed load,
persisted WGSC v4 header/fingerprint and warm disk-cache load are checked. Results
include logs, screenshots and hashes of the supplied editor/template/export.
Observed Worker creation plus a known `proxy_to_pthread=yes` template establishes
the intended Worker test configuration; it is not timing evidence or a benchmark.

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
