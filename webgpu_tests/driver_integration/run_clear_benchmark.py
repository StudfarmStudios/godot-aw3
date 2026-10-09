#!/usr/bin/env python3
"""Compare local-device clear submission + GPU completion, alternating binaries."""

import argparse
import hashlib
import json
import re
import statistics
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("baseline", type=Path)
parser.add_argument("candidate", type=Path)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--rounds", type=int, default=5)
args = parser.parse_args()
project = Path(__file__).resolve().parent
engines = {"baseline": args.baseline.resolve(), "candidate": args.candidate.resolve()}
hashes = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in engines.items()}
results = []
args.output.parent.mkdir(parents=True, exist_ok=True)


def run(name, mode, round_index):
    command = [
        str(engines[name]),
        "--path",
        str(project),
        "--script",
        "benchmark_clears.gd",
        "--rendering-driver",
        "webgpu",
        "--rendering-method",
        "forward_plus",
    ]
    if mode == "color":
        command += ["--", "--bench-color"]
    process = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
    log = args.output.with_name(f"{args.output.stem}-{name}-{mode}-{round_index}.log")
    log.write_text(process.stdout)
    found = re.search(r"^CLEAR_BENCH (.*)$", process.stdout, re.MULTILINE)
    if process.returncode or not found or re.search(r"ERROR:|SCRIPT ERROR:|GPUValidationError", process.stdout):
        raise RuntimeError(f"Benchmark failed; inspect {log}")
    result = json.loads(found[1]) | {"engine": name, "round": round_index, "sha256": hashes[name]}
    results.append(result)
    print(json.dumps(result), flush=True)


for i in range(args.rounds):
    for name in ["baseline", "candidate"] if i % 2 == 0 else ["candidate", "baseline"]:
        run(name, "depth", i)
# The old color path is incorrect; do not present it as a valid performance baseline.
for i in range(3):
    run("candidate", "color", i)
summary = {
    "baseline_depth_median_ms": statistics.median(r["median_ms"] for r in results if r["engine"] == "baseline"),
    "candidate_depth_median_ms": statistics.median(
        r["median_ms"] for r in results if r["engine"] == "candidate" and r["mode"] == "depth"
    ),
    "candidate_color_median_ms": statistics.median(r["median_ms"] for r in results if r["mode"] == "color"),
}
ratios = []
for i in range(args.rounds):
    pair = {r["engine"]: r["median_ms"] for r in results if r["mode"] == "depth" and r["round"] == i}
    ratios.append(pair["candidate"] / pair["baseline"])
summary["paired_depth_ratio_median"] = statistics.median(ratios)
args.output.write_text(json.dumps({"summary": summary, "results": results}, indent=2) + "\n")
print(json.dumps(summary), flush=True)
