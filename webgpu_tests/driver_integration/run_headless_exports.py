#!/usr/bin/env python3
"""Check headless import and repeated export-pack teardown on the actual editor."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("engine", type=Path)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
project = Path(__file__).resolve().parent
base = [str(args.engine.resolve()), "--headless", "--path", str(project)]
checks = []
for index in range(4):
    pack = args.output / f"regressions-{index}.pck"
    label = "import" if index == 0 else f"export-{index}"
    command = base + (["--editor", "--import", "--quit"] if index == 0 else ["--export-pack", "WebGPU regression pack", str(pack.resolve())])
    process = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
    (args.output / f"{label}.log").write_text(process.stdout)
    errors = [line for line in process.stdout.splitlines() if re.search(r"ERROR:|SCRIPT ERROR:|handle_crash:|Program crashed", line)]
    pack_ok = index == 0 or (pack.is_file() and pack.stat().st_size > 32 and pack.open("rb").read(4) == b"GDPC")
    result = {"step": label, "returncode": process.returncode, "pack_ok": pack_ok, "errors": errors}
    checks.append(result)
    print(json.dumps(result), flush=True)
    if process.returncode or errors or not pack_ok:
        raise RuntimeError(f"Headless {label} failed; inspect {args.output}")
result = {"passed": True, "engine_sha256": hashlib.file_digest(args.engine.open("rb"), "sha256").hexdigest(), "checks": checks}
(args.output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
