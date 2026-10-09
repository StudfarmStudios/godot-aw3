#!/usr/bin/env python3
"""Check production occlusion scrolling, eight channels, signed offsets and guards."""

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
N = 16
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("engine", type=Path)
p.add_argument("--output", type=Path, required=True)
p.add_argument("--fallback", action="store_true")
a = p.parse_args()
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=True)
shader = ROOT / "servers/rendering/renderer_rd/shaders/environment/sdfgi_preprocess.glsl"
s = (
    shader
    .read_text()
    .replace("#[compute]", "")
    .replace(
        "#VERSION_DEFINES",
        "#extension GL_GOOGLE_include_directive : require\n#define MODE_SCROLL_OCCLUSION\n#define SDFGI_BUFFER_STORAGE\n#define SDFGI_NATIVE_STORAGE_FORMAT\n",
    )
)
(out / "scroll.source.comp").write_text(s)
glslang = shutil.which("glslang")
assert glslang, "Install glslang to preprocess the production includes"
pre = subprocess.run(
    [glslang, "-E", "-S", "comp", "-I" + str(shader.parent), str(out / "scroll.source.comp")],
    capture_output=True,
    text=True,
    check=True,
)
(out / "scroll.comp").write_text(pre.stdout)
source = bytes(
    (x * 7 + y * 13 + z * 17 + c * 41) % 256
    for z in range(2 * N)
    for y in range(N)
    for x in range(2 * N)
    for c in range(4)
)
(out / "source.rgba8").write_bytes(source)
cases = []
for i, scroll in enumerate([(0, 0, 0), (3, -5, 2), (-7, 1, -4), (15, -15, 15)]):
    for cascade in range(2):
        name = f"scroll{i}-cascade{cascade}"
        expected = bytearray([90] * (8 * N**3 + 64))
        for z in range(N - abs(scroll[2])):
            for y in range(N - abs(scroll[1])):
                for x in range(N - abs(scroll[0])):
                    read = [v + max(0, -d) for v, d in zip((x, y, z), scroll)]
                    write = [v + max(0, d) for v, d in zip((x, y, z), scroll)]
                    read[2] += cascade * N
                    for channel in range(8):
                        rx = read[0] + (N if channel >= 4 else 0)
                        value = source[((read[2] * N + read[1]) * (2 * N) + rx) * 4 + channel % 4]
                        index = channel * N**3 + (write[2] * N + write[1]) * N + write[0]
                        expected[index] = value
        (out / (name + ".expected")).write_bytes(expected)
        cases.append({"name": name, "scroll": scroll, "cascade": cascade})
(out / "cases.json").write_text(json.dumps(cases))
command = [
    str(a.engine.resolve()),
    "--path",
    str(PROJECT),
    "--rendering-method",
    "forward_plus",
    "--rendering-driver",
    "webgpu",
    "--script",
    str(PROJECT / "scroll.gd"),
    "--",
    "--fixture-dir=" + str(out),
]
if a.fallback:
    command.append("--webgpu-force-fallbacks")
start = time.monotonic()
proc = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
log = proc.stdout
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
    path = out / (case_name + ".actual")
    actual = path.read_bytes() if path.exists() else b""
    expected = (out / (case_name + ".expected")).read_bytes()
    results.append({
        "case": case["name"],
        "passed": actual == expected,
        "different_bytes": sum(x != y for x, y in zip(actual, expected)),
        "bytes": len(actual),
    })
report = {
    "passed": all(c["passed"] for c in results)
    and not errors
    and proc.returncode == 0
    and "SDFGI_SCROLL COMPLETE cases=8" in log,
    "cases": results,
    "errors": errors,
    "returncode": proc.returncode,
    "seconds": time.monotonic() - start,
    "host": platform.platform(),
    "engine_sha256": hashlib.sha256(a.engine.read_bytes()).hexdigest(),
    "shader_sha256": hashlib.sha256(shader.read_bytes()).hexdigest(),
    "fallback": a.fallback,
    "command": command,
}
(out / "results.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
raise SystemExit(0 if report["passed"] else 1)
