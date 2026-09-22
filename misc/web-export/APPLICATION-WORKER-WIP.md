# Browser application-Worker WebGPU

Runs Godot's main loop — and the WebGPU device — inside the application Worker
that `-sPROXY_TO_PTHREAD=1` creates, so the browser main thread is left free.
Native desktop gets most of its 70-bot headroom from `--render-thread separate`;
the browser cannot use that, because the WebGPU device and the canvas live in
the browser main thread's realm and every emdawn call has to happen there. This
moves the whole loop instead.

Build it with `APPLICATION_WORKER=1 misc/web-export/wasm.sh export <game>`,
which adds `proxy_to_pthread=yes` to the template flags.

## Pieces

- `platform/web/js/libs/library_godot_webgpu_worker.js` — requests the
  adapter/device in the calling Worker's realm and hands it to
  `RenderingContextDriverWebGPU`. Deliberately *not* proxied to the browser main
  thread.
- `platform/web/web_main.cpp` — splits `godot_web_main` so the device request
  can complete before `Main::setup`, driven by the Worker's event loop via
  `emscripten_exit_with_live_runtime()` rather than Asyncify. A private
  `--godot-application-worker-webgpu` argv marker requests it; the C++ entry
  strips the marker before `Main::setup` sees it.
- `platform/web/js/engine/engine.js` — appends that marker, skips the
  main-thread device request, and hands the canvas to `Module.canvas`.
- `platform/web/js/libs/library_godot_display.js` — resizes a transferred canvas
  through Emscripten instead of assigning `width`/`height`.
- `platform/web/detect.py` — `PROXY_TO_PTHREAD` can only transfer
  `Module.canvas` to the Worker when OffscreenCanvas support is linked;
  Emscripten's transfer registry lives in `$GL` even on this WebGPU-only path.
- `platform/web/emscripten_helpers.py` / `SCsub` — plumb `proxy_to_pthread` into
  the engine JS substitution, and run Substfile *before* the closure compiler
  rather than instead of it.

## The two integration bugs

Both are about canvas ownership, and neither shows up without
`proxy_to_pthread`:

1. **`pthread_create: could not find canvas with ID "#canvas" to transfer to
   thread!`** — Emscripten transfers `Module.canvas` to the proxied main thread
   and refuses to start without it, but Godot never sets that field. The object
   `Godot()` is constructed with comes from `Config.getModuleConfig()`, which has
   no canvas; the canvas is resolved later, by `Config.getGodotConfig()`, and
   only ever reaches Godot's own `GodotConfig`. `engine.js` now assigns
   `me.rtenv['canvas']` after that call and before `callMain`.

2. **`InvalidStateError: Cannot resize canvas after call to
   transferControlToOffscreen()`** — `GodotDisplayScreen.updateSize()` runs on
   the browser main thread (`godot_js_display_size_update__proxy: 'sync'`) and
   assigned `canvas.width`/`canvas.height`, which the main thread no longer
   owns. It now calls Emscripten's `setCanvasElementSize()`, which writes the
   shared size block and forwards the resize to the owning thread. CSS sizing
   stays with the DOM element and is still set directly. Because the element's
   `width`/`height` stop tracking the bitmap after a transfer, `applied_size`
   stands in for that readback so the resize is not re-issued every frame. When
   the canvas has *not* been transferred the old direct assignment is kept
   verbatim, so the ordinary web build takes the path it always has.

## Verified

`misc/../appworker-godot-probe` (a source-only C# scene, kept outside the engine
tree) in Chrome, three consecutive clean runs plus one after the final edit:

```text
[APPWORKER_PROBE] PASS frames=1189 signal=1 async=3 resize=2 input=2
                  renderer=WebGPU Device same_thread=True
```

That covers: `WebGPU 1.0 - Forward+` reported from the Worker-local device, the
three visual oracles rendered (checked against a screenshot), a generated C#
signal callback, three `ToSignal` async continuations, two programmatic resizes
(640x360 -> 512x288 -> 640x360), two real browser input events reaching C#
(mouse button and key), every managed callback on one thread, and a clean exit.

One transient warning per run, at the first resize:
`WebGPU: surface texture (W x H) differs from configured (w x h) - using actual
size`. The cross-thread canvas resize is asynchronous by construction, so the
surface can lag the configured size for a frame; the driver already handles it
and the warning does not repeat.

## Not verified

- **Any real game.** Only the smoke probe has run. Audio, networking, threaded
  physics, particles and the rest of the main-thread-proxied JS surface
  (fullscreen, pointer lock, drag-and-drop, the virtual keyboard) are untouched
  by these fixes and have never run in this mode. The resize path broke this
  way; others plausibly do too.
- **That it is faster.** No measurement has been taken. The whole premise is
  that freeing the browser main thread helps, and that is still an assumption
  here.
- **The ordinary (non-`proxy_to_pthread`) web template** has not been rebuilt
  since the display change. That path is unchanged by construction — it keeps
  the same two assignments behind `if (!transferred)` — but it has not been run.

## Notes

- Do not reuse the same HTML canvas for a second `Engine` start: Emscripten
  marks a canvas permanently transferred after `transferControlToOffscreen()`.
  Reload the page or create a new canvas.
- Build the template with the emscripten SDK's own cache. A copy-on-write clone
  of it has all the libc++ wrapper headers but an include ordering that makes
  every `<cstddef>`/`<cmath>`/`<cstring>` fail to find them — which is what
  stopped this work the first time round.
