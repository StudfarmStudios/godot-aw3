#!/usr/bin/env python3
"""Execute the production luminance shader on GPU, including a legacy mutation control."""

import argparse
import hashlib
import json
import platform
import re
import subprocess
import sys
import time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("engine", type=Path)
parser.add_argument(
    "--modes", nargs="+", choices=["metal", "native", "fallback"], default=["metal", "native", "fallback"]
)
parser.add_argument(
    "--legacy-control",
    action="store_true",
    help="Also require the former any-coordinate predicate to fail on native WebGPU",
)
parser.add_argument("--output", type=Path, default=Path(__file__).parent / "artifacts")
parser.add_argument("--timeout", type=int, default=90)
args = parser.parse_args()
project = Path(__file__).resolve().parent
shader = project.parents[1] / "servers/rendering/renderer_rd/shaders/effects/luminance_reduce.glsl"
args.output.mkdir(parents=True, exist_ok=True)
runs = []
for mode, legacy in [(mode, False) for mode in args.modes] + ([("native", True)] if args.legacy_control else []):
    name = mode + ("-legacy" if legacy else "")
    command = [
        str(args.engine.resolve()),
        "--path",
        str(project),
        "--script",
        "res://main.gd",
        "--rendering-method",
        "forward_plus",
        "--rendering-driver",
        "metal" if mode == "metal" else "webgpu",
        "--disable-vsync",
        "--",
        "--luminance-shader=" + str(shader),
    ]
    if mode == "fallback":
        command.append("--webgpu-force-fallbacks")
    if legacy:
        command.append("--legacy-bounds")
    start = time.monotonic()
    timed_out = False
    with (args.output / (name + ".log")).open("w") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, text=True)
        try:
            process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    output = (args.output / (name + ".log")).read_text()
    errors = [
        line
        for line in output.splitlines()
        if re.search(
            r"ERROR:|SCRIPT ERROR:|GPUValidationError|handle_crash|Program crashed|\[WebGPU.*(?:[Ee]rror|[Vv]alidation)",
            line,
        )
    ]
    complete = re.search(r"LUMINANCE_REDUCTION COMPLETE passed=(\d+) failed=(\d+)", output)
    passed_checks = int(complete[1]) if complete else 0
    failed_checks = int(complete[2]) if complete else 0
    expected_banner = "Metal 4.0 - Forward+" if mode == "metal" else "WebGPU 1.0 - Forward+"
    passed = expected_banner in output and not errors and not timed_out and passed_checks + failed_checks == 24
    passed &= (
        (process.returncode == 1 and failed_checks > 0) if legacy else (process.returncode == 0 and failed_checks == 0)
    )
    result = {
        "mode": mode,
        "legacy_control": legacy,
        "passed": passed,
        "passed_checks": passed_checks,
        "failed_checks": failed_checks,
        "returncode": process.returncode,
        "timed_out": timed_out,
        "seconds": time.monotonic() - start,
        "host": platform.platform(),
        "engine_sha256": hashlib.sha256(args.engine.read_bytes()).hexdigest(),
        "shader_sha256": hashlib.sha256(shader.read_bytes()).hexdigest(),
        "command": command,
        "errors": errors,
        "checks": [
            line for line in output.splitlines() if line.startswith("LUMINANCE_REDUCTION ") and "COMPLETE" not in line
        ],
    }
    runs.append(result)
    print(json.dumps({key: value for key, value in result.items() if key != "checks"}), flush=True)
report = {"passed": all(run["passed"] for run in runs), "runs": runs}
(args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
sys.exit(0 if report["passed"] else 1)
