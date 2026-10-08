#!/usr/bin/env python3
"""Test production retained-voxel scrolling, indirect dispatch and counter-reset ordering."""

import argparse
import hashlib
import json
import platform
import re
import shutil
import struct
import subprocess
from pathlib import Path

P = Path(__file__).resolve().parent
R = P.parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("engine", type=Path)
p.add_argument("--output", type=Path, required=True)
p.add_argument("--fallback", action="store_true")
a = p.parse_args()
o = a.output.resolve()
o.mkdir(parents=True, exist_ok=True)
shader = R / "servers/rendering/renderer_rd/shaders/environment/sdfgi_preprocess.glsl"
s = (
    shader
    .read_text()
    .replace("#[compute]", "")
    .replace(
        "#VERSION_DEFINES",
        "#extension GL_GOOGLE_include_directive : require\n#define MODE_SCROLL\n#define SDFGI_BUFFER_STORAGE\n#define SDFGI_NATIVE_STORAGE_FORMAT\n",
    )
)
(o / "scroll.source.comp").write_text(s)
g = shutil.which("glslang")
assert g
r = subprocess.run(
    [g, "-E", "-S", "comp", "-I" + str(shader.parent), str(o / "scroll.source.comp")],
    capture_output=True,
    text=True,
    check=True,
)
(o / "scroll.comp").write_text(r.stdout)
s2 = s.replace("#define MODE_SCROLL", "#define MODE_INITIALIZE_JUMP_FLOOD")
(o / "initialize.source.comp").write_text(s2)
r = subprocess.run(
    [g, "-E", "-S", "comp", "-I" + str(shader.parent), str(o / "initialize.source.comp")],
    capture_output=True,
    text=True,
    check=True,
)
(o / "initialize.comp").write_text(r.stdout)
N = 16
voxels = []
expected = [bytearray(N**3 * b) for b in [2, 4, 4, 4]]
for i in range(256):
    idx = i * 17 % (N**3)
    x = idx % N
    y = (idx // N) % N
    z = idx // (N * N)
    albedo = ((i * 37) & 0x7FFF) | ((i % 63 + 1) << 15) | ((i * 101 & 0x7FF) << 21)
    light = 0x12345600 + i | ((i % 4) << 30)
    aniso = 0x23456700 + i | (((i + 1) % 4) << 30)
    voxels.extend([x | (y << 7) | (z << 14) | ((i * 43 & 0x7FF) << 21), albedo, light, aniso])
    x += 3
    y -= 2
    z += 1
    if 0 <= x < N and 0 <= y < N and 0 <= z < N:
        dst = (z * N + y) * N + x
        for target, value, width in zip(
            expected,
            [((albedo & 0x7FFF) << 1) | 1, (albedo >> 15) & 63, light & 0x3FFFFFFF, aniso & 0x3FFFFFFF],
            [2, 4, 4, 4],
        ):
            target[dst * width : (dst + 1) * width] = value.to_bytes(width, "little")
(o / "voxels.bin").write_bytes(struct.pack("<" + "I" * len(voxels), *voxels))
for name, data in zip(["albedo", "facing", "light", "aniso"], expected):
    (o / (name + ".expected")).write_bytes(data)
c = [
    str(a.engine.resolve()),
    "--path",
    str(P),
    "--rendering-method",
    "forward_plus",
    "--rendering-driver",
    "webgpu",
    "--script",
    str(P / "voxel_scroll.gd"),
    "--",
    "--fixture-dir=" + str(o),
]
if a.fallback:
    c.append("--webgpu-force-fallbacks")
r = subprocess.run(c, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
(o / "gpu.log").write_text(r.stdout)
e = [x for x in r.stdout.splitlines() if re.search(r"ERROR:|SCRIPT ERROR:|GPUValidationError|handle_crash", x)]
report = {
    "passed": r.returncode == 0 and not e and "VOXEL_SCROLL COMPLETE checks=40 failed=0" in r.stdout,
    "checks": 40,
    "errors": e,
    "returncode": r.returncode,
    "engine_sha256": hashlib.sha256(a.engine.read_bytes()).hexdigest(),
    "shader_sha256": hashlib.sha256(shader.read_bytes()).hexdigest(),
    "host": platform.platform(),
    "fallback": a.fallback,
    "command": c,
    "log": r.stdout[-2000:],
}
(o / "results.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
raise SystemExit(0 if report["passed"] else 1)
