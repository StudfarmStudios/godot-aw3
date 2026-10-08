#!/usr/bin/env python3
"""Compare seeded shader-layout initialization with and without float32 filtering."""

import argparse
import hashlib
import json
import platform
import re
import shutil
import statistics
import subprocess
import sys
from pathlib import Path

CASES = [
    ("hiz", "screen_space_reflection_hiz.glsl", "", ["s:r32", "i:r32"]),
    (
        "hiz_odd",
        "screen_space_reflection_hiz.glsl",
        "#define MODE_ODD_WIDTH\n#define MODE_ODD_HEIGHT",
        ["s:r32", "i:r32"],
    ),
    ("downsample", "screen_space_reflection_downsample.glsl", "", ["s:r32", "s:rgba8", "i:r32", "i:rgba8"]),
    (
        "trace",
        "screen_space_reflection.glsl",
        "",
        ["s:rgba16", "s:r32", "s:rgba8", "i:rgba16", "i:r8", "u:scene"],
    ),
    ("filter", "screen_space_reflection_filter.glsl", "", ["s:rgba16", "i:rgba16"]),
    (
        "resolve",
        "screen_space_reflection_resolve.glsl",
        "",
        ["s:r32", "s:rgba8", "s:r32", "s:rgba8", "s:rgba16", "s:r8", "i:rgba16"],
    ),
]
FIELDS = ("shader_create_us", "fresh_layout_uniform_us", "reused_layout_uniform_us")
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("engine", type=Path)
parser.add_argument("--output", type=Path, default=Path(__file__).parent / "artifacts")
parser.add_argument("--pairs", type=int, default=3)
parser.add_argument("--batches", type=int, default=7)
parser.add_argument("--iterations", type=int, default=32)
parser.add_argument("--timeout", type=int, default=180)
parser.add_argument("--prepare-only", action="store_true")
args = parser.parse_args()
if min(args.pairs, args.batches, args.iterations) < 1:
    parser.error("pairs, batches and iterations must be positive")
fixture = Path(__file__).resolve().parent
root = fixture.parent.parent
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
project = output / "project"
project.mkdir(exist_ok=True)
for name in ("project.godot", "main.gd"):
    shutil.copyfile(fixture / name, project / name)
stages = []
for name, filename, defines, bindings in CASES:
    original = root / "servers/rendering/renderer_rd/shaders/effects" / filename
    source = original.read_text()
    if "#include" in source or source.count("#VERSION_DEFINES") != 1:
        raise RuntimeError(f"Review benchmark source preparation after changes to {original}")
    prepared = source.replace("#[compute]", "").replace("#VERSION_DEFINES", defines)
    shader = project / (name + ".glsl")
    shader.write_text(prepared)
    stages.append({
        "name": name,
        "path": str(shader),
        "bindings": bindings,
        "source": str(original.relative_to(root)),
        "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
        "prepared_sha256": hashlib.sha256(prepared.encode()).hexdigest(),
    })
manifest = {"stages": stages, "batches": args.batches, "iterations": args.iterations}
(output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
if args.prepare_only:
    print(json.dumps({"prepared": len(stages), "project": str(project)}))
    sys.exit(0)

runs = []
for pair in range(args.pairs):
    for mode in ("native", "nofilter") if pair % 2 == 0 else ("nofilter", "native"):
        name = f"{pair + 1}-{mode}"
        config = output / (name + ".json")
        config.write_text(json.dumps({**manifest, "mode": mode}) + "\n")
        command = [
            str(args.engine.resolve()),
            "--path",
            str(project),
            "--rendering-method",
            "forward_plus",
            "--rendering-driver",
            "webgpu",
            "--disable-vsync",
            "--script",
            "res://main.gd",
            "--",
            "--bench-config=" + str(config),
        ]
        if mode == "nofilter":
            command.append("--webgpu-no-float32-filterable")
        timed_out = False
        log_path = output / (name + ".log")
        with log_path.open("w") as log:
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
        log_text = log_path.read_text()
        errors = [
            line
            for line in log_text.splitlines()
            if re.search(
                r"ERROR:|SCRIPT ERROR:|GPUValidationError|handle_crash|Program crashed|was leaked|\[WebGPU.*(?:[Ee]rror|[Vv]alidation)",
                line,
            )
        ]
        payloads = [
            line.removeprefix("LAYOUT_BENCH_RESULT ")
            for line in log_text.splitlines()
            if line.startswith("LAYOUT_BENCH_RESULT ")
        ]
        result = json.loads(payloads[0]) if len(payloads) == 1 else {"passed": False, "samples": []}
        omission = "float32-filterable feature NOT available" in log_text
        valid = (
            result["passed"]
            and process.returncode == 0
            and not timed_out
            and not errors
            and "WebGPU 1.0 - Forward+" in log_text
            and omission == (mode == "nofilter")
            and len(result["samples"]) == len(stages) * args.batches
        )
        run = {
            "pair": pair + 1,
            "mode": mode,
            "passed": valid,
            "returncode": process.returncode,
            "timed_out": timed_out,
            "errors": errors,
            "float32_filterable_omitted": omission,
            "samples": result["samples"],
            "command": command,
        }
        runs.append(run)
        print(json.dumps({key: value for key, value in run.items() if key != "samples"}), flush=True)
        if not valid:
            break
    if not runs[-1]["passed"]:
        break

summaries = []
for stage_case in CASES:
    name = stage_case[0]
    for field in FIELDS:
        per_pair = []
        for pair in range(1, args.pairs + 1):
            medians = {}
            for mode in ("native", "nofilter"):
                values = [
                    sample[field] / sample["iterations"]
                    for run in runs
                    if run["passed"] and run["pair"] == pair and run["mode"] == mode
                    for sample in run["samples"]
                    if sample["stage"] == name
                ]
                if values:
                    medians[mode] = statistics.median(values)
            if len(medians) == 2:
                per_pair.append({
                    "pair": pair,
                    "native_us_per_creation": medians["native"],
                    "nofilter_us_per_creation": medians["nofilter"],
                    "additional_us": medians["nofilter"] - medians["native"],
                    "ratio": medians["nofilter"] / medians["native"] if medians["native"] else None,
                })
        if per_pair:
            summaries.append({
                "stage": name,
                "measurement": field,
                "paired_median_additional_us": statistics.median(item["additional_us"] for item in per_pair),
                "pairs": per_pair,
            })
report = {
    "passed": len(runs) == args.pairs * 2 and all(run["passed"] for run in runs),
    "scope": "Native seeded CPU layout initialization; excludes GLSL compilation, shader pipelines, GPU work and deferred frees. Capability omission changes both source analysis and layout contracts; this is not a parser-only timing or browser startup benchmark.",
    "host": platform.platform(),
    "engine_sha256": hashlib.sha256(args.engine.read_bytes()).hexdigest(),
    "manifest": manifest,
    "runs": runs,
    "summaries": summaries,
}
(output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
sys.exit(0 if report["passed"] else 1)
