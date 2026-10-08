#!/usr/bin/env python3
"""Prove the GPU regression rejects non-atomic writes and missing 2D bounds checks.

Only temporary copies of the production callback headers are mutated. A control
passes when the complete GPU suite runs without engine errors and rejects the
incorrect numerical behavior. A crash, timeout or compilation failure fails it.
"""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("engine", type=Path)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
mutations = {
    "last-writer": [
        ("atomicMax(rw_reconstructed_depth_values[index], uDepth);", "rw_reconstructed_depth_values[index] = uDepth;"),
        ("atomicMin(rw_reconstructed_depth_values[index], uDepth);", "rw_reconstructed_depth_values[index] = uDepth;"),
    ],
    "no-bounds": [
        ("if (any(lessThan(iPxPos, ivec2(0))) || any(greaterThanEqual(iPxPos, MaxRenderSize()))) {", "if (false) {"),
        ("if (any(lessThan(iPxSample, ivec2(0))) || any(greaterThanEqual(iPxSample, MaxRenderSize()))) {", "if (false) {"),
        ("if (all(greaterThanEqual(iPxSample, ivec2(0))) && all(lessThan(iPxSample, MaxRenderSize()))) {", "if (true) {"),
    ],
}
results = []
for name, replacements in mutations.items():
    destination = output / name
    headers = destination / "headers"
    shutil.copytree(ROOT / "thirdparty/amd-fsr2/shaders", headers, dirs_exist_ok=True)
    header = headers / "ffx_fsr2_callbacks_glsl.h"
    text = header.read_text()
    for before, after in replacements:
        assert text.count(before) == 1, f"Production source changed: recheck {name} mutation"
        text = text.replace(before, after)
    header.write_text(text)
    process = subprocess.run([sys.executable, str(PROJECT / "run_native.py"), str(args.engine.resolve()),
                              "--output", str(destination), "--mode", "native", "--include-root", str(headers)],
                             capture_output=True, text=True, timeout=150)
    (destination / "runner.log").write_text(process.stdout + process.stderr)
    result = json.loads((destination / "native.json").read_text())
    expected_failure = (process.returncode == 1 and result["returncode"] == 1 and not result["timed_out"]
                        and result["checks"] == 144 and result["failed_checks"] > 0
                        and len(result["errors"]) == result["failed_checks"]
                        and all(line.startswith("FSR2_ATOMIC FAIL") for line in result["errors"]))
    results.append({"mutation": name, "passed": expected_failure, "rejected_checks": result["failed_checks"],
                    "engine_sha256": result["engine_sha256"], "mutated_callback_sha256": result["production_callback_sha256"]})
report = {"passed": all(result["passed"] for result in results), "results": results}
(output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report))
sys.exit(0 if report["passed"] else 1)
