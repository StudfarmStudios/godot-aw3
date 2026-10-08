# SPIR-V versions and resource semantics

Run the production preprocessing and Tint wrapper against compiler-generated
SPIR-V 1.0, 1.3, 1.4 and 1.5. Both original and preprocessed modules must pass
`spirv-val`. The corpus includes atomic buffers containing matrices, opaque
texture helper parameters, logical aggregate copies, both local-array stores and
actual `OpVariable` initializers, readonly vertex storage with helper calls,
fragment atomics, signed/unsigned integer images, and nonzero-mip integer fetches.
Real vertex storage writes must fail; qualifying them as readonly is not enough.

```sh
python3 webgpu_tests/tint_translation/run_translation.py \
  --tint bin/tint_convert_cli --output /tmp/tint-corpus
python3 webgpu_tests/tint_translation/run_operand_guards.py \
  --tint bin/tint_convert_cli --corpus /tmp/tint-corpus --output /tmp/tint-guards
python3 webgpu_tests/tint_translation/run_gpu.py /path/to/godot \
  --corpus /tmp/tint-corpus --output /tmp/tint-gpu
```

`--baseline /path/to/old/tint_convert_cli` records prior translation failures.
The GPU runner checks numerical buffer values and texture bytes, rejecting
validation errors, missing checks, timeouts and abnormal exits. Integer inputs
include the high bit, so signed and unsigned extension differ. The sampled
texture's first mip contains unrelated values, so accidentally dropping `Lod`
cannot pass. Translation alone is not GPU correctness or Firefox/D3D12 evidence.

SPIR-V 1.4 integer image flags need a narrow fix: preserve `Lod` and `Sample`,
and accept `SignExtend`/`ZeroExtend` only when they match the 32-bit texel type
represented by WGSL. Other image semantics fail before Tint's operand parser.
The guard fixture validates two legal SPIR-V modules, then requires clean
rejection of unsigned-result sign extension and volatile image access. These are
not equivalent to dropping every optional image operand. See the
[SPIR-V image operand definitions](https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html#_image_operands).

The initial 36-case corpus already handles actual initialized-array operands;
the other fork's extra array splitting pass is unnecessary for those cases.
Our base also already traverses matrix/vector members in Tint atomic lowering.
Do not import nonfinite approximation, generic subgroup emulation, blanket image
operand/decorations stripping, or aggressive output-removing DCE as a bundle.
Existing depth markers, specialization, sampler aliasing and dead-resource
handling remain in place.

Recorded native results: **52/52 translation checks, 2/2 rejection guards and
32/32 numerical GPU checks in each normal/forced-fallback mode**. The earlier
engine without the image-operand parser fix aborts on the same GPU fixture
(signal 6). Results under `results/` include executable identities. These are
Dawn/Metal results on an Apple M1 Ultra; no Windows/D3D12 claim follows.
