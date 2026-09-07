# Godot Engine — Assault Wing 3 fork

Godot **4.7.1** with the things AW3 needs and the official engine does not have:

- **C# ahead-of-time compiled to WebAssembly.** Godot cannot export C# to the
  web at all; this can, and the gameplay code is compiled rather than
  interpreted (~45-52 fps against ~28-30 for the interpreter in AW3).
- **A WebGPU rendering backend**, so the web build is not limited to WebGL2 and
  the Compatibility renderer.
- **An SDL3 platform port** ([`platform/sdl`](platform/sdl/README.md)), so
  export templates run on Linux devices with no display server — only KMS+DRM
  (embedded arm64 boxes that boot straight into the game).

Upstream Godot is otherwise unchanged; see [`GODOT_README.md`](GODOT_README.md).

## Where the pieces come from

| Piece | Source |
|---|---|
| Static-linked Mono for web | [ComplexRobot/godot](https://github.com/ComplexRobot/godot) `dotnet/mono-static-linking` — upstream draft [godotengine/godot#106125](https://github.com/godotengine/godot/pull/106125) |
| AW3's web/.NET fixes | this fork, commit "Web/.NET export fixes for AW3" |
| WebGPU backend | [dwalter/godotwebgpu](https://github.com/dwalter/godotwebgpu) `webgpu-4.6.2` @ `f329e39`, imported onto 4.7.1 and then expanded for Forward+ and other more highend rendering features |
| SDL platform port | this fork, written for AW3 against 4.7 (previously carried in the AW3 repo as `tools/godot-sdl-platform`) |

The WebGPU work was written against 4.6.2, and Godot's 4.6 release branch is not
an ancestor of 4.7.1, so it is carried here as an import of that branch's diff
rather than as a merge. To re-sync with dwalter upstream, diff their branch
against its 4.6.2 base again and re-apply.

## Branch

`aw-web-export` is the only branch and the default. It carries 4.7.1 + the
static-linked Mono web export + AW3's .NET fixes + the WebGPU backend + the SDL
port. (The earlier `aw3/web-mono-aot` and `aw3/webgpu` branches were folded
into it and no longer exist.)

## Adding web support to a C# game

`misc/web-export/wasm.sh` turns a Godot 4.7 C# project into a browser build:
gameplay C# AOT-compiled to WebAssembly, threads on, rendering through WebGPU.
It is non-interactive and idempotent, so a person or an agent can run it end
to end:

```sh
git clone -b aw-web-export https://github.com/StudfarmStudios/godot-aw3 && cd godot-aw3
misc/web-export/wasm.sh all   /path/to/game      # the folder with project.godot
misc/web-export/wasm.sh serve /path/to/game      # http://127.0.0.1:8080/ with COOP/COEP headers
```

`all` is these four, which also run on their own:

| subcommand | what it does | when to re-run |
|---|---|---|
| `toolchain` | installs emsdk 4.0.20 and an arm64/x64 .NET 9 SDK with the `wasm-tools` workload under `~/.godot-aw3` (Homebrew on macOS for scons/glslang/molten-vk; apt hints on Linux) | once per machine |
| `engine` | builds this fork's editor, regenerates the C# glue and pushes the fork's `GodotSharp` NuGet packages to `bin/GodotSharp/Tools/nupkgs`, and builds the bootstrap web template | when the fork moves (it notices `modules/mono` commits newer than the assemblies) |
| `prepare <game>` | writes `nuget.config` (source mapping so `Godot.*` comes from the fork, not nuget.org), a generated `godot-aw3-web.props` plus one `<Import>` line in the csproj, an entry-point stub, a `.sln` if none exists, `renderer/rendering_method.web` in `project.godot`, and a `Web` export preset pointing at the template | once per game, or to change `AOT_MODE` |
| `export <game>` | pass 1 exports (the publish AOT-compiles the C# and leaves `.o` files), pass 2 relinks the template against them, then copies `godot.wasm`/`godot.js` over the export | after every C# change |

The two passes exist because the AOT images are linked into the **engine**
template, not into the game's pck, so the template is game-specific. `export`
refuses to continue when the publish left no fresh object, when scons did not
report `linking N AOT-compiled assemblies`, or when the template zip was not
rewritten — each of those otherwise ships the previous build's code with no
message. `doctor [game]` prints the state of everything above, including a
stale-GodotSharp check and where the cached NuGet package came from.

Knobs, all environment variables: `AOT_MODE` (`LLVMOnlyInterp` by default —
methods the AOT compiler cannot produce run on the interpreter; `LLVMOnly`
aborts on them instead and is what AW3 ships after a full coverage pass),
`RENDERING_METHOD` (`forward_plus`, falls back to `mobile` on adapters with
fewer than 48 sampled textures per stage; either selects WebGPU), `ENGINE_DIR`,
`EMSDK_DIR`, `DOTNET_DIR`, `CSPROJ`, `PRESET`, `JOBS`, `FORCE=1`.

Expect the first `engine` run to take from twenty minutes to an hour depending
on the machine; a later `export` is a few minutes (publish, then a relink).
The serve step matters: threads need `SharedArrayBuffer`, which browsers grant
only to cross-origin isolated pages, so a plain file server shows a blank page.

Things the game has to live with on the web, each of which fails without
naming itself — the long form with every reason is AW3's
`docs/gameclient/web-csharp-export.md`:

- A P/Invoke of your own must not return a struct by value or carry floating
  point in its signature (`WASM0001` in the publish log; `export` stops on it).
- `OS.GetCmdlineUserArgs()` is empty: the shell passes args without `--`, so
  read `OS.GetCmdlineArgs()` and set them via `"args"` in `index.html`.
- `System.Net.Http.HttpClient` never sends (no .NET JS host); use Godot's
  `HttpClient`.
- `ResourceLoader.LoadThreadedRequest` never completes: loading creates GPU
  resources and WebGPU calls must stay on the thread that created the device.
  Load on the main thread and spread it over frames.
- Culture-sensitive string calls abort (no ICU); the props set
  `InvariantGlobalization`, so use ordinal comparisons.
- A black screen with nothing printed means the template and the assemblies
  disagree: run `doctor`, then `engine` (rebuilds stale GodotSharp and purges
  the NuGet cache) and `export` again.

## Building by hand

```sh
# Editor (macOS)
scons platform=macos target=editor module_mono_enabled=yes \
      accesskit=no angle=no vulkan_sdk_path=$(brew --prefix molten-vk)
./bin/godot.macos.editor.arm64.mono --headless --generate-mono-glue modules/mono/glue
python3 modules/mono/build_scripts/build_assemblies.py \
      --godot-output-dir=./bin --push-nupkgs-local ./bin/GodotSharp/Tools/nupkgs

# Web template. mono_aot_dir points at a game's AOT objects (left behind by a
# first export) and links them into the template; omit it for the bootstrap.
# Bootstrap and relink must use the same flags or scons rebuilds everything.
scons platform=web target=template_release module_mono_enabled=yes webgpu=yes \
      stack_size=32768 default_pthread_stack_size=32768 initial_memory=256 \
      optimize=speed lto=thin \
      mono_aot_dir=<abs path>/<game>/.godot/mono/temp/obj/ExportRelease/browser-wasm/wasm/for-publish

# Native macOS WebGPU (Dawn on Metal) for editor or template: add
#   webgpu=yes dawn_sdk_path=<Dawn CMake install prefix>
# and run with --rendering-driver webgpu. Dawn build: AW3 docs/gameclient/native-webgpu.md.

# KMS/DRM (arm64 device) template. Needs a static SDL3 first; both steps are
# wrapped by the scripts in platform/sdl - see that README.
platform/sdl/build-sdl3.sh
ARCH=arm64 platform/sdl/build-template.sh
```

The AOT pipeline, why each fix exists, and the browser-testing recipe are
documented in the AW3 repository under `docs/gameclient/web-csharp-export.md`.
The WebGPU driver has its own notes in [`drivers/webgpu/README.md`](drivers/webgpu/README.md),
the SDL platform port in [`platform/sdl/README.md`](platform/sdl/README.md).
