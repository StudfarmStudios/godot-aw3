#!/usr/bin/env python3
"""Verify dynamic renderer bindings with transform/color changes across real frames."""

import argparse
import hashlib
import json
import platform
import re
import subprocess
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", type=Path)
    parser.add_argument("--modes", nargs="+", choices=["native", "fallback", "metal"], default=["native", "fallback"])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    runs = []
    for mode in args.modes:
        command = [
            str(args.engine.resolve()),
            "--path",
            str(Path(__file__).resolve().parent),
            "--rendering-method",
            "forward_plus",
            "--rendering-driver",
            "metal" if mode == "metal" else "webgpu",
            "--render-thread",
            "separate",
            "--disable-vsync",
        ]
        if mode == "fallback":
            command += ["--", "--webgpu-force-fallbacks", "--webgpu-no-float32-filterable"]
        timed_out = False
        log_path = args.output / f"{mode}.log"
        with log_path.open("w") as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            try:
                process.wait(timeout=90)
            except subprocess.TimeoutExpired:
                timed_out = True
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        output = log_path.read_text()
        errors = [
            line
            for line in output.splitlines()
            if re.search(
                r"ERROR:|SCRIPT ERROR:|GPUValidationError|handle_crash|Program crashed|\[WebGPU.*(?:[Ee]rror|[Vv]alidation)",
                line,
            )
        ]
        match = re.search(r"DYNAMIC_BIND_GROUP COMPLETE passed=(\d+) failed=(\d+)", output)
        checks = int(match[1]) if match else 0
        failed = int(match[2]) if match else 0
        expected_banner = "Metal 4.0 - Forward+" if mode == "metal" else "WebGPU 1.0 - Forward+"
        valid = (
            process.returncode == 0
            and not timed_out
            and not errors
            and checks == 192
            and failed == 0
            and expected_banner in output
        )
        runs.append({
            "mode": mode,
            "passed": valid,
            "checks": checks,
            "failed_checks": failed,
            "returncode": process.returncode,
            "timed_out": timed_out,
            "errors": errors,
            "command": command,
        })
    report = {
        "passed": all(run["passed"] for run in runs),
        "host": platform.platform(),
        "engine_sha256": hashlib.sha256(args.engine.read_bytes()).hexdigest(),
        "runs": runs,
    }
    (args.output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if not report["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
