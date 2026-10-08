#!/usr/bin/env python3
"""Run the real-engine regression fixture, rejecting validation errors and skips."""

import argparse
import hashlib
import json
import platform
from pathlib import Path
import re
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("engine", type=Path, help="Native Godot editor built with webgpu=yes and Dawn")
parser.add_argument("--mode", choices=["native", "fallback", "both"], default="both")
parser.add_argument("--output", type=Path, default=Path(__file__).parent / "artifacts")
parser.add_argument("--timeout", type=int, default=120)
args = parser.parse_args()
project = Path(__file__).resolve().parent
args.output.mkdir(parents=True, exist_ok=True)
failed = False
engine_sha256 = hashlib.file_digest(args.engine.open("rb"), "sha256").hexdigest()
for mode in (["native", "fallback"] if args.mode == "both" else [args.mode]):
    command = [str(args.engine.resolve()), "--path", str(project), "--rendering-method", "forward_plus",
               "--rendering-driver", "webgpu"]
    if mode == "fallback":
        command += ["--", "--webgpu-force-fallbacks"]
    start = time.monotonic()
    timed_out = False
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        output, _ = process.communicate(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        process.terminate()
        try:
            output, _ = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            output, _ = process.communicate()
    elapsed = time.monotonic() - start
    errors = [line for line in output.splitlines() if re.search(
        r"ERROR:|SCRIPT ERROR:|GPUValidationError|\[WebGPU.*(?:[Ee]rror|[Vv]alidation)|DRIVER_TEST FAIL|DRIVER_TEST timeout", line)]
    complete = re.search(r"DRIVER_TEST COMPLETE passed=(\d+) failed=(\d+)", output)
    # Current fixture has 16 upload/shared checks, five shape checks and two
    # slice checks, two compressed-mip checks and 18 MSAA checks. A partial suite, renderer fallback or missing callback fails.
    checks = int(complete[1]) + int(complete[2]) if complete else 0
    failed_checks = int(complete[2]) if complete else None
    webgpu_forward = "WebGPU 1.0 - Forward+" in output
    passed = webgpu_forward and process.returncode == 0 and not timed_out and not errors and checks == 43 and failed_checks == 0
    (args.output / f"{mode}.log").write_text(output)
    result = {"mode": mode, "passed": passed, "checks": checks, "returncode": process.returncode,
              "failed_checks": failed_checks, "timed_out": timed_out, "seconds": elapsed,
              "host": platform.platform(), "engine_sha256": engine_sha256, "command": command, "errors": errors}
    (args.output / f"{mode}.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)
    failed |= not passed
sys.exit(1 if failed else 0)
