#!/usr/bin/env python3
"""Render emissive SDFGI bounce, then scroll cascades in a real Forward+ scene."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import re
import subprocess
import time
from pathlib import Path

PROJECT = Path(__file__).resolve().parent
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--cascades", type=int, choices=range(1, 9), default=4)
p.add_argument("--driver", choices=["webgpu", "metal"], default="webgpu")
p.add_argument("--no-float32-filterable", action="store_true")
p.add_argument("--debug-capture", action="store_true")
p.add_argument("--no-occlusion", action="store_true")
p.add_argument("--scroll-frames", type=int, default=20)
p.add_argument("--rebuild-scrolled", action="store_true")
p.add_argument(
    "--benchmark-frames",
    type=int,
    default=0,
    help="Steady-state wall time with final GPU completion; coordinate exclusive GPU use first",
)
p.add_argument("engine", type=Path)
p.add_argument("--output", type=Path, required=True)
p.add_argument("--fallback", action="store_true")
a = p.parse_args()
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=True)
command = [
    str(a.engine.resolve()),
    "--path",
    str(PROJECT),
    "--rendering-method",
    "forward_plus",
    "--rendering-driver",
    a.driver,
    "--script",
    str(PROJECT / "scene.gd"),
    "--",
    "--fixture-dir=" + str(out),
    "--cascades=" + str(a.cascades),
    "--scroll-frames=" + str(a.scroll_frames),
]
if a.fallback:
    command.append("--webgpu-force-fallbacks")
if a.no_float32_filterable:
    command.append("--webgpu-no-float32-filterable")
if a.debug_capture:
    command.append("--debug-capture")
if a.no_occlusion:
    command.append("--no-occlusion")
if a.rebuild_scrolled:
    command.append("--rebuild-scrolled")
if a.benchmark_frames:
    command.append("--benchmark-frames=" + str(a.benchmark_frames))
start = time.monotonic()
timed_out = False
returncode: int | None
try:
    process = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=240)
    log = process.stdout
    returncode = process.returncode
except subprocess.TimeoutExpired as error:
    timed_out = True
    returncode = None
    captured_output = error.stdout or ""
    log = captured_output.decode(errors="replace") if isinstance(captured_output, bytes) else captured_output
(out / "gpu.log").write_text(log)
errors = [
    line
    for line in log.splitlines()
    if re.search(
        r"ERROR:|SCRIPT ERROR:|GPUValidationError|\[WebGPU.*(?:[Ee]rror|[Vv]alidation)|SDFGI_SCENE FAIL|handle_crash",
        line,
    )
]
if timed_out:
    errors.append("Scene exceeded 240 seconds; incomplete GPU run")
metrics = re.search(
    r"SDFGI_SCENE (?:PASS|FAIL) cascades=(\d+) affected=(\d+) red_increase=([\d.]+) scrolled_affected=(\d+)", log
)
report = {
    "passed": not errors and returncode == 0 and "SDFGI_SCENE PASS" in log,
    "errors": errors[:30],
    "error_count": len(errors),
    "returncode": returncode,
    "timed_out": timed_out,
    "seconds": time.monotonic() - start,
    "host": platform.platform(),
    "engine_sha256": hashlib.sha256(a.engine.read_bytes()).hexdigest(),
    "driver": a.driver,
    "fallback": a.fallback,
    "no_float32_filterable": a.no_float32_filterable,
    "cascades": a.cascades,
    "scroll_frames": a.scroll_frames,
    "affected_pixels": int(metrics[2]) if metrics else None,
    "red_increase_sum": float(metrics[3]) if metrics else None,
    "scroll_affected_pixels": int(metrics[4]) if metrics else None,
    "command": command,
}
scene_metrics = out / "scene-metrics.json"
if scene_metrics.exists():
    report["scene_metrics"] = json.loads(scene_metrics.read_text())
(out / "results.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
raise SystemExit(0 if report["passed"] else 1)
