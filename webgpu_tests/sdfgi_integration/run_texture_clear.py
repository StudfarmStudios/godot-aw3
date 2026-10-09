#!/usr/bin/env python3
"""Exercise full-depth, per-mip and ordered fallback texture clears on the GPU."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import re
import subprocess
from pathlib import Path

P = Path(__file__).resolve().parent
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("engine", type=Path)
p.add_argument("--output", type=Path, required=True)
p.add_argument("--fallback", action="store_true")
p.add_argument("--driver", choices=["webgpu", "metal"], default="webgpu")
a = p.parse_args()
o = a.output.resolve()
o.mkdir(parents=True, exist_ok=True)
c = [
    str(a.engine.resolve()),
    "--path",
    str(P),
    "--rendering-method",
    "forward_plus",
    "--rendering-driver",
    a.driver,
    "--script",
    str(P / "texture_clear.gd"),
    "--",
    "--fixture-dir=" + str(o),
]
if a.fallback:
    c.append("--webgpu-force-fallbacks")
r = subprocess.run(c, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
(o / "gpu.log").write_text(r.stdout)
e = [x for x in r.stdout.splitlines() if re.search(r"ERROR:|SCRIPT ERROR:|GPUValidationError|handle_crash", x)]
m = re.search(r"TEXTURE_CLEAR COMPLETE checks=(\d+) failed=(\d+)", r.stdout)
report = {
    "passed": r.returncode == 0 and not e and bool(m and int(m[2]) == 0),
    "checks": int(m[1]) if m else 0,
    "failed": int(m[2]) if m else None,
    "errors": e[:20],
    "returncode": r.returncode,
    "engine_sha256": hashlib.sha256(a.engine.read_bytes()).hexdigest(),
    "fixture_sha256": hashlib.sha256((P / "texture_clear.gd").read_bytes()).hexdigest(),
    "host": platform.platform(),
    "fallback": a.fallback,
    "driver": a.driver,
    "command": c,
}
(o / "results.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
raise SystemExit(0 if report["passed"] else 1)
