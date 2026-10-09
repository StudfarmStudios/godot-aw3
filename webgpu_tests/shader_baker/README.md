# Native WebGPU shader baking and cache fallback

Use an editor build with `webgpu=yes` and run it with the WebGPU driver. The
initial export integration intentionally captures the active WebGPU renderer's
source defines. A Vulkan or Metal editor cannot yet regenerate the full browser
target profile and is rejected when WebGPU baking is requested.

```sh
python3 webgpu_tests/shader_baker/run_export.py /path/to/godot --output /tmp/webgpu-export
python3 webgpu_tests/shader_baker/run_export.py /path/to/godot --wgsl --wgsl-fallbacks --tint-cli /path/to/tint_convert_cli --output /tmp/webgpu-export-wgsl
python3 webgpu_tests/shader_baker/run_cache_fallback.py /path/to/godot --output /tmp/webgpu-cache
python3 webgpu_tests/shader_baker/run_cache_fallback.py /path/to/godot --placeholders --output /tmp/webgpu-placeholders
python3 webgpu_tests/shader_baker/run_wgsl_cache.py /path/to/godot --output /tmp/webgpu-wgsl-cache
python3 webgpu_tests/shader_baker/test_cache_identity.py
python3 webgpu_tests/shader_baker/test_cli_build.py
python3 webgpu_tests/shader_baker/test_tint_isolation.py
python3 webgpu_tests/shader_baker/test_precompile_failures.py
```

The export fixture generates a scene with mesh surface materials, overrides,
overlays, a next pass, a MultiMesh, a particle draw mesh, nested arrays and
dictionaries (including resource keys), and a StandardMaterial3D. Label3D and
Sprite3D exercise generated material collection. It imports and exports an
unencrypted PCK, verifies named-material collection and parses its GDSC files.
This does not require an export template because it uses `--export-pack`.
With `--wgsl`, it requires the optional WGSL seed, checks its header and records,
extracts the exported caches into a fresh project, verifies all seed records
load with source-SPIR-V binding metadata, and renders the red test mesh.
`--wgsl-fallbacks` additionally verifies exports with missing/stale CLI tools
and malformed batch output retain compact SPIR-V and omit invalid WGSL seeds.

The Web preset's `shader_baker/tint_cli` selects the host CLI, defaulting to
`tint_convert_cli` beside the editor executable. Its content fingerprint must
match the editor. Missing or stale tools leave compact SPIR-V baking available
and report why WGSL baking was skipped. Per-module failures, output limits and
cancellation produce an explicitly reported partial seed; missing entries still
use deferred runtime translation. The host CLI currently builds on POSIX hosts.
Its output is optional; the engine's compact shader container remains portable.

Before a cold build on a slow host, run `bash drivers/webgpu/tint_cli/build.sh`
from the repository root, then run the normal SCons build. This avoids starting
the native compiler's full worker pool alongside SCons' Wasm compiler jobs.
CI performs that prebuild as a separate step with a 30-minute deadline and fails
on compiler errors or timeout. SCons still checks the CLI's current source inputs
under its 600-second deadline; unchanged vendor objects are reused. This changes
build scheduling only, not the translator/profile identity or shader output.

The cache fixture creates an isolated project and uniquely named user directory.
It renders a red mesh and verifies pixels on every launch. It checks packaged
cache preference, fallback after invalid outer framing, missing variants,
invalid later containers, bounded inner counts, and source regeneration when
both caches are invalid. The placeholder mode enables TAA after initial frames
and targets the Forward+ advanced group, which fills existing placeholder RIDs.
Expected parser diagnostics are allowed only in explicitly corrupt-container
cases; unrelated errors fail the run. The output retains per-launch logs, JSON,
the temporary project, and the path to its uniquely named user cache.

The WGSL fixture verifies v4 translator identity, rejects legacy v2/v3 seeds,
checks disk regeneration, and rejects a whole bundled file if a later record is
truncated or corrupt. It deliberately rotates disk record hashes so a valid
bundled seed must win over conflicting WGSL. All launches verify rendered pixels.
Run without an unrelated `/tmp/wgsl_seed.bin`; the fixture refuses to change it.

GDSC stays at version 4 and the WebGPU shader container stays at version 1 with
lossless SMOL-V or raw SPIR-V. Shader creation remains deferred. Native Dawn
results do not establish Firefox/Windows or browser coverage.

The translator identity tests check real content hashing and build invalidation:
preprocessing, Tint, runtime code and profile edits invalidate the identity;
generated headers do not hash themselves; a driver-only edit does not force a
vendor rebuild; changed vendor headers invalidate the corresponding objects.

`target_profile.json` identifies the shared translator contract and conservative
WebGPU capabilities; it does not regenerate source defines from another live
driver. Native WebGPU source snapshots retain the renderer's actual setting and
capability defines in their SPIR-V hash and ShaderRD cache key. Different project
settings therefore miss safely rather than being treated as equivalent. This
does not establish browser adapter coverage for every native-baked variant.

The build table lists its intentionally excluded variants and fails on any
unexpected GLSL or Tint failure. Its recipes cover a curated built-in corpus;
the export snapshot additionally covers enabled live material variants. Failed
batches preserve the previous table, temporary workspaces are unique, and the
CLI isolates translation aborts and timeouts. Standalone tests simulate pipe,
fork, short-write, interrupted-write, malformed-protocol and compile failures.

Check seed metadata and concurrent cache use with:

```sh
python3 webgpu_tests/shader_baker/build_metadata_probe.py --output /tmp/metadata-oracle
python3 webgpu_tests/shader_baker/run_sidecar_metadata.py /path/to/frozen-editor \
  --tint-cli /path/to/matching/tint_convert_cli --probe /tmp/metadata-oracle/probe \
  --output /tmp/seed-metadata
python3 webgpu_tests/shader_baker/run_cache_threads.py /path/to/frozen-editor --output /tmp/cache-threads
```

Build the oracle after the matching CLI is built. It links only private copies
of existing objects, does not invoke SCons, and records their hashes. The export
wrapper saves each exact SPIR-V input, then every sidecar record is compared to
production pre-specialization metadata (including anisotropic sampler aliasing).
The fixture requires at least one alias change, so the prior unaliased seed
metadata fails this check. Image dimensions/depth/array/sample fields are also
compared. Runtime format/sample-type recovery remains outside the v1 wire fields.

The concurrency check creates four local WebGPU devices on worker threads,
verifies 160 distinct compute results and leaves the main renderer drawing so
timed disk flushes can overlap compilation. It is a stress check, not a
ThreadSanitizer proof. Cache locking protects shared maps, counter updates and
persistence; SPIR-V analysis, Tint and GPU calls run outside that cache lock.

The recorded macOS results use native editor SHA-256
`413b6443bc377c8bf83f06c2344b36f1c4525d3b6b16bf387c70f7ea1e54562d`
and translator/profile
`d375989c9e230ac4456d94d3da5b10bb7471c941585ac53e69f20695e1cd7aa0`:

- [WGSC identity/corruption/precedence](results/native-wgsl-v4-macos-arm64.json): 11/11.
- [Live placeholder fallback](results/native-placeholders-macos-arm64.json): 14/14.
- [Exported metadata](results/native-sidecar-metadata-macos-arm64.json):
  1,095/1,095 records match runtime analysis, including 26 anisotropic alias changes.
- [Sidecar export](results/native-export-wgsl-macos-arm64.json): 1,095 translations,
  zero failures, 11 named material routes, seed reload and correct rendered pixels.
  Missing/stale CLI and malformed batch output also preserve compact SPIR-V
  without packaging invalid WGSL.
- [Concurrent cache stress](results/native-cache-threads-macos-arm64.json):
  160/160 GPU values across four local devices while the main renderer drew 421 frames.

The build also passes all 278 curated GLSL/Tint modules. Browser validation
uses the separate [candidate harness](../browser_fork_ports/README.md); these native
results do not establish Windows/D3D12 correctness or browser startup performance.
