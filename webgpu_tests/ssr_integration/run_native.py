#!/usr/bin/env python3
"""Verify Forward+ SSR reflections, roughness and odd resize."""

import argparse
import hashlib
import itertools
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
    "--modes",
    nargs="+",
    choices=["metal", "native", "fallback", "no-filter", "combined"],
    default=["metal", "native", "fallback", "no-filter", "combined"],
)
parser.add_argument("--output", type=Path, default=Path(__file__).parent / "artifacts")
parser.add_argument("--timeout", type=int, default=90)
parser.add_argument("--resolutions", nargs="+", choices=["half", "full"], default=["half", "full"])
parser.add_argument("--msaa", nargs="+", choices=["off", "4"], default=["off", "4"])
parser.add_argument("--debug-buffers", action="store_true")
args = parser.parse_args()
project = Path(__file__).resolve().parent
args.output.mkdir(parents=True, exist_ok=True)
runs = []
for mode, resolution, msaa in itertools.product(args.modes, args.resolutions, args.msaa):
    name = f"{mode}-{resolution}-msaa{msaa}"
    capture = args.output / name
    capture.mkdir(exist_ok=True)
    command = [
        str(args.engine.resolve()),
        "--path",
        str(project),
        "--rendering-method",
        "forward_plus",
        "--rendering-driver",
        "metal" if mode == "metal" else "webgpu",
        "--disable-vsync",
    ]
    command.extend(["--", "--output=" + str(capture.resolve())])
    if args.debug_buffers:
        command.append("--debug-buffers")
    if resolution == "full":
        command.append("--full-size")
    if msaa == "4":
        command.append("--msaa")
    if mode in ("fallback", "combined"):
        command.append("--webgpu-force-fallbacks")
    if mode in ("no-filter", "combined"):
        command.append("--webgpu-no-float32-filterable")
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
            r"ERROR:|SCRIPT ERROR:|GPUValidationError|handle_crash|Program crashed|was leaked|\[WebGPU.*(?:[Ee]rror|[Vv]alidation)",
            line,
        )
    ]
    complete = re.search(r"SSR_INTEGRATION COMPLETE passed=(\d+) failed=(\d+)", output)
    passed_checks = int(complete[1]) if complete else 0
    failed_checks = int(complete[2]) if complete else 0
    expected_banner = "Metal 4.0 - Forward+" if mode == "metal" else "WebGPU 1.0 - Forward+"
    passed = expected_banner in output and not errors and not timed_out and passed_checks + failed_checks == 15
    passed &= process.returncode == 0 and failed_checks == 0
    result = {
        "mode": mode,
        "resolution": resolution,
        "msaa": msaa,
        "passed": passed,
        "passed_checks": passed_checks,
        "failed_checks": failed_checks,
        "returncode": process.returncode,
        "timed_out": timed_out,
        "seconds": time.monotonic() - start,
        "host": platform.platform(),
        "engine_sha256": hashlib.sha256(args.engine.read_bytes()).hexdigest(),
        "command": command,
        "errors": errors,
        "checks": [
            line for line in output.splitlines() if line.startswith("SSR_INTEGRATION ") and "COMPLETE" not in line
        ],
    }
    runs.append(result)
    print(
        json.dumps({
            **{key: value for key, value in result.items() if key not in ("checks", "errors")},
            "error_count": len(errors),
            "errors": errors[:8],
        }),
        flush=True,
    )
# A merely nonzero reflection can still hide a blank depth source. Compare
# integrated red reflection energy against the native renderer at the same
# resolution/MSAA setting, allowing 5% for format/driver rounding differences.
comparisons = []
for run in runs:
    if run["mode"] == "metal":
        continue
    reference = next(
        (
            item
            for item in runs
            if item["mode"] == "metal" and item["resolution"] == run["resolution"] and item["msaa"] == run["msaa"]
        ),
        None,
    )
    if reference is None:
        continue

    def reflection_energy(checks):
        values = {}
        for check in checks:
            match = re.search(r"(\w+)_red_reflection \[\d+, ([\d.]+)\]", check)
            if match:
                values[match[1]] = float(match[2])
        return values

    expected = reflection_energy(reference["checks"])
    actual = reflection_energy(run["checks"])
    for phase, energy in expected.items():
        ratio = actual.get(phase, 0.0) / energy if energy > 0 else 0.0
        comparisons.append({
            "mode": run["mode"],
            "resolution": run["resolution"],
            "msaa": run["msaa"],
            "phase": phase,
            "reference_ratio": ratio,
            "passed": 0.95 <= ratio <= 1.05,
        })
report = {
    "passed": all(run["passed"] for run in runs) and all(check["passed"] for check in comparisons),
    "runs": runs,
    "reference_comparisons": comparisons,
}
(args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
sys.exit(0 if report["passed"] else 1)
