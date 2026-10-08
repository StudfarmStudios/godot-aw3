#!/usr/bin/env python3
"""Check particle shader cleanup during runtime and normal engine shutdown."""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", type=Path)
    parser.add_argument("--drivers", nargs="+", choices=["metal", "webgpu"], default=["metal", "webgpu"])
    parser.add_argument("--cases", nargs="+", choices=["runtime", "shutdown"], default=["runtime", "shutdown"])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    project = args.output / "project"
    shutil.copytree(Path(__file__).parent / "project", project, dirs_exist_ok=True)
    results = []
    for driver in args.drivers:
        for case in args.cases:
            name = f"{driver}-{case}"
            command = [
                str(args.engine.resolve()),
                "--path",
                str(project.resolve()),
                "--rendering-method",
                "forward_plus",
                "--rendering-driver",
                driver,
                "--resolution",
                "64x64",
                "--log-file",
                str((args.output / f"{name}-engine.log").resolve()),
                "--script",
                "probe.gd",
                "--",
                case,
            ]
            process = subprocess.run(command, capture_output=True, text=True, timeout=args.timeout)
            log = process.stdout + process.stderr
            (args.output / f"{name}.log").write_text(log)
            errors = [
                line
                for line in log.splitlines()
                if re.search(
                    r"ERROR:|SCRIPT ERROR|were leaked|were never freed|AddressSanitizer|UndefinedBehaviorSanitizer",
                    line,
                )
            ]
            matches = re.findall(r"^PARTICLE_LIFETIME_RESULT (.+)$", log, re.MULTILINE)
            probe = json.loads(matches[0]) if len(matches) == 1 else None
            result = {"driver": driver, "case": case, "exit_code": process.returncode, "probe": probe, "errors": errors}
            result["pass"] = process.returncode == 0 and not errors and bool(probe and probe["pass"])
            results.append(result)
            print(json.dumps(result), flush=True)
    result = {
        "engine_sha256": hashlib.sha256(args.engine.read_bytes()).hexdigest(),
        "cases": results,
        "all_pass": all(row["pass"] for row in results),
    }
    (args.output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    raise SystemExit(0 if result["all_pass"] else 1)


if __name__ == "__main__":
    main()
