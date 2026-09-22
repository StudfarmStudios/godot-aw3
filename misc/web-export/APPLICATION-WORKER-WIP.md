# Browser application-Worker WebGPU — work in progress, does not build

Parked from the 70-bot optimization session (2026-09-21/22). **This branch does
not produce a working browser build.** It is kept so the design and the
Emscripten plumbing are not lost, not because it is close to done.

## What it tries to do

Native desktop gets most of its 70-bot headroom from `--render-thread separate`.
The browser cannot use that today: the WebGPU device and the canvas live in the
browser main thread's realm, and every emdawn call has to happen there. This
branch moves Godot's main loop — and the device request — into the application
Worker that `-sPROXY_TO_PTHREAD=1` already creates, so the renderer runs off the
browser main thread.

Pieces:

- `library_godot_webgpu_worker.js` — requests the adapter/device in the calling
  Worker's realm and hands it to `RenderingContextDriverWebGPU`. Deliberately
  *not* proxied to the browser main thread.
- `web_main.cpp` — splits `godot_web_main` so the device request can complete
  before `Main::setup`, driven by the Worker's event loop via
  `emscripten_exit_with_live_runtime()` rather than Asyncify. A private
  `--godot-application-worker-webgpu` argv marker requests it; the C++ entry
  strips the marker.
- `engine.js` — appends that marker and skips the main-thread device request
  when the template was linked with `proxy_to_pthread`.
- `detect.py` — `PROXY_TO_PTHREAD` can only transfer `Module.canvas` to the
  Worker when OffscreenCanvas support is linked; Emscripten's transfer registry
  lives in `$GL` even on this WebGPU-only path.
- `emscripten_helpers.py` / `SCsub` — plumb `proxy_to_pthread` into the engine
  JS substitution, and run Substfile *before* the closure compiler rather
  than instead of it.
- `wasm.sh` — `APPLICATION_WORKER=1` adds `proxy_to_pthread=yes`.

## Evidence so far

An isolated browser probe (`temp/cpu-throughput-20260921/wasm-render-worker-probe`)
passed cleanly in Chrome: worker-local adapter/device request and emdawn import,
transferred OffscreenCanvas at 320x180 then reconfigured to 256x144, a
submitted/read-back 64x64 clear matching its expected FNV-1a hash, zero GPU
errors, worker `requestAnimationFrame` available, and a nonblocking join on
shutdown. That proves the *browser primitives*, not Godot integration.

## Why it is parked

The full engine template export does not link. The last run
(`temp/cpu-throughput-20260921/export-appworker-probe-v2.log`) failed twice over:

1. The workspace-local `.emscripten-cache` sysroot had a broken header search
   order — `<cerrno>`/`<cctype>`/`<cwctype>` could not find libc++'s headers,
   and `math_funcs.h` failed to parse as a consequence.
2. Independently, Tint rejected four shaders: `tonemap_mobile` subpass variants
   (`textureLoad` on `input_attachment<f32>` with a sample index),
   `screen_space_reflection_filter` (storage image write with no format
   qualifier), and `sdfgi_debug_probes` (vertex entry point with no declared
   position).

Nothing here has been verified against actual Godot rendering, input, resize,
or shutdown in a browser.

## To pick this up

1. Rebuild the local Emscripten cache from scratch rather than cloning the
   installed one, and confirm the sysroot header order.
2. Decide whether the four Tint failures are pre-existing on this template
   configuration or specific to `proxy_to_pthread` — check against a plain
   `webgpu=yes` template first.
3. Only then export a C# scene and verify render, input, resize and clean exit
   in a browser before this is worth a PR.
