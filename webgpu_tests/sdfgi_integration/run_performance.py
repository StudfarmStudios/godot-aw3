#!/usr/bin/env python3
"""Measure bounded GI/control scenes; requires an exclusive idle GPU/CPU window."""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
from pathlib import Path
from typing import Any

P = Path(__file__).resolve().parent
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("baseline", type=Path)
p.add_argument("candidate", type=Path)
p.add_argument("--output", type=Path, required=True)
p.add_argument("--rounds", type=int, default=3)
p.add_argument("--frames", type=int, default=240)
a = p.parse_args()
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=True)
records = []


def run(
    label: str,
    engine: Path,
    driver: str,
    cascades: int,
    round_number: int,
    disabled: bool = False,
    fallback: bool = False,
) -> None:
    directory = out / f"{label}-{round_number}"
    command = [
        "python3",
        str(P / "run_scene.py"),
        str(engine.resolve()),
        "--driver",
        driver,
        "--cascades",
        str(cascades),
        "--benchmark-frames",
        str(a.frames),
        "--output",
        str(directory),
    ]
    if disabled:
        command += ["--benchmark-disabled-only"]
    if fallback:
        command += ["--fallback", "--no-float32-filterable"]
    process = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
    report = json.loads((directory / "results.json").read_text())
    if process.returncode or not report["passed"]:
        raise RuntimeError(process.stdout)
    metrics = report["scene_metrics"]
    timings = {}
    for name in ["disabled_timing", "enabled_timing"]:
        if name not in metrics:
            continue
        t = metrics[name]
        if t["pending_end"] != 0 or t["pipeline_count_start"] != t["pipeline_count_end"]:
            raise RuntimeError("Pipeline compilation entered timed region: " + label)
        timings[name] = {**t, "wall_ms_per_frame": t["total_ms"] / t["frames"]}
    record = {
        "label": label,
        "round": round_number,
        "report": str(directory / "results.json"),
        "engine_sha256": report["engine_sha256"],
        "timings": timings,
        "memory": {k: v for k, v in metrics.items() if k.endswith("_memory")},
    }
    records.append(record)
    print(label, round_number, {k: round(v["wall_ms_per_frame"], 4) for k, v in timings.items()}, flush=True)
    (out / "samples.json").write_text(json.dumps(records, indent=2) + "\n")


for round_number in range(a.rounds):
    pair = [("metal-old", a.baseline), ("metal-new", a.candidate)]
    if round_number % 2:
        pair.reverse()
    for label, engine in pair:
        run(label, engine, "metal", 4, round_number)
for round_number in range(a.rounds):
    pair = [("webgpu-disabled-old", a.baseline), ("webgpu-disabled-new", a.candidate)]
    if round_number % 2:
        pair.reverse()
    for label, engine in pair:
        run(label, engine, "webgpu", 4, round_number, disabled=True)
for round_number in range(a.rounds):
    cases = [
        ("webgpu-1", 1, False),
        ("webgpu-4", 4, False),
        ("webgpu-8", 8, False),
        ("webgpu-4-baseline-features", 4, True),
    ]
    if round_number % 2:
        cases.reverse()
    for label, n, fallback in cases:
        run(label, a.candidate, "webgpu", n, round_number, fallback=fallback)
summary: dict[str, Any] = {}
for label in sorted({r["label"] for r in records}):
    group_records = [r for r in records if r["label"] == label]
    summary[label] = {}
    for timing in ["disabled_timing", "enabled_timing"]:
        values = [r["timings"][timing]["wall_ms_per_frame"] for r in group_records if timing in r["timings"]]
        if values:
            summary[label][timing] = {"median_wall_ms_per_frame": statistics.median(values), "samples": values}
ratios = {}
for group, timing in [
    ("metal", "disabled_timing"),
    ("metal", "enabled_timing"),
    ("webgpu-disabled", "disabled_timing"),
]:
    old = [r for r in records if r["label"] == group + "-old"]
    new = [r for r in records if r["label"] == group + "-new"]
    values = [
        n["timings"][timing]["wall_ms_per_frame"] / o["timings"][timing]["wall_ms_per_frame"] for o, n in zip(old, new)
    ]
    ratios[group + "-" + timing] = {"median_paired_candidate_baseline": statistics.median(values), "ratios": values}
report = {
    "passed": True,
    "rounds": a.rounds,
    "frames": a.frames,
    "summary": summary,
    "preservation_ratios": ratios,
    "samples": records,
    "note": "Explicit idle window required. Wall samples include queued GPU completion, per-frame handoff, and viewport timestamp instrumentation. This small 128x128 synthetic scene is not browser or full-game FPS evidence. Baseline WebGPU did not support GI; only its GI-disabled control is compared.",
}
(out / "results.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"summary": summary, "preservation_ratios": ratios}, indent=2))
