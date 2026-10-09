# Seeded sampled texture layout initialization

This focused CPU benchmark measures six production SSR compute variants: even
and odd HiZ, downsample, trace, roughness filtering, and resolve. It compares the
same engine with Float32Filterable enabled and deliberately omitted. The omitted
feature path performs conservative source-SPIR-V sampling analysis; the normal
feature path skips it.

Run only while other builds and GPU tests are idle:

```sh
python3 webgpu_tests/sampled_texture_layout_benchmark/run_native.py /absolute/engine \
  --output /private/tmp/layout-benchmark
```

Each of three process pairs alternates launch order. A process compiles the real
GLSL sources, creates resources, seeds existing stage-analysis/WGSL caches, and
performs three warmup creations per variant before collecting seven batches of
32 creations. Sources and prepared GLSL are hashed in the output manifest.

The intervals are reported separately:

- Fresh `shader_create_from_spirv`, including ordinary RenderingDevice reflection.
- `uniform_set_create` on each fresh shader, which triggers lazy driver layout
  initialization and, only with the feature omitted, sampled-texture analysis.
- `uniform_set_create` on an existing seeded shader, which reuses its layout.

Resource destruction and three local-device submit/sync cycles occur outside
these intervals. No compute pipelines are created or dispatched. Timing excludes
GLSL compilation, initial WGSL translation, GPU execution, and deferred frees.
There is no production timing instrumentation or additional source-analysis
cache. Valid RID creation, clean exit, clean validation logs, and actual feature
omission are required; a passing smoke run alone is not performance evidence.

The comparison includes capability-dependent layout and sampler differences, so
it does not isolate parser time or measure full application startup. Results are
specific to native CPU/Dawn on the recorded host, not browser/Wasm or Windows.
Measured on Apple M1 Ultra / macOS 26.5.2, native Dawn, binary
`59ecacbe71a4a99e4645d992a263c5e6bf13f3b10ea330548e98702cacf23c54`, during an exclusive
slot with other tests and builds idle. All six processes passed with zero errors;
8,064 fresh shader creations and 16,128 uniform creations were timed. Full batch
samples, paired medians, hashes, and source sizes are retained in
`results/native-macos-arm64.json`.

Fresh layout + first uniform creation, microseconds per creation:

| Production SSR variant | Filtering available | Filtering omitted | Paired median increase |
| --- | ---: | ---: | ---: |
| hiz | 20.1 | 45.1 | +25.4 |
| hiz_odd | 24.2 | 61.8 | +37.4 |
| downsample | 33.0 | 69.3 | +36.2 |
| trace | 122.0 | 404.8 | +283.5 |
| filter | 51.2 | 173.3 | +122.3 |
| resolve | 67.1 | 164.1 | +97.2 |

The fresh-layout interval is 2.1–3.4 times its normal-feature interval, with
25–284 microseconds additional work per sampled variant. Existing-layout uniform
creation adds only 0.09–0.44 microseconds; its ordinary 1.7–3.7 microsecond interval
remains small. Fresh shader creation before lazy layout initialization changes by
0.2–9.3 microseconds, indicating the added work is concentrated in layout setup.
These differences include layout/sampler choices as well as source analysis.

A cache could avoid repeated analysis of identical SPIR-V, but these six modules
add only about 0.60 ms in total when each is initialized once. This bounded
native sample does not establish a material application-startup regression or
justify a new cache by itself. Measure representative browser startup before
adding memory, synchronization, and cache-key complexity; do not extrapolate
these six shader variants across the entire engine shader inventory.
