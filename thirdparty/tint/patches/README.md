# Tint Patches for Godot WebGPU

These patches modify the vendored Tint source for Godot's WebGPU backend.
They are applied on top of clean upstream Tint extracted via `extract_tint.sh`.

## Applying

From the repository root:

```bash
for p in thirdparty/tint/patches/*.patch; do
    patch -p1 < "$p"
done
```

## Patch Summary

| Patch | Files | Group | Description |
|-------|-------|-------|-------------|
| 0001 | validate.cc | UBO layout | `SetSkipBlockLayout(true)` + improved error messages |
| 0002 | validator.h, validator.cc, reader.cc | Spec constants | `kAllowStructMemberSizeMismatch` capability |
| 0003 | decompose_strided_array.cc | Spec constants | Skip padding when stride < element size |
| 0004 | shader_io.cc | Point size | Accept non-constant `point_size` stores |
| 0005 | ir_to_program.cc | Spec constants | `@size` emission guard + capability |
| 0006 | parse_num.cc | Vendoring | Replace `absl::from_chars` with `std::from_chars` |
| 0007 | parse_num.cc | macOS | Use locale-explicit float parsing below the macOS 26 deployment target |
| 0008 | parser.cc, texture.cc, atomics.cc, reader.cc | SPIR-V 1.4 | Accept resource interfaces and matching integer image extension operands |

## Logical Groups

**Group A — UBO Layout (0001)**: Godot uses C++ struct packing for uniform buffers,
not std140/std430. Always necessary.

**Group B — Specialization Constants (0002, 0003, 0005)**: Godot's specialization
constants can change struct/array sizes at runtime, creating size mismatches that
Tint's IR validator and lowering passes don't expect. These patches relax validation
and prevent invalid WGSL output.

**Group C — Point Size (0004)**: Godot shaders pass through `gl_PointSize` with
non-constant values. Tint strips point_size during lowering but validates the stored
value first. This patch relaxes that validation. Could potentially be moved to
`spirv_preprocess.cpp` or proposed upstream.

**Group D — Vendoring (0006)**: Replaces Abseil dependency with C++17 `std::from_chars`.
Always necessary when vendoring without Abseil.

**Group E — macOS compatibility (0007)**: Apple's libc++ declares floating-point
`std::from_chars` unavailable below macOS 26. Use `strtof_l` / `strtod_l` with
the C locale while retaining `std::from_chars` for integers and other platforms.

**Group F — SPIR-V resource interfaces (0008)**: SPIR-V 1.4 includes resource
variables in entry-point interfaces. Accept the newer module environment, avoid
creating addressable phony uses for opaque handles, and remove interface-only
uses when lowering textures and atomic buffers. Retain phony instructions through
final IR validation. Adapted from patches 0007–0009 and 0011–0012 in
[Shane-Gadsby/godotwebgpu at 470f89e](https://github.com/Shane-Gadsby/godotwebgpu/tree/470f89e78eece1c7a73285345e2ca39b8f8706ad/thirdparty/tint/patches).
The matrix/vector atomic traversal in their patch 0010 is already present in
our vendored Tint; it requires no additional change. The driver wrapper separately
changes vertex storage pointer types in Tint IR and validates the result, so real
vertex writes remain errors. See `webgpu_tests/tint_translation/`.
The additional parser change handles matching 32-bit `SignExtend`/`ZeroExtend`
image flags, preserves `Lod`/`Sample`, and rejects other operand semantics before
the operand parser. It does not import blanket image-operand stripping.

## Upstream Source

Tint is extracted from [Dawn](https://dawn.googlesource.com/dawn) using
`extract_tint.sh`. The patches were generated against upstream `main` and verified
to apply cleanly and produce identical output via round-trip testing.
