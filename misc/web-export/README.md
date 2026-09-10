# Local C# WebAssembly exports

`wasm.sh` installs the local toolchain, builds the fork, prepares a C# project,
exports it, and serves it. Run `bash misc/web-export/wasm.sh help` for commands
and environment settings. Use it for generic Godot C# projects; project-specific
release orchestration belongs in the consuming repository.

## LLVM PGO helpers

These tools consume the complete AOT output from a release export. They do not
select managed methods, change trimming, or discard unvisited game content.
Use Python 3.10+ and the same activated Emscripten SDK for all variants.

```sh
python3 misc/web-export/prepare-pgo-sdk.py --emscripten-dir "$EMSDK/upstream/emscripten"
python3 misc/web-export/pgo-aot.py baseline --aot-dir "$INPUTS" --output "$OUT/aot-baseline"
python3 misc/web-export/pgo-aot.py generate --aot-dir "$INPUTS" --output "$OUT/aot-generate"
# Run a project-specific coverage/gameplay harness against the instrumented build.
"$EMSDK/upstream/bin/llvm-profdata" merge "$OUT"/*.profraw -o "$OUT/merged.profdata"
python3 misc/web-export/pgo-aot.py use --aot-dir "$INPUTS" --output "$OUT/aot-use" \
  --profile "$OUT/merged.profdata"
```

`INPUTS` is a frozen copy of a successful export's
`.godot/mono/temp/obj/ExportRelease/browser-wasm/wasm/for-publish` directory.
Keep its bitcode, registration tables, and matching exported packs unchanged
between variants. The helper verifies the complete bitcode/object module set,
requires a separate empty output directory, and writes compiler options, input
and output hashes, intrinsic translations, and profile provenance to
`pgo-build.json`. Stale control-flow profiles are compiler errors.

`prepare-pgo-sdk.py` is an opt-in, idempotent Emscripten 4.0.20 compatibility
patch for LLVM profile metadata symbols containing dots. It backs up
`tools/shared.py`, changes only their JavaScript identifiers, and refuses an
unrecognized SDK implementation. It is unnecessary for ordinary release AOT.

Link each AOT directory into the matching engine variant with SCons:
`wasm_pgo=off|generate|use`, `mono_aot_dir=/absolute/aot-directory`, and, for
`use`, `wasm_pgo_profile=/absolute/merged.profdata`. Use separate
`extra_suffix` values for training and use. Serialize builds in an engine
checkout; generated files and ZIP staging paths are shared. Only the generate
variant exports LLVM's profile-writing functions. Never distribute it.

The game owns representative training, browser automation, shader harvesting,
validation, and deployment. AW3's one-command native pipeline is documented in
[its release guide](https://github.com/StudfarmStudios/aw3/blob/main/docs/gameclient/local-web-release.md).
