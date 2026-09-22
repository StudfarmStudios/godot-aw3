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

## Separate render thread (`--render-thread separate` / `thread_model=2`)

On top of the application Worker, Godot's own render thread now works on the
web. It is a dedicated pthread, not a `WorkerThreadPool` task, because it has to
own three things that are bound to the realm of the Worker that creates them:
the WebGPU device (requested in that Worker, `library_godot_webgpu_worker.js`),
the canvas (re-transferred to it with `emscripten_pthread_attr_settransferredcanvases`
— Emscripten re-transfers a canvas the calling thread already owns), and the
`RenderingDevice`, which `DisplayServerWeb` therefore no longer creates in its
constructor: `has_deferred_rendering()` tells `RenderingServerDefault` to call
`deferred_rendering_initialize()` from the render thread once the device
exists, and `deferred_rendering_finalize()` there at `_thread_exit`. The thread
is never joined or exited: the device's JS callbacks may still fire in its
Worker afterwards, and one that ran after a `pthread_exit` (the thread's TLS
gone) wedged the malloc lock for every thread in the process. On the web a
process ends with its page, so `finish()` syncs the queue and detaches it.

The thread runs from its event loop, and where a frame is drawn matters more
than anything else here. A standalone test (`temp/finalize-20260922/present-lab`,
a canvas transferred main → Worker → Worker the way Emscripten does it, drawing
GPU-heavy frames) presents at 60 fps when the draw happens inside the Worker's
`requestAnimationFrame` callback and at **~5 fps** when the same draws are issued
from ordinary tasks — even with an idle animation-frame loop running alongside,
which then fires only ~12 times a second. With light frames the difference
disappears, which is why the first two versions of this thread (a semaphore wait
inside a task, then mailbox-driven drains plus a bare rAF loop) measured fine in
a test page and presented ~11 frames a second in the game. So:

- `draw()` queues a *frame marker* in front of every `_draw`. The marker asks
  `CommandQueueMT` to pause the flush after itself (`request_flush_pause()`);
  the remaining commands stay queued and the same thread's next `flush_all()`
  resumes them.
- Pushes wake the render thread through `Atomics.waitAsync` on a counter
  (`web_wake`, `emscripten_atomic_wait_async`), and the wake drains up to the
  marker: every `sync()`/`push_and_ret()` the game thread issues before its
  draw is answered within microseconds. Emscripten's own mailbox is not used
  for this — its notification is a `postMessage` routed through the browser
  main thread, and a busy main thread (proxied file reads, audio) turned into
  render-thread stalls.
- The thread's `requestAnimationFrame` callback resumes the paused flush, which
  runs `_draw` and whatever followed it up to the next marker. The game thread's
  next `sync()` therefore completes once per animation frame: the engine is
  paced by the display like every browser game, instead of drawing as fast as
  it can into a swap chain the browser never gets to show.

Two things that do not work: draining on `requestAnimationFrame` *alone* (the
game thread blocks on `sync()`/`push_and_ret()` several times a frame, each
waiting up to a frame — ~25 fps), and `emscripten_set_immediate_loop` (its
`postMessage` form is rejected by a `DedicatedWorkerGlobalScope`); the
game-thread loop uses `godot_js_immediate_loop`, a `MessageChannel` post, for
the same reason a `setTimeout(0)` loop is clamped to 4 ms once nested. Resource
creation off the render thread (`can_create_resources_async`) is disabled on a
threaded web renderer: the device does not exist in any other realm.

Canvas sizing is the recurring trap. After `transferControlToOffscreen()` only
the owning pthread may resize the bitmap, Emscripten's shared size block is the
only authoritative size, and the JS side reports each change once. Resizes are
therefore applied by the owner (`check_size_force_redraw()` forwards to the
render thread with `call_on_render_thread` when deferred), a change that lands
before the root window registered its callback is delivered late
(`rect_changed_pending`), and the size `setup_canvas` recorded during
construction is applied explicitly, because that first report is consumed
before the main loop exists. Symptom when any of this is missed: a 1920x1080
bitmap stretched over the page — larger HUD, missing widgets, elliptical fields.

### Audio: the cost of the application Worker

Profiling the game thread in a bot match showed 15% of its time asleep in
synchronous proxies to the browser main thread — almost all of it the sample
playback setters (`godot_audio_sample_update_pitch_scale`,
`set_volumes_linear`, `sample_start`, `sample_stop`), called once per
positional sound per frame, each a full round trip because the AudioContext
lives on the main thread. They return nothing and are fire-and-forget now: the
Worker-side entry copies the pointer arguments (all of them point at the
caller's temporaries) into heap memory and forwards through an `async` proxy
whose main-thread body frees them; proxied calls keep their order, and off a
pthread the body is called directly with the original pointers. The remaining
synchronous per-frame proxies are small and listed in the numbers below.

### Numbers

M1 Ultra, Chrome (native arm64) with `--disable-frame-rate-limit
--disable-gpu-vsync`, 3440x1280, `--demo --practice --bots=8
--arena=spacejunk_mayhem_2`, engine `--print-fps`, two runs each, interleaved:

| Build | Engine FPS |
| --- | ---: |
| Production (main thread, PGO) | 120.5 |
| Ordinary template, this engine (main thread) | 116.8 |
| Application Worker, no render thread | 95.7 before the audio change, 112.5 after |
| Application Worker, render thread | 169.4 before, **193.3** after; 182.1 / 207.1 drawing from rAF |

Those are engine frame rates. What the browser actually shows was measured
separately (`Page.screencast` frames per second, vsync on): the first render
thread presented **11 frames/s** while its engine ran 96 fps; drawing from the
animation-frame callback presents every frame — 60.0 presented at 60.0 engine
fps in the menu at 1000x613, 1500x863 and 1700x913, and 60.0 / 60.0 in a
warmed-up 8-bot match. The application Worker without the render thread
presents 57 at 57. A match's first ~15 s run at 1–19 fps on every build (pipeline
compilation); a probe that samples earlier than that measures warm-up, not the
design — two rounds of "stalls" were exactly that.

Cold start with harvested shaders and split packs: 9.2 s to the menu with the
render thread, against 6.1 s without it (the extra is the second device request
and the deferred GPU bring-up; not yet investigated).

Still synchronous per frame (share of the game thread, after the audio change):
`display_size_update` 0.95%, `sample_stream_is_registered` 0.79%,
`window_size_get` 0.67%, `touchscreen_is_available` 0.51%; in a match with the
render thread the game thread spends 6.4% of its time waiting on
`window_size_get` alone, and the browser main thread spends 25% of its time in
the audio glue's `setVolume`. The page's own
`requestAnimationFrame` cadence reads a steady ~14 Hz under any Worker build
with vsync disabled; unexplained, and it does not affect the game (which does
not run on that thread), but it makes page-rAF-based measurements meaningless
for these builds — use `--print-fps`.

### Not verified

- Gameplay under the render thread beyond menu, hover input and short demo
  matches. A HUD direction-arrow lag was reported by hand and is not yet
  reproduced or explained; `GetGlobalTransformInterpolated()` is scene-side
  and refreshed before `_Process`, so it is not a stale interpolation read.
- The engine's own `--max-fps` pacing is compiled out under `PROXY_TO_PTHREAD`.
  The game loop is paced by the render thread's animation frames instead (its
  per-frame `sync()` completes once per frame), so with vsync on it runs at the
  display rate and with the browser's vsync disabled it runs as fast as the
  compositor issues frames (the 182–207 fps above).
- A hidden tab stops a Worker's animation frames, so the game thread blocks in
  its next `sync()` until the tab is visible again — the same freeze the
  ordinary template has, whose whole loop runs from the page's rAF.
- One demo run (vsync on, 3440x1280) was found dead ~200 s in, at about the
  time a demo match ends: every thread blocked on the malloc lock, the game
  thread throwing `system_error` out of `condition_variable::wait`, a Mono
  thread asserting in `mono_threads_exit_gc_safe_region_internal`. That is the
  shape a JS exception leaves when it unwinds a wasm thread mid-frame (locks
  held, GC-safe region unbalanced); the exception itself was not captured
  (that run had no console log), and three later runs of 60–270 s with full
  `pageerror` capture stayed at 60 fps without an error. The render thread's
  rAF callback is a bare dynCall and the game thread's tick runs under
  `callUserCallback`; either rethrows to the Worker's `onerror`, so a repeat
  will show up as `worker sent an error!` on the page console.

The ordinary (non-`proxy_to_pthread`) template was rebuilt with every change
here and boots clean: `WebGPU 1.0 - Forward+`, menus built, no errors, a
1280x773 bitmap on an untransferred canvas.
