#!/usr/bin/env python3
"""Compare the production SDFGI WebGPU occlusion kernel with a scalar reference."""

import argparse
import hashlib
import json
import platform
import random
import re
import shutil
import struct
import subprocess
import time
from pathlib import Path

from occlusion_reference import N, index, reference

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("engine", type=Path)
p.add_argument("--output", type=Path, required=True)
p.add_argument("--fallback", action="store_true")
p.add_argument(
    "--texture-reference", action="store_true", help="Run the original image-array kernel on the native Metal driver"
)
a = p.parse_args()
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=True)
source_path = ROOT / "servers/rendering/renderer_rd/shaders/environment/sdfgi_preprocess.glsl"
source = (
    source_path
    .read_text()
    .replace("#[compute]", "")
    .replace(
        "#VERSION_DEFINES",
        "#extension GL_GOOGLE_include_directive : require\n#define MODE_OCCLUSION\n#define OCCLUSION_SIZE 8\n#define SDFGI_BUFFER_STORAGE\n#define SDFGI_NATIVE_STORAGE_FORMAT\n#define SDFGI_CASCADE_ATLAS\n",
    )
)
if a.texture_reference:
    source = (
        source
        .replace("#define SDFGI_BUFFER_STORAGE\n", "")
        .replace("#define SDFGI_NATIVE_STORAGE_FORMAT\n", "")
        .replace("#define SDFGI_CASCADE_ATLAS\n", "")
    )
(out / "occlusion.source.comp").write_text(source)
glslang = shutil.which("glslang")
assert glslang, "Install glslang to preprocess the production includes"
preprocessed = subprocess.run(
    [glslang, "-E", "-S", "comp", "-I" + str(source_path.parent), str(out / "occlusion.source.comp")],
    capture_output=True,
    text=True,
    check=True,
)
(out / "occlusion.comp").write_text(preprocessed.stdout)
cases = []
for name, parity in [
    ("empty", 0),
    ("solid", 0),
    ("walls", 0),
    ("walls_shifted", 5),
    ("sparse", 0),
    ("sparse_shifted", 7),
]:
    rng = random.Random(4149)
    facing = [0] * (N**3)
    for z in range(N):
        for y in range(N):
            for x in range(N):
                value = 0
                if name == "solid":
                    value = 63
                if name.startswith("walls"):
                    if x in (3, 11):
                        value |= 1 | 8
                    if y == 6 and 2 <= x <= 13:
                        value |= 2 | 16
                    if z == 9 and x < 8:
                        value |= 4 | 32
                if name.startswith("sparse") and rng.randrange(9) == 0:
                    value = rng.randrange(1, 64)
                facing[index((x, y, z))] = value
    (out / f"{name}.facing").write_bytes(struct.pack("<" + "I" * len(facing), *facing))
    (out / f"{name}.expected").write_bytes(reference(facing, parity))
    cases.append({"name": name, "parity": parity})
(out / "cases.json").write_text(json.dumps(cases))
command = [
    str(a.engine.resolve()),
    "--path",
    str(PROJECT),
    "--rendering-method",
    "forward_plus",
    "--rendering-driver",
    "metal" if a.texture_reference else "webgpu",
    "--script",
    str(PROJECT / "occlusion.gd"),
    "--",
    "--fixture-dir=" + str(out),
]
if a.fallback:
    command.append("--webgpu-force-fallbacks")
if a.texture_reference:
    command.append("--texture-reference")
start = time.monotonic()
process = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
log = process.stdout
(out / "gpu.log").write_text(log)
errors = [
    line
    for line in log.splitlines()
    if re.search(r"ERROR:|SCRIPT ERROR:|GPUValidationError|\[WebGPU.*(?:[Ee]rror|[Vv]alidation)|handle_crash", line)
]
results = []
for case in cases:
    case_name = case["name"]
    assert isinstance(case_name, str)
    actual_path = out / (case_name + ".actual")
    actual = actual_path.read_bytes() if actual_path.exists() else b""
    expected = (out / (case_name + ".expected")).read_bytes()
    diffs = [abs(x - y) for x, y in zip(actual, expected)]
    tolerance = 3 if a.texture_reference else 1
    wrong = sum(d > tolerance for d in diffs)
    guard_ok = actual[len(expected) :] == bytes([0x5A]) * 64
    results.append({
        "case": case["name"],
        "passed": len(diffs) == len(expected) and wrong == 0 and guard_ok,
        "voxels": len(diffs),
        "mismatched_voxels": wrong,
        "max_error_unorm8": max(diffs, default=-1),
        "scalar_tolerance_unorm8": tolerance,
        "guards_intact": None if a.texture_reference else guard_ok,
    })
result = {
    "passed": all(c["passed"] for c in results)
    and not errors
    and process.returncode == 0
    and "SDFGI_OCCLUSION COMPLETE cases=6" in log,
    "cases": results,
    "returncode": process.returncode,
    "errors": errors,
    "seconds": time.monotonic() - start,
    "engine_sha256": hashlib.sha256(a.engine.read_bytes()).hexdigest(),
    "shader_sha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
    "host": platform.platform(),
    "fallback": a.fallback,
    "texture_reference": a.texture_reference,
    "command": command,
}
(out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
raise SystemExit(0 if result["passed"] else 1)
