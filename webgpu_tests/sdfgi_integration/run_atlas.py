#!/usr/bin/env python3
"""Exercise the production cascade sampling helper and tile-clear shader on WebGPU."""

import argparse
import hashlib
import json
import platform
import re
import shutil
import subprocess
import time
from pathlib import Path

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parents[1]
SHADERS = ROOT / "servers/rendering/renderer_rd/shaders"
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("engine", type=Path)
p.add_argument("--output", type=Path, required=True)
p.add_argument("--fallback", action="store_true")
p.add_argument("--no-float32-filterable", action="store_true")
a = p.parse_args()
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=True)
glslang = shutil.which("glslang")
assert glslang, "Install glslang to preprocess the production includes"
for name in ["fill", "sample", "clear"]:
    if name == "clear":
        source = (
            (SHADERS / "environment/sdfgi_preprocess.glsl")
            .read_text()
            .replace("#[compute]", "")
            .replace(
                "#VERSION_DEFINES",
                "#extension GL_GOOGLE_include_directive : require\n#define MODE_CLEAR_LIGHT\n#define SDFGI_CASCADE_ATLAS\n#define SDFGI_BUFFER_STORAGE\n#define SDFGI_NATIVE_STORAGE_FORMAT\n",
            )
        )
    else:
        source = (PROJECT / ("atlas_" + name + ".comp")).read_text()
    (out / (name + ".source.comp")).write_text(source)
    result = subprocess.run(
        [
            glslang,
            "-E",
            "-S",
            "comp",
            "-I" + str(SHADERS),
            "-I" + str(SHADERS / "environment"),
            str(out / (name + ".source.comp")),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    (out / (name + ".comp")).write_text(result.stdout)
command = [
    str(a.engine.resolve()),
    "--path",
    str(PROJECT),
    "--rendering-method",
    "forward_plus",
    "--rendering-driver",
    "webgpu",
    "--script",
    str(PROJECT / "atlas.gd"),
    "--",
    "--fixture-dir=" + str(out),
]
if a.fallback:
    command.append("--webgpu-force-fallbacks")
if a.no_float32_filterable:
    command.append("--webgpu-no-float32-filterable")
start = time.monotonic()
process = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
log = process.stdout
(out / "gpu.log").write_text(log)
errors = [
    line
    for line in log.splitlines()
    if re.search(
        r"ERROR:|SCRIPT ERROR:|GPUValidationError|\[WebGPU.*(?:[Ee]rror|[Vv]alidation)|SDFGI_ATLAS FAIL|handle_crash",
        line,
    )
]
checks = re.search(r"SDFGI_ATLAS COMPLETE checks=(\d+) failed=(\d+)", log)
report = {
    "passed": not errors and process.returncode == 0 and checks is not None and checks.groups() == ("32", "0"),
    "checks": int(checks[1]) if checks else 0,
    "errors": errors,
    "returncode": process.returncode,
    "seconds": time.monotonic() - start,
    "host": platform.platform(),
    "engine_sha256": hashlib.sha256(a.engine.read_bytes()).hexdigest(),
    "sampling_helper_sha256": hashlib.sha256((SHADERS / "sdfgi_cascade_inc.glsl").read_bytes()).hexdigest(),
    "preprocess_shader_sha256": hashlib.sha256(
        (SHADERS / "environment/sdfgi_preprocess.glsl").read_bytes()
    ).hexdigest(),
    "fallback": a.fallback,
    "no_float32_filterable": a.no_float32_filterable,
    "command": command,
}
(out / "results.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
raise SystemExit(0 if report["passed"] else 1)
