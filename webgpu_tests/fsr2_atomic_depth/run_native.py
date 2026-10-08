#!/usr/bin/env python3
"""Run actual-GPU tests of the production FSR2 SSBO atomic-depth callbacks."""

import argparse
import hashlib
import json
import platform
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("engine", type=Path)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--mode", choices=["native", "fallback", "both"], default="both")
parser.add_argument("--timeout", type=int, default=120)
parser.add_argument(
    "--include-root",
    type=Path,
    default=ROOT / "thirdparty/amd-fsr2/shaders",
    help="Production callback include directory; override for mutation checks",
)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
shaders = out / "shaders"
shaders.mkdir(exist_ok=True)
glslang = shutil.which("glslang")
assert glslang, "Install glslang to preprocess the production includes"
include_root = args.include_root.resolve()
for inverted in range(2):
    for operation in range(5):
        command = [
            glslang,
            "-E",
            "-S",
            "comp",
            "-I" + str(include_root),
            f"-DFFX_FSR2_OPTION_INVERTED_DEPTH={inverted}",
            f"-DTEST_OPERATION={operation}",
            str(PROJECT / "atomic_depth.comp"),
        ]
        compiled = subprocess.run(command, capture_output=True, text=True, timeout=30)
        if compiled.returncode:
            raise RuntimeError(compiled.stdout + compiled.stderr)
        (shaders / f"depth_{inverted}_{operation}.glsl").write_text(compiled.stdout)
engine_hash = hashlib.sha256(args.engine.read_bytes()).hexdigest()
header_hash = hashlib.sha256((include_root / "ffx_fsr2_callbacks_glsl.h").read_bytes()).hexdigest()
failed = False
for mode in ["native", "fallback"] if args.mode == "both" else [args.mode]:
    command = [
        str(args.engine.resolve()),
        "--path",
        str(PROJECT),
        "--rendering-method",
        "forward_plus",
        "--rendering-driver",
        "webgpu",
        "--script",
        str(PROJECT / "main.gd"),
        "--",
        "--shader-dir=" + str(shaders),
    ]
    if mode == "fallback":
        command += ["--webgpu-force-fallbacks"]
    start = time.monotonic()
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    timed_out = False
    try:
        log, _ = process.communicate(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        process.kill()
        log, _ = process.communicate()
    errors = [
        line
        for line in log.splitlines()
        if re.search(
            r"ERROR:|SCRIPT ERROR:|GPUValidationError|\[WebGPU.*(?:[Ee]rror|[Vv]alidation)|FSR2_ATOMIC FAIL|handle_crash|Program crashed",
            line,
        )
    ]
    complete = re.search(r"FSR2_ATOMIC COMPLETE passed=(\d+) failed=(\d+)", log)
    checks = int(complete[1]) + int(complete[2]) if complete else 0
    failed_checks = int(complete[2]) if complete else None
    passed = (
        "WebGPU 1.0 - Forward+" in log
        and process.returncode == 0
        and not timed_out
        and not errors
        and checks == 144
        and failed_checks == 0
    )
    result = {
        "mode": mode,
        "passed": passed,
        "checks": checks,
        "failed_checks": failed_checks,
        "returncode": process.returncode,
        "timed_out": timed_out,
        "seconds": time.monotonic() - start,
        "host": platform.platform(),
        "engine_sha256": engine_hash,
        "production_callback_sha256": header_hash,
        "command": command,
        "errors": errors,
    }
    (out / f"{mode}.log").write_text(log)
    (out / f"{mode}.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({**result, "errors": errors[:12], "error_count": len(errors)}), flush=True)
    failed |= not passed
sys.exit(int(failed))
