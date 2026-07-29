# platform/sdl — Godot platform port for KMS/DRM devices

A custom Godot platform port (per the official [custom platform ports](https://docs.godotengine.org/en/4.4/contributing/development/core_and_modules/custom_platform_ports.html)
docs) that replaces the X11/Wayland windowing of the stock Linux platform
with **SDL3**. SDL picks the best available video driver at runtime —
`wayland`, `x11`, or **`kmsdrm`** — so export templates built with it run on
devices that have no display server at all, only KMS+DRM (e.g. embedded
arm64 boxes booting straight into the game).

Everything lives in this folder and is selected with `scons platform=sdl`.
**No engine source outside `platform/sdl/` is modified** — the port only
consumes existing engine code (`drivers/sdl/joypad_sdl.cpp`,
`thirdparty/glad`), so it survives rebases onto upstream Godot.

## What the port provides

| Area | Implementation |
|---|---|
| Display / window | `DisplayServerSDL` — single fullscreen-capable window on SDL3 |
| Rendering | Vulkan (RenderingDevice, via `SDL_Vulkan_*`, incl. `VK_KHR_display` under kmsdrm), OpenGL 3.3, OpenGL ES 3.0 (via `SDL_GL_*`/EGL) |
| Keyboard / mouse / touch | SDL events → Godot `InputEvent`s (`key_mapping_sdl`) |
| Joypads | Godot's own SDL3 joypad driver (`drivers/sdl/joypad_sdl.cpp`), reused as-is — rumble, hotplug, mapping DB included |
| Audio | `AudioDriverSDL` on SDL3 audio (auto-selects pipewire / pulseaudio / alsa) |
| OS layer | `OS_SDL` (`OS_Unix` + XDG paths, crash handler, embedded PCK support) — reports `get_name() == "Linux"` and the `linuxbsd` feature tag, so exports/scripts behave like a normal Linux build |
| .NET / C# | Standard `module_mono_enabled=yes` template build; exports use the normal `linux-arm64` / `linux-x64` RIDs |

Not supported (not meaningful on an embedded target): multiple windows,
subwindows, IME, TTS, native dialogs, system fonts (bundle fonts in the
project).

## Building templates

Two scripts, both keeping their intermediates in the git-ignored `tmp/`:

```sh
# 1) Static SDL3 with the kmsdrm backend (see script header for -dev packages)
platform/sdl/build-sdl3.sh

# 2) Godot export template from this tree, with .NET support
platform/sdl/build-template.sh
```

`build-template.sh` is only a wrapper around scons; the equivalent direct
invocation is

```sh
PKG_CONFIG_PATH=tmp/sdl3-prefix-<arch>/lib/pkgconfig \
scons platform=sdl target=template_release arch=arm64 \
      static_sdl=yes module_mono_enabled=yes production=yes
```

The easiest way to get an **arm64** template is to run both scripts natively
on arm64 — on the device itself, an arm64 VM, or
`docker run --platform linux/arm64 -v "$PWD:/w" -w /w ubuntu:24.04`.
Cross-compiling from x86_64 works too (`ARCH=arm64`, needs
`g++-aarch64-linux-gnu` plus an arm64 SDL3 — multiarch or sysroot).

Knobs are documented in each script's header (`ARCH`, `TARGET`, `WITH_MONO`,
`SDL3_PREFIX`, ...). For a debug template, build with `TARGET=template_debug`.

Because the port lives in the engine tree, the template is always built from
whatever this fork's checkout is — keep it on the same branch/tag the game's
editor build came from (`config/features` in `gameclient/project.godot`).

## Exporting the game

1. In the Godot editor, use the regular **Linux** export preset.
2. Set **Architecture** to `arm64`.
3. Under **Custom Template → Release**, point at the built binary
   (`bin/godot.sdl.template_release.arm64.mono`).
4. Export as usual. C# publishing picks the `linux-arm64` RID automatically;
   the device does not need .NET installed (self-contained publish).

The engine version of editor and template must match.

## Running on the device

The game must be started from a console/VT with nothing else holding DRM
master (no compositor, no other fullscreen app).

- Permissions: the user needs access to `/dev/dri/*` and `/dev/input/*` —
  typically groups `video`, `render`, `input` (or run via systemd/seatd).
- SDL picks `kmsdrm` automatically when `DISPLAY`/`WAYLAND_DISPLAY` are
  unset; force it with `SDL_VIDEO_DRIVER=kmsdrm` if needed.
- Renderer: AW3 defaults to Forward+ (Vulkan). On GPUs without a Vulkan
  driver (or without `VK_KHR_display`), use the compatibility renderer:

  ```sh
  ./AssaultWing.arm64 --rendering-method gl_compatibility --rendering-driver opengl3_es
  ```

  (Or bake it in with a `platform`-specific project settings override.)
- Diagnostics: add `--verbose` — the port logs the chosen SDL video driver,
  GL/Vulkan device, and audio backend at startup.

## Layout

```
detect.py            SCons platform config (arch validation, SDL3 via
                     pkg-config, GL/Vulkan defines, GLAD wiring)
SCsub                Sources + GLAD loaders + the shared SDL joypad driver
godot_sdl.cpp        main() entry (pck section, Main::setup/start loop)
os_sdl.*             OS_Unix subclass (paths, crash handler, feature tags)
display_server_sdl.* DisplayServer on SDL3 (window, events, GL/Vulkan init)
key_mapping_sdl.*    SDL scancode/keycode → Godot Key translation
audio_driver_sdl.*   AudioDriver on SDL3 audio streams
rendering_context_driver_vulkan_sdl.*  Vulkan surface via SDL_Vulkan
crash_handler_sdl.*  glibc backtrace handler (from the linuxbsd platform)
build-sdl3.sh        Static SDL3 (kmsdrm) build
build-template.sh    Template build wrapper around scons
```

## Maintenance notes

- `detect.py` is a trimmed copy of `platform/linuxbsd/detect.py`. When
  rebasing this fork onto a newer Godot, diff the two: display-server / OS
  virtuals and the linuxbsd SCons options occasionally change between minor
  versions and may need matching updates here.
- `detect.py` forces `builtin_sdl=no`: the SDL copy vendored in
  `thirdparty/sdl` is input-only (no video/audio) and cannot back this port.
  The full SDL3 from `build-sdl3.sh` provides input for the joypad driver
  as well.
- Event-queue contract: `JoypadSDL::process_events()` consumes the whole SDL
  queue via `SDL_PollEvent`, so `DisplayServerSDL::process_events()` first
  drains all non-joystick event ranges with `SDL_PeepEvents`, then hands the
  rest to the joypad driver. Keep that ordering if you touch the event loop.

The concept-level write-up (why the port exists, device constraints) lives in
the AW3 repository under `docs/gameclient/kmsdrm-linux.md`.
