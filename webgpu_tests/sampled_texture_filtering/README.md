# Float32 exact fetch and filtering contracts

The local RenderingDevice fixture runs **72 GPU checks**: twelve compute cases with base and type-specialized pipelines, two real graphics draws whose shared binding filters in one stage and fetches in the other, and four cases reusing a uniform set across distinct shader layouts.

```sh
python3 webgpu_tests/sampled_texture_filtering/run_native.py /absolute/path/to/engine \
  --tint-cli bin/tint_convert_cli --output /private/tmp/sampled-filtering
```

Normal, forced-fallback, omitted `Float32Filterable`, and combined modes run by default. R32F source textures include storage usage to prevent the separate upload-format downgrade from hiding this defect. A deliberately linear sampler is bound even to exact-fetch shaders.

Positive cases cover direct and nested-helper texel fetches, separate image/sampler bindings, dimensions and mip-level queries, default-pruned textures activated by specialization, and textures sharing bind group 3 with emulated push constants. The source texture must remain unchanged. Shared-set cases visit source/target/source pipelines for both R32F and RGBA16F, with each shader used as the creation layout. They verify restored exact-fetch data and original linear samplers. Actual filtered R32F on a device without its optional feature deliberately retains the existing blank fallback; that one case checks layout compatibility, not filtering fidelity.

Filtering countercases use universally filterable RGBA16F texels `[0, 1]` and require the linear midpoint `0.5`. They cover direct/helper sampling; a type specialization whose default variant only fetches but whose later variant filters; a filtered binding absent from the default module; and both vertex/fragment stage unions. Treating every float texture or sampler as unfilterable would fail these countercases. Optional CLI checks verify all twelve defaults really have no overrides, the future-filter default has no sampling instruction, and pruned source bindings are absent.

The driver derives the layout contract from original SPIR-V, before specialization, and follows image/sampler provenance through helper parameters/returns and handle aliases. It unions requirements across stages. Exact fetches and dimensions can use `UnfilterableFloat`; actual sampling/gather and unknown uses retain filtering. This analysis runs only on devices without float32 filtering. Runtime uniform binding now retains R32F data when the declared contract is unfilterable. Retargeting a cached uniform set re-evaluates the original textures and samplers against the target contract instead of carrying over a blank texture or nearest-only sampler twin. There is no new GPU pass, snapshot or persisted-cache schema.

`results/baseline-macos-arm64.json` records engine SHA `d9508b4463617af707eff84a597a1138987357acfd975fe0a58c330066d1e85f`: normal/fallback **52/52**, omitted-filtering/combined **37/52**, all zero engine errors. The fifteen failures are numerical exact-fetch/dimension failures; the genuine filtering countercases already pass. `results/fetch-corrected-macos-arm64.json` records the first fetch correction on SHA `0d7e35d8d83399eb8884a1f43b45d44d7d291e1f03895d636ba98d4dd8b5d904`: all original **52/52** in all four modes, plus twelve translation proofs.

The expanded shared-set negative control (`results/reuse-baseline-macos-arm64.json`) gets **69/72** without float32 filtering on that binary: fetch-to-filter R32F generates a layout error, filtered-source R32F stays blank when fetched, and RGBA16F returns nearest value `1.0` instead of linear `0.5`. `results/corrected-macos-arm64.json` records SHA `e6d26dd46c9871a75b75e62b5cac42dd2bbc7b0fe727a67414cf7a56bc4fdfa9`: **72/72 in all four modes**, twelve translation proofs, zero engine errors and clean exits. All three shared-set regressions are corrected.

This is native Dawn/Metal evidence on Apple M1 Ultra, not browser or Firefox/Windows/D3D12 coverage.

`results/operand-corrected-macos-arm64.json` repeats **72/72 in all four modes and twelve translation proofs**, with zero errors and clean exits, on final SHA `413b6443bc377c8bf83f06c2344b36f1c4525d3b6b16bf387c70f7ea1e54562d`. The conservative unknown-use scan now relies on SPIRV-Tools ID operand metadata: literal instruction numbers, composite indices, switch cases and debug lines cannot accidentally request filtering. The dedicated `sampled_texture_literals` fixture records those negative controls.
