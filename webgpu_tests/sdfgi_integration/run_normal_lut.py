#!/usr/bin/env python3
"""Check the production best-fit-normal nearest/clamp fetch on actual R32F data."""

import argparse
import hashlib
import json
import platform
import re
import subprocess
from pathlib import Path

P = Path(__file__).resolve().parent
R = P.parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("engine", type=Path)
p.add_argument("--output", type=Path, required=True)
p.add_argument("--no-float32-filterable", action="store_true")
p.add_argument("--fallback", action="store_true")
p.add_argument("--legacy-control", action="store_true", help="Expect the old filtered lookup to lose R32F data")
a = p.parse_args()
if a.legacy_control and not a.no_float32_filterable:
    p.error("--legacy-control requires --no-float32-filterable")
o = a.output.resolve()
o.mkdir(parents=True, exist_ok=True)
s = (R / "servers/rendering/renderer_rd/shaders/forward_clustered/scene_forward_clustered.glsl").read_text()
block_match = re.search(r"ivec2 fitting_size =[\s\S]*?float fFittingScale =[^;]+;", s)
assert block_match, "Production nearest/clamp lookup changed"
block = block_match[0]
source = (
    """#version 450
layout(local_size_x=1) in;
layout(set=0,binding=0) uniform texture2D best_fit_normal_texture;
layout(set=0,binding=1) uniform sampler SAMPLER_NEAREST_CLAMP;
layout(set=0,binding=2,std430) readonly buffer Coordinates { vec2 uv[]; } input_data;
layout(set=0,binding=3,std430) writeonly buffer Results { float value[]; } output_data;
void main() {
uint i=gl_GlobalInvocationID.x;
vec2 vTexCoord=input_data.uv[i];
"""
    + block
    + "\noutput_data.value[i]=fFittingScale;\n}\n"
)
# On a device with float32 filtering, also run the original nearest/clamp lookup
# against the same data. Baseline devices cannot declare this filtered contract.
legacy_source = source.replace(
    block,
    "float fFittingScale = textureLod(sampler2D(best_fit_normal_texture, SAMPLER_NEAREST_CLAMP), vTexCoord, 0.0).r;",
)
(o / "lookup.comp").write_text(legacy_source if a.legacy_control else source)
(o / "nearest.comp").write_text(legacy_source)
c = [
    str(a.engine.resolve()),
    "--path",
    str(P),
    "--rendering-method",
    "forward_plus",
    "--rendering-driver",
    "webgpu",
    "--script",
    str(P / "normal_lut.gd"),
    "--",
    "--fixture-dir=" + str(o),
]
if a.no_float32_filterable:
    c.append("--webgpu-no-float32-filterable")
if a.fallback:
    c.append("--webgpu-force-fallbacks")
r = subprocess.run(c, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
(o / "gpu.log").write_text(r.stdout)
e = [x for x in r.stdout.splitlines() if re.search(r"ERROR:|SCRIPT ERROR:|GPUValidationError|handle_crash", x)]
n = 81 if a.no_float32_filterable else 162
expected_failures = n if a.legacy_control else 0
report = {
    "passed": r.returncode == int(a.legacy_control)
    and not e
    and f"NORMAL_LUT COMPLETE checks={n} failed={expected_failures}" in r.stdout,
    "checks": n,
    "negative_control": a.legacy_control,
    "errors": e,
    "returncode": r.returncode,
    "fallback": a.fallback,
    "no_float32_filterable": a.no_float32_filterable,
    "source_sha256": hashlib.sha256(s.encode()).hexdigest(),
    "engine_sha256": hashlib.sha256(a.engine.read_bytes()).hexdigest(),
    "host": platform.platform(),
    "command": c,
}
(o / "results.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
raise SystemExit(0 if report["passed"] else 1)
