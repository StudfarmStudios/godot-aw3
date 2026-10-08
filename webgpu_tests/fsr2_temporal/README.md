# FSR2 temporal and exposure regression

This is a real Forward+ renderer fixture, using a 384×256 HDR viewport upscaled
from 192×128. It records 19 linear RGBA32F images per run and checks 90 properties:
foreground motion, newly uncovered background, abrupt color changes, an 80× HDR
luminance change, bright-to-dim auto-exposure adaptation, and resize/reset to
516×388. The input crosses six 64×64 SPD workgroups initially and twenty partial
workgroups after resize. Both internal dimensions remain greater than 64.

```sh
python3 webgpu_tests/fsr2_temporal/run_native.py /path/to/godot
```

By default the runner executes native Metal, native WebGPU and WebGPU with
`--webgpu-force-fallbacks`, twice each. Use `--modes native fallback` on a host
without Metal. Each run must finish every check without engine/validation errors
or timeouts and exit cleanly. PNGs are previews; comparison uses all RGB values in
the linear float images. Per-capture mean, 99th-percentile and maximum absolute
errors are recorded against the Metal reference. These reference differences are
diagnostic, not an assertion of visual parity. Repeated runs additionally must
have mean absolute error ≤0.003 and 99th percentile ≤0.03 for every capture.

Rendering is explicit (`force_draw` at 1/60 s, followed by `force_sync`) so an
occluded macOS window cannot pause the test. Warmup waits for zero pending
pipelines and stable pipeline-request totals, independently of expected pixels.
The compositor's deferred metadata publication is synchronized without drawing
an extra frame. After warmup the FSR context is reset, frame count is aligned to
the 32-frame jitter period, and captures follow a fixed draw sequence.

## Recorded results

On Apple M1 Ultra / macOS 26.5.2, corrected binary SHA-256
`8102c335e324ebf8c62512e26eb507a63ad63884c4eff1863962aa3cfc2aa09e`:

- All six runs pass 90/90 checks with zero engine errors and clean exit.
- All 19 captures are bit-exact between the two runs of each backend.
- Native WebGPU bright-to-dim mean red is 0.363246, versus Metal 0.363013.
  Forced fallback is 0.363244.

The previous binary (`46dc9ae5ce79ead485786b146e960ed19ea5e6c240475836f3a8be773aa90b62`)
produces mean red 0.069619 on WebGPU and fails the added analytic exposure oracle
(89/90 checks), without engine errors. Its original 87-check matrix passed twice
per backend with exact repeated pixels; the reference comparison exposed the
problem and motivated the three additional luminance checks.

| Capture | Previous WebGPU / Metal RGB MAE | Corrected WebGPU / Metal RGB MAE |
| --- | ---: | ---: |
| Bright-to-dim exposure | 0.293394 | 0.000553 |
| HDR checker, settled | 0.041020 | 0.041020 |
| Motion step 6 | 0.001308 | 0.001308 |
| Settled color change | 0.003300 | 0.003300 |
| First resized frame | 0.000006 | 0.000006 |

The exposure defect also reproduced with bilinear upscaling instead of FSR2,
which isolated it to the renderer's general luminance reduction. The companion
`luminance_reduction` fixture directly checks the production shader and proves
that restoring the old one-axis bounds predicate fails 20 GPU oracles. Correcting
the predicate adds no texture or dispatch.

The dim exposure oracle follows the configured adaptation: mean input 0.0275,
previous luminance 1, scale 0.4, speed 10 and fixed delta 1/60. After 32 frames the
expected mean is approximately
`0.0275 * 0.4 / (0.0275 + 0.9725 * (5/6)^32) = 0.362`.
A 0.30–0.42 bound allows spatial reconstruction and quantization differences while
rejecting the measured erroneous 0.0696. The bright mean must be 0.75–1.0 and the
settled HDR gain must be 70–90 for an 80× input change.

`results/` contains compact baseline, corrected and old-binary-oracle reports.
Raw images and logs are omitted. Timing recorded during concurrent GPU tests is
not a performance measurement.

## Limits and next fixtures

This demonstrates bounded scene correctness and repeated-run stability. It does
not establish FSR2 quality parity: the HDR checker still has RGB MAE 0.041 and
99th-percentile error 0.758 on values up to 4, concentrated around transitions;
individual moving-edge pixels can differ substantially. Native WebGPU here uses
Dawn's Metal backend. Firefox, Windows/D3D12, browser execution, multiview and real
game scenes remain separate requirements.

The next renderer feature matrix should cover CameraAttributesPractical near/far
DOF with focused and defocused objects, requested MSAA off/2×/4×/8× (checking the
actual supported sample count), hardware-depth and resolved-R32 depth inputs,
HDR/SDR, odd resize, and toggling DOF during a run. A compositor should inspect
resolved depth plus scene/velocity output. Compare edge spread and focus contrast
with native Metal rather than accepting only finite pixels. The current Forward+
post-transparent path already resolves MSAA depth before postprocessing; an
additional unconditional resolve should not be ported merely to make the fixture
pass. GI+MSAA and stereo require their own tests.
