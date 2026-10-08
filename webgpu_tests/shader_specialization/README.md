# Storage texture specialization regressions

The fixture uses the engine's real RenderingDevice, shader compiler, pipeline
specialization API, GPU dispatch and synchronous readback. It checks every texel
and component of 40 shaders, each with four dispatch phases and two readbacks:
320 numeric checks per capability mode.

```sh
python3 webgpu_tests/shader_specialization/run_native.py /path/to/godot \
  --tint-cli bin/tint_convert_cli
```

The default runs native WebGPU and `--webgpu-force-fallbacks`. The optional Tint
CLI check verifies all generated shaders actually exercise the intended
translation path; the recorded evidence includes it. Use separate output
directories for different runs. Logs, generated GLSL/SPIR-V and reports go to the
ignored `artifacts/` directory unless `--output` is specified.

## Matrix

- R32F, RG32F and R32UI: native read/write-capable formats, a format that requires
  splitting on the tested adapter, and integer sampled-shadow types.
- Explicit readonly, unqualified read/write and explicit writeonly source images.
- Ordinary WGSL overrides and a specialization constant used as an array length,
  which forces the SPIR-V specialization path.
- Default-active and default-inactive branches. The typed/default-inactive cases
  have no source-image declaration in the base WGSL; later specialization must
  activate it against the same pre-existing layout and uniform set.
- Additional typed/default-inactive RG32F read/write and R32UI readonly cases use
  three slices of 3D and 2D-array textures, exercising reserved shadow dimensions.

Phases run default values, enabled/count=3 twice, then disabled/count=2. They
verify that constants affect output, repeated read/write dispatches see preceding
GPU writes, readonly sources remain intact, and disabled branches stop updating
sources. Local rendering devices submit and synchronize before each readback;
expected pixels never drive a retry or readiness loop. A float tolerance of
0.00001 is used; all inputs and expected results are exactly representable here.

The runner rejects all engine/GPU errors, incomplete check counts, timeouts and
unexpected process exits. With `--tint-cli`, it also requires zero overrides in
typed cases, two overrides otherwise, and absence of the source binding exactly
when the typed default-inactive case should prune it. This guards against a
future optimizer change silently weakening the intended coverage.

## Implementation contract

Both base and SPIR-V-specialized modules now share storage-texture lowering.
Shaders with specialization constants derive a layout contract from the original
SPIR-V before freezing constants. NonWritable/NonReadable qualifiers, decoration
groups and variable/pointer/array type indirection determine access; access is
unioned across stages. Unqualified images conservatively retain read/write
access. Source types supply formats and dimensions even when a default module
prunes the declaration. Unsupported read/write formats reserve a write binding
and sampled shadow; unsupported readonly access becomes a sampled binding.

Supported formats retain direct read/write storage access. Explicitly writeonly
bindings remain writeonly and do not acquire snapshots. The common WGSL helper
also leaves supported declarations unchanged without copying their source text.
Snapshots retain the existing per-dispatch semantics; these tests do not claim
same-dispatch communication between shader invocations.

## Validation scope

The recorded host is Apple M1 Ultra / macOS 26.5.2, using native Dawn/Metal. These
are compute-pipeline tests, not browser, Firefox, Windows/D3D12 or graphics-stage
coverage. No timing from concurrent correctness runs is a performance result.

Graphics split images are explicitly rejected when reachable from vertex or
fragment stages: snapshot refresh exists at compute dispatch boundaries, and
accepting a graphics split would read an uninitialized shadow. Readonly images and
native supported read/write formats remain available. The separate actual-draw
fixture checks these boundaries:

```sh
python3 webgpu_tests/shader_specialization/run_graphics.py /path/to/godot
```

It verifies specialized readonly vertex and fragment draws in both modes, a native
R32F read/write fragment draw, and unused RG32F read/write declarations that must
not cause rejection. Three unsupported fragment cases must fail before drawing
with the precise compute-only diagnostic; unrelated GPU/engine errors fail the
runner. All positive draws check framebuffer pixels and source-image contents.

## Recorded evidence

On binary SHA-256
`d06206f6c8f66ecd6e8708d477c4ed07f2bb3227a835598c69122dfc7bf305ed`:

- 320/320 compute checks in native mode and 320/320 with forced fallbacks, no
  engine errors, clean process exits.
- 40/40 independent production-translator override/pruning assertions.
- All ten graphics cases pass: seven draws produce the expected pixels and three
  unsupported cases report only the intended guard and its propagated failures.

The earlier `8102c335e324ebf8c62512e26eb507a63ad63884c4eff1863962aa3cfc2aa09e`
binary fails the original 288-check 2D subset: 20 numeric failures in native mode
and 36 with forced fallbacks, with Dawn storage access/type mismatches. The
expanded negative control also hits that older binary's independently fixed
unused 3D/array image-dimension bug, so the saved core subset is the cleaner
specialization-specific comparison.

`results/` preserves concise binary hashes, failed baseline oracles, translated
shader source hashes, and final counts. Generated shader sources, raw logs and
images are not committed. Supported-path performance is preserved by construction;
this fixture does not measure a speedup.
