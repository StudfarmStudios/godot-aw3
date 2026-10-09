#!/usr/bin/env python3
"""Many-writer GPU check of the exact production SDFGI facing atomic block."""

import argparse
import hashlib
import json
import platform
import re
import subprocess
import time
from pathlib import Path

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("engine", type=Path)
p.add_argument("--output", type=Path, required=True)
p.add_argument("--fallback", action="store_true")
p.add_argument("--non-atomic-control", action="store_true")
a = p.parse_args()
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=True)
shaders = ROOT / "servers/rendering/renderer_rd/shaders/forward_clustered"
scene = (shaders / "scene_forward_clustered.glsl").read_text()
block = re.split(r"#el(?:if|se)\b", scene.split("#ifdef SDFGI_BUFFER_STORAGE\n", 1)[1], maxsplit=1)[0]
production_block_hash = hashlib.sha256(block.encode()).hexdigest()
inc = (shaders / "scene_forward_clustered_inc.glsl").read_text()
declaration = inc.split("#ifdef SDFGI_BUFFER_STORAGE\n", 1)[1].split("#else", 1)[0]
if a.non_atomic_control:
    old = "atomicOr(geom_facing_grid.data[index], facing_bits);"
    assert block.count(old) == 1
    block = block.replace(old, "geom_facing_grid.data[index] = geom_facing_grid.data[index] | facing_bits;")
source = (
    """#version 450
layout(local_size_x=64,local_size_y=1,local_size_z=1) in;
layout(r16ui,set=1,binding=24) uniform restrict uimage3D albedo_volume_grid;
"""
    + declaration
    + """
layout(push_constant,std430) uniform Params { uint phase; uint mode; uint pad0; uint pad1; } params;
void main() {
    uint writer=gl_GlobalInvocationID.x;
    uint voxel=writer/4096u;
    ivec3 grid_pos=ivec3(int(voxel%8u),int((voxel/8u)%8u),int(voxel/64u));
    uint facing_bits=1u<<((writer%4096u)%6u);
    if(params.phase!=0u) { facing_bits=1u<<(((writer%4096u)%3u)*2u); }
    if(params.mode!=0u) {
        const ivec3 invalid[8]=ivec3[](ivec3(-1,1,0),ivec3(8,0,0),ivec3(0,-1,1),ivec3(0,8,0),ivec3(1,0,-1),ivec3(0,0,8),ivec3(8,8,-1),ivec3(-8,1,0));
        grid_pos=invalid[writer%8u];
        facing_bits=128u;
    }
"""
    + block
    + "\n}\n"
)
(out / "facing.comp").write_text(source)
command = [
    str(a.engine.resolve()),
    "--path",
    str(PROJECT),
    "--rendering-method",
    "forward_plus",
    "--rendering-driver",
    "webgpu",
    "--script",
    str(PROJECT / "facing.gd"),
    "--",
    "--fixture-dir=" + str(out),
]
if a.fallback:
    command.append("--webgpu-force-fallbacks")
start = time.monotonic()
process = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
log = process.stdout
(out / "gpu.log").write_text(log)
errors = [
    line
    for line in log.splitlines()
    if re.search(r"ERROR:|SCRIPT ERROR:|GPUValidationError|\[WebGPU.*(?:[Ee]rror|[Vv]alidation)|handle_crash", line)
]
complete = re.search(r"SDFGI_FACING COMPLETE checks=(\d+) failed=(\d+)", log)
checks = int(complete[1]) if complete else 0
failed = int(complete[2]) if complete else -1
passed = (
    not errors
    and checks == 12
    and (
        (failed > 0 and process.returncode == 1) if a.non_atomic_control else (failed == 0 and process.returncode == 0)
    )
)
report = {
    "passed": passed,
    "checks": checks,
    "failed_checks": failed,
    "negative_control": a.non_atomic_control,
    "errors": errors,
    "returncode": process.returncode,
    "seconds": time.monotonic() - start,
    "host": platform.platform(),
    "engine_sha256": hashlib.sha256(a.engine.read_bytes()).hexdigest(),
    "production_atomic_block_sha256": production_block_hash,
    "fixture_atomic_block_sha256": hashlib.sha256(block.encode()).hexdigest(),
    "fallback": a.fallback,
    "command": command,
}
(out / "results.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
raise SystemExit(0 if passed else 1)
