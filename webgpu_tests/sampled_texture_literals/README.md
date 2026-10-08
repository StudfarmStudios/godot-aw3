# Sampled-texture literal collisions

Four validated SPIR-V modules deliberately use sampled-image result ID **40** and an unrelated literal **40**: GLSL `FMax`'s extended instruction number, an `OpCompositeExtract` index, an `OpSwitch` case and an `OpLine` line number. Each fetches `0.25` from a storage-capable R32F texture into a readback buffer. A linear sampler is deliberately supplied. Twelve checks verify pipelines, numerical results and unchanged source texels.

```sh
python3 webgpu_tests/sampled_texture_literals/run_native.py /absolute/path/to/engine --output /private/tmp/sampled-literals
```

The runner requires `spirv-as`, `spirv-val` and `spirv-dis` on PATH. It generates text and binary modules in the output directory, preserves numeric IDs, validates Vulkan 1.1 legality and checks the exact collision before each four-mode GPU matrix. It rejects engine errors, leaked GPU resources, incomplete runs and incorrect values. The separate `sampled_texture_filtering` fixture preserves actual-filtering, stage-union, helper and future-specialization guards.

`results/baseline-macos-arm64.json` records SHA `e6d26dd46c9871a75b75e62b5cac42dd2bbc7b0fe727a67414cf7a56bc4fdfa9`: normal and forced storage fallbacks pass **12/12**, while omitted float32 filtering and combined omissions pass **8/12**. All four outputs silently become zero in those latter modes; engine logs contain no errors. The same collision in the real SSR HiZ shader makes mip 1 and every later level zero even though mip 0 and normals are correct.

The correction uses SPIRV-Tools' grammar-defined ID operands in conservative descriptor-use analysis. Literals cannot alias IDs; unfamiliar actual handle uses still retain filtering, and parse failures retain the original filtered contract. Native devices supporting float32 filtering skip this analysis. `results/corrected-macos-arm64.json` records SHA `413b6443bc377c8bf83f06c2344b36f1c4525d3b6b16bf387c70f7ea1e54562d`: **12/12 in all four modes**, clean exits, no engine errors or leaked resources.

These are native Dawn/Metal tests on Apple M1 Ultra, not Firefox/Windows/D3D12 evidence.
