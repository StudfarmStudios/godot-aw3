#!/usr/bin/env python3
"""Validate deferred font atlas uploads and cached color glyphs on the real GPU."""

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
parser.add_argument("--driver", default="webgpu", help="Use a different built driver to check immediate uploads")
parser.add_argument("--output", type=Path, default=Path(__file__).parent / "artifacts")
parser.add_argument("--benchmark", action="store_true")
parser.add_argument("--server", choices=["all", "advanced", "fallback"], default="all")
parser.add_argument("--baseline", action="store_true", help="Check immediate behavior in a pre-coalescing engine")
parser.add_argument("--timeout", type=int, default=120)
args = parser.parse_args()
project = Path(__file__).resolve().parent
font = project.parent.parent / "thirdparty/fonts/Inter_Regular.woff2"
args.output.mkdir(parents=True, exist_ok=True)
command = [
    str(args.engine.resolve()),
    "--path",
    str(project),
    "--rendering-method",
    "forward_plus",
    "--rendering-driver",
    args.driver,
    "--render-thread",
    "separate",
    "--",
    f"--font={font}",
    f"--server={args.server}",
]
if args.benchmark:
    command.append("--benchmark")
if args.baseline or args.driver != "webgpu":
    command.append("--immediate")
start = time.monotonic()
process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
timed_out = False
try:
    output, _ = process.communicate(timeout=args.timeout)
except subprocess.TimeoutExpired:
    timed_out = True
    process.terminate()
    try:
        output, _ = process.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        output, _ = process.communicate()
errors = [
    line
    for line in output.splitlines()
    if re.search(
        r"ERROR:|SCRIPT ERROR:|GPUValidationError|\[WebGPU.*(?:[Ee]rror|[Vv]alidation)|FONT_TEST FAIL|handle_crash|Program crashed",
        line,
    )
]
complete = re.search(r"FONT_TEST COMPLETE passed=(\d+) failed=(\d+)", output)
checks = int(complete[1]) + int(complete[2]) if complete else 0
benches = [
    json.loads(line.removeprefix("FONT_BENCH ")) for line in output.splitlines() if line.startswith("FONT_BENCH ")
]
expected = 1 if args.benchmark else (35 if args.server == "all" else 18)
passed = (
    process.returncode == 0
    and not timed_out
    and not errors
    and complete is not None
    and int(complete[2]) == 0
    and checks == expected
)
if args.driver == "webgpu":
    passed &= "WebGPU 1.0 - Forward+" in output
if args.benchmark:
    passed &= len(benches) == (2 if args.server == "all" else 1)
result = {
    "passed": passed,
    "checks": checks,
    "returncode": process.returncode,
    "timed_out": timed_out,
    "seconds": time.monotonic() - start,
    "host": platform.platform(),
    "engine_sha256": hashlib.sha256(args.engine.read_bytes()).hexdigest(),
    "command": command,
    "errors": errors,
    "benchmarks": benches,
}
(args.output / "run.log").write_text(output)
(args.output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result), flush=True)
sys.exit(0 if passed else 1)
