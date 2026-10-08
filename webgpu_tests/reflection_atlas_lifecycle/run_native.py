#!/usr/bin/env python3
"""Render once-only and reallocated reflection atlases, rejecting shutdown leaks."""

from __future__ import annotations

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
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--engine", type=Path, required=True)
parser.add_argument("--driver", choices=["webgpu", "metal", "vulkan", "d3d12"], default="webgpu")
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--timeout", type=float, default=90.0, help="Maximum seconds per lifecycle")
args = parser.parse_args()
if args.timeout <= 0:
    parser.error("--timeout must be positive")
engine = args.engine.resolve()
output = args.output.resolve()
project = output / "project"
project.mkdir(parents=True, exist_ok=True)
for filename in ["project.godot", "lifecycle.gd"]:
    shutil.copyfile(PROJECT / filename, project / filename)
cases: list[dict[str, object]] = []
for name, extra in [("once", ["--once-only"]), ("switch", [])]:
    command = [
        str(engine),
        "--path",
        str(project),
        "--rendering-method",
        "forward_plus",
        "--rendering-driver",
        args.driver,
        "--audio-driver",
        "Dummy",
        "--resolution",
        "160x120",
        "--script",
        "res://lifecycle.gd",
        "--",
        *extra,
    ]
    start = time.monotonic()
    timed_out = False
    returncode: int | None
    try:
        process = subprocess.run(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=args.timeout
        )
        log = process.stdout
        returncode = process.returncode
    except subprocess.TimeoutExpired as error:
        timed_out = True
        returncode = None
        captured = error.stdout or ""
        log = captured.decode(errors="replace") if isinstance(captured, bytes) else captured
    (output / (name + ".log")).write_text(log)
    errors = [
        line
        for line in log.splitlines()
        if re.search(r"ERROR:|WARNING:|GPUValidationError|AW3_LEAK|handle_crash|Device lost", line, re.IGNORECASE)
    ]
    required = ["ATLAS_ONCE_RENDERED", "ATLAS_LIFECYCLE_COMPLETE"]
    if name == "switch":
        required.append("ATLAS_REALTIME_RENDERED")
    missing = [marker for marker in required if marker not in log]
    cases.append({
        "case": name,
        "passed": returncode == 0 and not timed_out and not errors and not missing,
        "returncode": returncode,
        "timed_out": timed_out,
        "seconds": time.monotonic() - start,
        "errors": errors,
        "missing_markers": missing,
        "command": command,
    })
report = {
    "passed": all(case["passed"] for case in cases),
    "host": platform.platform(),
    "driver": args.driver,
    "engine_sha256": hashlib.sha256(engine.read_bytes()).hexdigest(),
    "fixture_sha256": {
        name: hashlib.sha256((PROJECT / name).read_bytes()).hexdigest() for name in ["project.godot", "lifecycle.gd"]
    },
    "cases": cases,
}
(output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
raise SystemExit(0 if report["passed"] else 1)
