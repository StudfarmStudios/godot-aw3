#!/usr/bin/env python3
"""Stress shared WGSL caches across four local RDs while the main renderer draws."""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import time
import uuid
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("engine", type=Path)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
output = args.output.resolve()
project = output / "project"
project.mkdir(parents=True)
source = Path(__file__).parent
shutil.copyfile(source / "cache_threads.gd", project / "cache_threads.gd")
(project / "project.godot").write_text(
    (source / "project.godot")
    .read_text()
    .replace("WebGPU shader baker regressions", "WebGPU-cache-threads-" + uuid.uuid4().hex)
)
command = [
    str(args.engine.resolve()),
    "--path",
    str(project),
    "--rendering-driver",
    "webgpu",
    "--rendering-method",
    "forward_plus",
    "--render-thread",
    "separate",
    "--verbose",
    "--script",
    "res://cache_threads.gd",
]
started = time.monotonic()
run = subprocess.run(command, text=True, capture_output=True, timeout=200)
log = run.stdout + run.stderr
(output / "run.log").write_text(log)
errors = [
    line for line in log.splitlines() if re.search(r"ERROR:|SCRIPT ERROR:|GPUValidationError|Program crashed", line)
]
complete = re.search(r"CACHE_THREADS COMPLETE results=\[true, true, true, true\] frames=(\d+)", log)
result = {
    "passed": run.returncode == 0 and not errors and complete is not None and int(complete[1]) > 1,
    "engine_sha256": hashlib.sha256(args.engine.read_bytes()).hexdigest(),
    "command": command,
    "returncode": run.returncode,
    "errors": errors,
    "seconds": time.monotonic() - started,
    "local_rendering_devices": 4,
    "verified_compute_dispatches": 160,
    "main_frames": int(complete[1]) if complete else 0,
    "limitation": "Concurrency stress with GPU value checks; not a ThreadSanitizer proof",
}
(output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result), flush=True)
raise SystemExit(0 if result["passed"] else 1)
