#!/usr/bin/env python3
"""Read actual D32 depth with the GI shader's production binding and fetch expression."""

import argparse
import hashlib
import json
import platform
import re
import subprocess
from pathlib import Path

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("engine", type=Path)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--untyped-control", action="store_true")
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
production = (ROOT / "servers/rendering/renderer_rd/shaders/environment/gi.glsl").read_text()
binding_match = re.search(r"layout\(set = 0, binding = 12\)[\s\S]*?(?=layout\(set = 0, binding = 13\))", production)
fetch_match = re.search(r"texelFetch\(sampler2D\(depth_buffer, linear_sampler\), screen_pos, 0\)\.r", production)
assert binding_match and fetch_match, "GI production depth declaration/fetch changed"
binding = binding_match[0]
fetch = fetch_match[0]
if args.untyped_control:
    binding = "layout(set = 0, binding = 12) uniform texture2D depth_buffer;\n"
source = (
    """#version 450
layout(local_size_x=1,local_size_y=1,local_size_z=1) in;
layout(set=0,binding=1,std430) buffer Results { float value; } result;
layout(set=0,binding=6) uniform sampler linear_sampler;
"""
    + binding
    + "void main() { ivec2 screen_pos=ivec2(1); result.value="
    + fetch
    + "; }\n"
)
(out / "depth.comp").write_text(source)
command = [
    str(args.engine.resolve()),
    "--path",
    str(PROJECT),
    "--rendering-method",
    "forward_plus",
    "--rendering-driver",
    "webgpu",
    "--script",
    str(PROJECT / "depth_read.gd"),
    "--",
    "--fixture-dir=" + str(out),
]
process = subprocess.run(command, capture_output=True, text=True, timeout=120)
log = process.stdout + process.stderr
(out / "gpu.log").write_text(log)
errors = [line for line in log.splitlines() if re.search(r"ERROR:|SCRIPT ERROR:|GPUValidationError|handle_crash", line)]
expected_failures = 2 if args.untyped_control else 0
report = {
    "passed": not errors
    and process.returncode == int(args.untyped_control)
    and f"SDFGI_DEPTH COMPLETE checks=2 failed={expected_failures}" in log,
    "checks": 2,
    "negative_control": args.untyped_control,
    "errors": errors,
    "returncode": process.returncode,
    "values": re.findall(r"SDFGI_DEPTH expected=([\d.]+) actual=([\d.]+)", log),
    "engine_sha256": hashlib.sha256(args.engine.read_bytes()).hexdigest(),
    "gi_source_sha256": hashlib.sha256(production.encode()).hexdigest(),
    "host": platform.platform(),
    "command": command,
}
(out / "results.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
raise SystemExit(0 if report["passed"] else 1)
