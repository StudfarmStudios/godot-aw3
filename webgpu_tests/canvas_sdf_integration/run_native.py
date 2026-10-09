#!/usr/bin/env python3
"""Render Canvas SDF masks, distances and normals against a native Metal reference."""

import argparse
import array
import hashlib
import json
import math
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
    choices=["metal", "native", "fallback", "nofilter", "combined"],
    default=["metal", "native", "fallback", "nofilter", "combined"],
)
parser.add_argument("--output", type=Path, default=Path(__file__).parent / "artifacts")
parser.add_argument("--timeout", type=int, default=120)
args = parser.parse_args()
project = Path(__file__).resolve().parent
args.output = args.output.resolve()
args.output.mkdir(parents=True, exist_ok=True)
runs = []
for mode in args.modes:
    directory = args.output / mode
    directory.mkdir(exist_ok=True)
    command = [
        str(args.engine.resolve()),
        "--path",
        str(project),
        "--rendering-method",
        "forward_plus",
        "--rendering-driver",
        "metal" if mode == "metal" else "webgpu",
        "--disable-vsync",
        "--",
        "--sdf-output=" + str(directory),
    ]
    if mode in ("fallback", "combined"):
        command.append("--webgpu-force-fallbacks")
    if mode in ("nofilter", "combined"):
        command.append("--webgpu-no-float32-filterable")
    start = time.monotonic()
    timed_out = False
    with (directory / "engine.log").open("w") as log:
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
    output = (directory / "engine.log").read_text()
    errors = [
        line
        for line in output.splitlines()
        if re.search(
            r"ERROR:|SCRIPT ERROR:|GPUValidationError|handle_crash|Program crashed|\[WebGPU.*(?:[Ee]rror|[Vv]alidation)",
            line,
        )
    ]
    complete = re.search(r"CANVAS_SDF COMPLETE passed=(\d+) failed=(\d+) captures=(\d+)", output)
    passed_checks = int(complete[1]) if complete else 0
    failed_checks = int(complete[2]) if complete else 0
    expected_banner = "Metal 4.0 - Forward+" if mode == "metal" else "WebGPU 1.0 - Forward+"
    passed = (
        expected_banner in output and not errors and not timed_out and complete is not None and int(complete[3]) == 9
    )
    passed &= passed_checks == 36 and failed_checks == 0 and process.returncode == 0
    manifest = json.loads((directory / "manifest.json").read_text()) if (directory / "manifest.json").exists() else {}
    result = {
        "mode": mode,
        "passed": bool(passed),
        "passed_checks": passed_checks,
        "failed_checks": failed_checks,
        "returncode": process.returncode,
        "timed_out": timed_out,
        "seconds": time.monotonic() - start,
        "host": platform.platform(),
        "engine_sha256": hashlib.sha256(args.engine.read_bytes()).hexdigest(),
        "command": command,
        "error_count": len(errors),
        "errors": list(dict.fromkeys(errors)),
        "checks": [line for line in output.splitlines() if line.startswith("CANVAS_SDF ") and "COMPLETE" not in line],
        "captures": manifest.get("captures", []),
    }
    runs.append(result)
    print(json.dumps({key: value for key, value in result.items() if key not in ("checks", "captures")}), flush=True)
comparisons = []
reference = next((run for run in runs if run["mode"] == "metal"), None)
if reference:
    for run in runs:
        if run == reference:
            continue
        for capture in run["captures"]:
            label = capture["label"]
            reference_file = args.output / "metal" / (label + ".rgba32f")
            actual_file = args.output / run["mode"] / (label + ".rgba32f")
            if not reference_file.exists():
                continue
            expected = array.array("f", reference_file.read_bytes())
            actual = array.array("f", actual_file.read_bytes())
            if len(expected) != len(actual):
                continue
            # Normals at medial axes have no unique direction; compare only the
            # same two well-defined exterior points as the analytic oracle.
            indices = (
                [((80 * capture["width"] + x) * 4 + channel) for x in (32, 128) for channel in (0, 1)]
                if capture["mode"] == 2
                else [index for index in range(len(expected)) if index % 4 != 3]
            )
            nonfinite = sum(not math.isfinite(actual[index]) or not math.isfinite(expected[index]) for index in indices)
            differences = sorted(
                abs(actual[index] - expected[index])
                for index in indices
                if math.isfinite(actual[index]) and math.isfinite(expected[index])
            )
            comparisons.append({
                "mode": run["mode"],
                "capture": label,
                "samples": len(indices),
                "nonfinite_components": nonfinite,
                "mean_absolute_error": sum(differences) / len(differences) if differences else None,
                "maximum_absolute_error": differences[-1] if differences else None,
                "p99_absolute_error": differences[int(len(differences) * 0.99)] if differences else None,
                "scope": "two exterior normals" if capture["mode"] == 2 else "all RGB pixels",
            })
report = {"passed": all(run["passed"] for run in runs), "runs": runs, "metal_comparisons": comparisons}
(args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
sys.exit(0 if report["passed"] else 1)
