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

## The integration bugs

The first two are about canvas ownership; the rest are about which realm code
runs in. None of them show up without `proxy_to_pthread`:

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

3. **`ReferenceError: window is not defined`, then `No interface 'AwBridge'
   registered`** — `godot_js_eval` had no `__proxy`, so it ran in the Worker,
   where there is no `window`. Every `godot_js_wrapper_*` function around it is
   already `__proxy: 'sync'` and runs on the browser main thread, so even an
   eval that avoided `window` would have defined its globals in the wrong realm
   for `get_interface()` to find them. `godot_js_eval` is now proxied like its
   neighbours. The heap is shared, so its pointer arguments stay valid, and on
   an ordinary build this already is the main thread, which makes it a no-op.

4. **UI laid out for a 300x150 window** — `godot_js_display_window_size_get`
   read `canvas.width`/`canvas.height` on the main thread. After the transfer
   those stop tracking the bitmap and keep reporting the value held at transfer
   time, which for a canvas with no width/height attributes is the HTML default
   of 300x150. The same stale readback scaled pointer coordinates in
   `library_godot_input.js`, so clicks landed in the wrong place. Both now go
   through `GodotConfig.canvasSize()`, which asks Emscripten for the
   authoritative size when the canvas has been transferred and reads the element
   directly when it has not.

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

### Assault Wing itself

The real game also builds and runs this way. It boots to
`WebGPU 1.0 - Forward+`, loads the `menu_battle` arena, starts the menu backdrop
battle, builds MainMenu/LoadoutMenu/ConfigMenu, renders the main menu correctly
sized, and logs **no errors**. Hovering two different menu entries by fraction of
the canvas highlights the entry under the cursor, which is what exercises the
pointer-coordinate scaling above.

Exporting the game needs one project-level fix: `prepare` writes a
`GodotAw3WasmEntry.cs` entry stub, and AW3 already carries its own `Program.cs`
stub for the same purpose, so the publish fails with `CS8802: Only one
compilation unit can have top-level statements`. Delete one of the two.
(`wasm.sh` surfaces the CS8802 line itself, so this diagnoses quickly.)

### Startup

A build with the harvested shader caches installed and the packs split reaches
the menu in **6.1 s** from a cold browser profile, against **35.5 s** for the
same build without them. The long black screen before the menu on an
unharvested build is shader compilation, not anything specific to this mode: the
ordinary template measures 33.9 s cold and 4.5 s warm against 35.5 s and 5.3 s
here.

The harvest itself runs fine in the application Worker — the game's own
`?shader-precompile` coverage cycled the menus and two arenas inside it and
produced a 7.5 MB WGSL seed plus 204 ShaderRD caches.

### Gameplay

Played hands-on by Jaakko on the split-pack, harvested-shader build and reported
working. That is a person playing it rather than an automated check, so treat it
as "the mode is not fundamentally broken for gameplay" rather than as coverage.

## Not verified

- **That it is faster.** No measurement has been taken. The whole premise is
  that freeing the browser main thread helps, and that is still an assumption
  here. Cold start came out within ~1 s of the ordinary template either way, so
  if there is a win it is in frame pacing during play, which is where it should
  be measured.
- **Subsystem detail.** Nothing has been deliberately exercised for audio,
  networking, threaded physics or particles, nor for the rest of the
  main-thread-proxied JS surface (fullscreen, pointer lock, drag-and-drop, the
  virtual keyboard). Hands-on play covers some of that incidentally and none of
  it rigorously.
- **Shader coverage** was harvested from the menus plus `spacejunk_mayhem_2` and
  `spacejunk_ctf_2` only; anything outside that still compiles on demand.
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
