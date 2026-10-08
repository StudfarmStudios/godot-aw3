#!/usr/bin/env python3
"""Run FSR2 motion/luminance fixtures and compare actual GPU pixels across runs/backends."""
import argparse
from array import array
import hashlib
import json
import math
from pathlib import Path
import platform
import re
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("engine", type=Path)
parser.add_argument("--modes", nargs="+", choices=["native", "fallback", "metal"], default=["metal", "native", "fallback"])
parser.add_argument("--repeats", type=int, default=2)
parser.add_argument("--output", type=Path, default=Path(__file__).parent / "artifacts")
parser.add_argument("--timeout", type=int, default=180)
args = parser.parse_args()
project = Path(__file__).resolve().parent
args.output.mkdir(parents=True, exist_ok=True)
engine_hash = hashlib.file_digest(args.engine.open("rb"), "sha256").hexdigest()
runs = []
failed = False
for mode in args.modes:
    for repeat in range(args.repeats):
        run_id = f"{mode}-{repeat}"
        directory = args.output / run_id
        directory.mkdir(exist_ok=True)
        driver = "metal" if mode == "metal" else "webgpu"
        command = [str(args.engine.resolve()), "--path", str(project), "--rendering-method", "forward_plus",
                   "--rendering-driver", driver, "--disable-vsync", "--", "--temporal-output=" + str(directory.resolve())]
        if mode == "fallback":
            command.append("--webgpu-force-fallbacks")
        start = time.monotonic()
        timed_out = False
        with (directory / "run.log").open("w") as log:
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
        output = (directory / "run.log").read_text()
        errors = [line for line in output.splitlines() if re.search(r"ERROR:|SCRIPT ERROR:|GPUValidationError|handle_crash|Program crashed|FSR2_TEMPORAL FAIL|\[WebGPU.*(?:[Ee]rror|[Vv]alidation)", line)]
        complete = re.search(r"FSR2_TEMPORAL COMPLETE passed=(\d+) failed=(\d+) captures=(\d+)", output)
        checks = int(complete[1]) + int(complete[2]) if complete else 0
        failed_checks = int(complete[2]) if complete else None
        captures = int(complete[3]) if complete else 0
        expected_banner = "Metal 4.0 - Forward+" if mode == "metal" else "WebGPU 1.0 - Forward+"
        passed = expected_banner in output and process.returncode == 0 and not timed_out and not errors and checks == 90 and failed_checks == 0 and captures == 19
        result = {"run_id": run_id, "mode": mode, "repeat": repeat, "passed": passed, "checks": checks, "failed_checks": failed_checks, "captures": captures,
                  "returncode": process.returncode, "timed_out": timed_out, "seconds": time.monotonic() - start, "host": platform.platform(),
                  "engine_sha256": engine_hash, "command": command, "errors": errors}
        (directory / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps({**result, "errors": errors[:12], "error_count": len(errors)}), flush=True)
        runs.append(result)
        failed |= not passed

# Compare linear RGBA32F images; PNGs are only human-readable previews.
def compare(left, right):
    manifests = [json.loads((args.output / run_id / "manifest.json").read_text()) for run_id in (left, right)]
    captures = []
    for a, b in zip(manifests[0]["captures"], manifests[1]["captures"]):
        if (a["label"], a["width"], a["height"]) != (b["label"], b["width"], b["height"]):
            raise ValueError("Mismatched capture sequence")
        pixels = []
        for run_id in (left, right):
            values = array("f")
            values.frombytes((args.output / run_id / (a["label"] + ".rgba32f")).read_bytes())
            pixels.append(values)
        differences = [abs(x - y) for i, (x, y) in enumerate(zip(*pixels)) if i % 4 != 3]
        if len(differences) != a["width"] * a["height"] * 3 or not all(math.isfinite(x) for x in differences):
            raise ValueError("Invalid pixel buffer")
        differences.sort()
        captures.append({"label": a["label"], "mae": sum(differences) / len(differences), "p99": differences[int(len(differences) * 0.99)], "max": differences[-1],
                         "left_frame": a["draw_frame"], "right_frame": b["draw_frame"]})
    return {"left": left, "right": right, "captures": captures}

comparisons = []
for mode in args.modes:
    if args.repeats >= 2 and all((args.output / f"{mode}-{i}" / "manifest.json").exists() for i in [0, 1]):
        comparison = compare(f"{mode}-0", f"{mode}-1")
        comparison["kind"] = "repeat"
        # Repeated runs may differ at jittered edges due to FP reductions. These
        # bounds detect unstable history or widespread output changes.
        comparison["passed"] = all(c["mae"] <= 0.003 and c["p99"] <= 0.03 for c in comparison["captures"])
        failed |= not comparison["passed"]
        comparisons.append(comparison)
for mode in ("native", "fallback"):
    if all((args.output / f"{m}-0" / "manifest.json").exists() for m in ("metal", mode)):
        comparison = compare("metal-0", f"{mode}-0")
        comparison["kind"] = "metal_reference"
        # Backend/precision differences are reported rather than declared equal;
        # scene oracles and deterministic repeats are independent requirements.
        comparisons.append(comparison)
report = {"passed": not failed, "runs": runs, "comparisons": comparisons, "scope": "Bounded temporal scene checks; Metal comparisons are diagnostic, not a quality-parity claim."}
(args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"passed": not failed, "runs": len(runs), "comparisons": len(comparisons), "results": str(args.output / "results.json")}), flush=True)
sys.exit(1 if failed else 0)
