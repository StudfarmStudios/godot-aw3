#!/usr/bin/env python3
"""Verify exact float32 fetches and preserved filtering contracts across specialization and stages."""

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
    "--modes",
    nargs="+",
    choices=["native", "fallback", "nofilter", "combined"],
    default=["native", "fallback", "nofilter", "combined"],
)
parser.add_argument("--output", type=Path, default=Path(__file__).parent / "artifacts")
parser.add_argument("--timeout", type=int, default=90)
parser.add_argument("--tint-cli", type=Path)
args = parser.parse_args()
project = Path(__file__).resolve().parent
args.output.mkdir(parents=True, exist_ok=True)
runs = []
for mode in args.modes:
    name = mode
    directory = args.output.resolve() / mode
    directory.mkdir(parents=True, exist_ok=True)
    command = [
        str(args.engine.resolve()),
        "--path",
        str(project),
        "--rendering-method",
        "forward_plus",
        "--rendering-driver",
        "metal" if mode == "metal" else "webgpu",
        "--disable-vsync",
        "--script",
        "res://main.gd",
        "--",
        "--filter-output=" + str(directory),
    ]
    if mode in ("fallback", "combined"):
        command.append("--webgpu-force-fallbacks")
    if mode in ("nofilter", "combined"):
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
            r"ERROR:|SCRIPT ERROR:|GPUValidationError|handle_crash|Program crashed|\[WebGPU.*(?:[Ee]rror|[Vv]alidation)",
            line,
        )
    ]
    complete = re.search(r"SAMPLED_FILTERING COMPLETE passed=(\d+) failed=(\d+)", output)
    passed_checks = int(complete[1]) if complete else 0
    failed_checks = int(complete[2]) if complete else 0
    expected_banner = "Metal 4.0 - Forward+" if mode == "metal" else "WebGPU 1.0 - Forward+"
    passed = expected_banner in output and not errors and not timed_out and passed_checks + failed_checks == 72
    passed &= process.returncode == 0 and failed_checks == 0
    result = {
        "mode": mode,
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
            line for line in output.splitlines() if line.startswith("SAMPLED_FILTERING ") and "COMPLETE" not in line
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
translation_checks = []
if args.tint_cli:
    for source in sorted((args.output / args.modes[0]).glob("*.spv")):
        conversion = subprocess.run(
            [str(args.tint_cli.resolve()), str(source.resolve())], text=True, capture_output=True, timeout=30
        )
        sampling = "textureSample" in conversion.stdout
        source_present = bool(re.search(r"\bvar\s+source_texture\s*:", conversion.stdout))
        overrides = len(re.findall(r"@id\(", conversion.stdout))
        expected_sampling = source.stem in ("filter_direct", "filter_helper")
        expected_source = not source.stem.endswith("pruned")
        valid = (
            conversion.returncode == 0
            and overrides == 0
            and sampling == expected_sampling
            and source_present == expected_source
        )
        translation_checks.append({
            "case": source.stem,
            "passed": valid,
            "sampling_in_default_variant": sampling,
            "source_in_default_variant": source_present,
            "override_count": overrides,
            "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        })
report = {
    "passed": all(run["passed"] for run in runs)
    and (not args.tint_cli or len(translation_checks) == 12 and all(check["passed"] for check in translation_checks)),
    "runs": runs,
    "translation_checks": translation_checks,
}
if args.tint_cli:
    report["tint_cli_sha256"] = hashlib.sha256(args.tint_cli.read_bytes()).hexdigest()
(args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
sys.exit(0 if report["passed"] else 1)
