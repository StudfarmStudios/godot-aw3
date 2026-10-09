# WebGPU Shader Coverage Test Project

A Godot 4.7 scene exercising a broad set of RenderingDevice features through the
SPIR-V → WGSL pipeline. This is a smoke test, not proof of every shader variant
or feature's visual correctness. Feature availability, resources and deferred
compilation affect the work actually submitted; separate shader corpora and
targeted numerical/visual fixtures provide stronger checks.

## What it exercises

### Environment Shaders
- `sky.glsl` — Procedural sky with radiance
- `tonemap.glsl` — ACES tone mapping
- `ssao.glsl` + blur/importance/interleave — Screen-space ambient occlusion
- `ssil.glsl` + blur/importance/interleave — Screen-space indirect light
- `screen_space_reflection.glsl` + downsample/filter/resolve — SSR
- `volumetric_fog.glsl` + `volumetric_fog_process.glsl` — Volumetric fog
- `sdfgi_*.glsl` (5 shaders) — Signed distance field GI
- A VoxelGI node is created, but has no baked data and does not establish VoxelGI shader coverage
- `bokeh_dof.glsl` — Depth of field
- Glow/bloom blur shaders

### Material Shaders (scene_forward_clustered.glsl variants)
- Normal mapping (`NORMAL_USED`)
- Emission (`EMISSION_USED`)
- Metallic/roughness (standard PBR)
- Clearcoat (`CLEARCOAT`)
- Anisotropy (`ANISOTROPY`)
- Subsurface scattering (`SSS_USED`) + `subsurface_scattering.glsl`
- Refraction (`REFRACTION_USED`)
- Heightmap/parallax (`HEIGHT_USED`)
- Detail maps (`DETAIL_ALBEDO`, `DETAIL_NORMAL`)
- Rim lighting (`RIM_USED`)
- Backlight/transmission (`TRANSMITTANCE_USED`)
- Alpha scissor (depth prepass variant)
- Alpha hash
- Alpha depth pre-pass
- Unshaded mode
- UV2 coordinates
- Billboard mode
- Proximity fade
- Distance fade
- Vertex grow

### Lighting & Shadows
- `cluster_store.glsl` + `cluster_render.glsl` — Light clustering (7 lights)
- Directional shadow (4 splits)
- Omni point shadow
- Spot shadow
- Volumetric light energy

### Particles
- `particles.glsl` — GPU particle simulation
- `particles_copy.glsl` — Particle data copy
- Trail particles (`USE_PARTICLE_TRAILS`)
- Turbulence
- Collision (sphere + box)
- Attractors

### Instancing & Skinning
- `skeleton.glsl` — Bone-based vertex skinning
- MultiMesh instanced rendering (64 instances with colors + custom data)

### Canvas 2D
- `canvas.glsl` — 2D rendering pipeline
- ColorRect (basic draw)
- Label (MSDF text rendering)
- NinePatchRect (nine-patch mode)
- PointLight2D (canvas lighting path)

### Post-Processing & AA
- `taa_resolve.glsl` — Temporal anti-aliasing after switching off FSR2 halfway through the run
- `motion_vectors.glsl` — Motion vector generation
- FSR2 (temporal upscaling, 6+ compute shaders)
- Luminance reduction (auto-exposure)

### Other
- `decal_data_inc.glsl` — Decal rendering (2 decals: albedo+normal, emission)
- Reflection probes (real-time + interior with ambient override)
- Fog volumes (box + ellipsoid shapes)
- Color correction/adjustment

## Usage

### With SPIR-V dump (for shader validation)
```bash
# Build engine with dump enabled:
GODOT_DUMP_SPIRV=/tmp/spirv_dump godot --headless --path . --quit

# Validate all dumped SPIR-V through Tint:
node ../shader_corpus/validate_spirv_dump.mjs /tmp/spirv_dump/
```

### Export for web (CI smoke test)
```bash
godot --headless --path . --export-release "WebGPU" export/index.html
```

### Run in Chrome
```bash
npm install --no-save playwright@1.64.0
npx playwright install chromium --with-deps
# Linux CI uses a headed browser on a virtual display.
xvfb-run -a node preflight.mjs
xvfb-run -a node smoke_test.mjs ./export/
```

Linux CI pins Playwright 1.64.0 / Chromium 156.0.8078.4 and explicitly selects
SwiftShader for software validation. ANGLE uses the documented SwANGLE pair
`--use-gl=angle --use-angle=swiftshader`; Dawn separately selects SwiftShader.
This selects the bundled SwiftShader ICD for ANGLE as well as for Dawn; generic
ANGLE Vulkan can otherwise select an unavailable system driver. ANGLE still
requires the surface extensions supplied by bundled SwiftShader. Both scripts
share the same browser flags and require at least 48 sampled textures, eight
storage textures and eight storage buffers per shader stage. The preflight
requests these limits and exercises all 64 bindings in one compute dispatch,
then checks numerical GPU readback. The smoke test checks the engine's own
adapter and requested device and rejects Mobile fallback.

Chromium's `--disable-dawn-features=tiered_adapter_limits` removes privacy tier
rounding for this software runner; native limit normalization, device limit
validation and GPU validation remain enabled. SwiftShader's dynamic-buffer
limits otherwise reduce the grouped texture limits below Forward+ requirements,
even though the underlying implementation supports the needed bindings. See the
[pinned Chromium switch](https://github.com/chromium/chromium/blob/156.0.8078.4/gpu/command_buffer/service/webgpu_decoder_impl.cc#L1143),
[Dawn limit tiers](https://github.com/google/dawn/blob/0a2c7df818e285d6db0f085135139cda04cee8bb/src/dawn/native/Limits.cpp#L73)
and [required-limit validation](https://github.com/google/dawn/blob/0a2c7df818e285d6db0f085135139cda04cee8bb/src/dawn/native/Adapter.cpp#L293).
The Linux smoke uses a 320 × 180 browser viewport and a five-minute bound. The
original 1280 × 720 cold software run reached Forward+ and its first FSR2 frame
but exceeded two minutes without shader errors or device loss. The smaller
viewport reduces raster work while preserving the ten-frame scene, all enabled
effects and the FSR2-to-TAA transition; canvas dimensions are logged to verify the
actual rendering size. The broad-scene export explicitly uses adaptive canvas
policy 2; the shared export helper defaults to project-sized policy 1 for the
fixed-pixel targeted fixtures. This is a correctness smoke test, not a performance or
visual-quality comparison. Other platforms keep their existing viewport/time
defaults. A timeout remains a failure.

This configuration is test infrastructure, not a browser flag required of users,
and does not establish Firefox/Windows/D3D12 or other hardware-driver coverage.

CI retains the complete console/error report (`smoke-result.json`), browser
version and launch flags. `DEBUG=pw:browser` captures Chromium process output;
`VERBOSE=1` includes all page console messages in `smoke.log`. The independent
preflight runs alongside the candidate build so an unusable software adapter is
reported before waiting for compilation.

## Pass criteria

- Adapter and device meet the Forward+ binding requirements; no Mobile fallback
- The frame sequence completes without engine, browser or shader errors in console
- No device-lost events
- GDScript reports `PASS` in output
