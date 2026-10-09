#!/usr/bin/env python3
"""Check actual graphics-stage access and explicit rejection of unsupported RW snapshots."""

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("engine", type=Path)
parser.add_argument("--modes", nargs="+", choices=["native", "fallback"], default=["native", "fallback"])
parser.add_argument(
    "--cases",
    nargs="+",
    choices=["vertex_read", "fragment_read", "fragment_rw", "fragment_rg_rw", "unused_rg_rw"],
    default=["vertex_read", "fragment_read", "fragment_rw", "fragment_rg_rw", "unused_rg_rw"],
)
parser.add_argument("--output", type=Path, default=Path(__file__).parent / "artifacts/graphics")
args = parser.parse_args()
project = Path(__file__).resolve().parent
args.output.mkdir(parents=True, exist_ok=True)
runs = []
for mode in args.modes:
    for case in args.cases:
        rejection = case == "fragment_rg_rw" or (mode == "fallback" and case == "fragment_rw")
        command = [
            str(args.engine.resolve()),
            "--path",
            str(project),
            "--script",
            "res://graphics.gd",
            "--rendering-method",
            "forward_plus",
            "--rendering-driver",
            "webgpu",
            "--",
            "--graphics-case=" + case,
        ]
        if mode == "fallback":
            command.append("--webgpu-force-fallbacks")
        if rejection:
            command.append("--expect-rejection")
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=90)
            output = result.stdout + result.stderr
            returncode = result.returncode
        except subprocess.TimeoutExpired as error:
            output = str(error)
            returncode = -1
        (args.output / (mode + "-" + case + ".log")).write_text(output)
        errors = [
            line
            for line in output.splitlines()
            if re.search(r"ERROR:|GPUValidationError|handle_crash|Program crashed|SPECIALIZATION_GRAPHICS FAIL", line)
        ]
        unexpected = errors
        guard = "WebGPU: split read/write storage textures require a compute stage" in output
        if rejection:
            unexpected = [
                line
                for line in errors
                if not (
                    "WebGPU: split read/write storage textures require a compute stage" in line
                    or any(
                        'Condition "' + condition + '" is true.' in line
                        for condition in [
                            "!_ensure_shader_layout(p_shader)",
                            "!_ensure_shader_modules(shader)",
                            "!pipeline.driver_id",
                        ]
                    )
                )
            ]
        complete = re.search(r"SPECIALIZATION_GRAPHICS COMPLETE passed=(\d+) failed=(\d+)", output)
        checks = int(complete[1]) if complete else 0
        passed = (
            returncode == 0
            and not unexpected
            and complete is not None
            and int(complete[2]) == 0
            and checks == (1 if rejection else 3)
            and guard == rejection
        )
        run = {
            "mode": mode,
            "case": case,
            "expected_rejection": rejection,
            "passed": passed,
            "checks": checks,
            "returncode": returncode,
            "errors": errors,
            "unexpected_errors": unexpected,
        }
        runs.append(run)
        print(json.dumps(run), flush=True)
report = {
    "passed": all(run["passed"] for run in runs),
    "engine_sha256": hashlib.sha256(args.engine.read_bytes()).hexdigest(),
    "runs": runs,
}
(args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
sys.exit(0 if report["passed"] else 1)
