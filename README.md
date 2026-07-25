# Godot Engine — Assault Wing 3 fork

Godot **4.7.1** with the two things AW3 needs on the web and the official engine
does not have:

- **C# ahead-of-time compiled to WebAssembly.** Godot cannot export C# to the
  web at all; this can, and the gameplay code is compiled rather than
  interpreted (~45-52 fps against ~28-30 for the interpreter in AW3).
- **A WebGPU rendering backend**, so the web build is not limited to WebGL2 and
  the Compatibility renderer.

Upstream Godot is otherwise unchanged; see [`GODOT_README.md`](GODOT_README.md).

## Where the pieces come from

| Piece | Source |
|---|---|
| Static-linked Mono for web | [ComplexRobot/godot](https://github.com/ComplexRobot/godot) `dotnet/mono-static-linking` — upstream draft [godotengine/godot#106125](https://github.com/godotengine/godot/pull/106125) |
| AW3's web/.NET fixes | this fork, commit "Web/.NET export fixes for AW3" |
| WebGPU backend | [dwalter/godotwebgpu](https://github.com/dwalter/godotwebgpu) `webgpu-4.6.2` @ `f329e39`, imported onto 4.7.1 |

The WebGPU work was written against 4.6.2, and Godot's 4.6 release branch is not
an ancestor of 4.7.1, so it is carried here as an import of that branch's diff
rather than as a merge. To re-sync with dwalter upstream, diff their branch
against its 4.6.2 base again and re-apply.

## Branches

- `aw3/web-mono-aot` — 4.7.1 + mono static linking + AW3's web/.NET fixes. This
  is the configuration AW3 ships today.
- `aw3/webgpu` — the above plus the WebGPU backend.

## Building

```sh
# Editor (macOS)
scons platform=macos target=editor module_mono_enabled=yes \
      accesskit=no angle=no vulkan_sdk_path=$(brew --prefix molten-vk)
./bin/godot.macos.editor.arm64.mono --headless --generate-mono-glue modules/mono/glue
python3 modules/mono/build_scripts/build_assemblies.py \
      --godot-output-dir=./bin --push-nupkgs-local /tmp/godot-nuget

# Web template. mono_aot_dir points at a game's AOT objects (left behind by a
# first export) and links them into the template - see the AW3 docs.
scons platform=web target=template_release module_mono_enabled=yes webgpu=yes \
      stack_size=32768 default_pthread_stack_size=32768 initial_memory=256 \
      mono_aot_dir=<abs path>/gameclient/.godot/mono/temp/obj/ExportRelease/browser-wasm/wasm/for-publish
```

The AOT pipeline, why each fix exists, and the browser-testing recipe are
documented in the AW3 repository under `docs/gameclient/web-csharp-export.md`.
The WebGPU driver has its own notes in [`drivers/webgpu/README.md`](drivers/webgpu/README.md).
