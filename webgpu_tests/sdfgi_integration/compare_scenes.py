#!/usr/bin/env python3
"""Compare settled GI images and bounce energy (requires Pillow)."""

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageChops, ImageStat

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("reference", type=Path)
parser.add_argument("candidate", type=Path)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument(
    "--max-mae", type=float, default=1.0, help="Mean RGB byte error limit for initial and scrolled GI images"
)
parser.add_argument("--max-energy-delta", type=float, default=0.05)
args = parser.parse_args()
reference = json.loads((args.reference / "results.json").read_text())
candidate = json.loads((args.candidate / "results.json").read_text())
comparisons = {}
for name in ["disabled", "enabled", "scrolled"]:
    paths = [directory / (name + ".png") for directory in [args.reference, args.candidate]]
    images = [Image.open(path).convert("RGB") for path in paths]
    assert images[0].size == images[1].size
    difference = ImageChops.difference(*images)
    stats = ImageStat.Stat(difference)
    histogram = difference.histogram()
    combined = [sum(histogram[channel * 256 + value] for channel in range(3)) for value in range(256)]
    samples = sum(combined)
    cumulative = 0
    p95 = 255
    for value, count in enumerate(combined):
        cumulative += count
        if cumulative >= samples * 0.95:
            p95 = value
            break
    comparisons[name] = {
        "mae_rgb255": sum(stats.mean) / 3.0,
        "max_rgb255": max(high for low, high in stats.extrema),
        "p95_rgb255": p95,
        "reference_png_sha256": hashlib.sha256(paths[0].read_bytes()).hexdigest(),
        "candidate_png_sha256": hashlib.sha256(paths[1].read_bytes()).hexdigest(),
    }
energy_delta = abs(candidate["red_increase_sum"] - reference["red_increase_sum"]) / max(
    reference["red_increase_sum"], 1.0
)
report = {
    "passed": reference["passed"]
    and candidate["passed"]
    and all(comparisons[name]["mae_rgb255"] <= args.max_mae for name in ["enabled", "scrolled"])
    and energy_delta <= args.max_energy_delta,
    "reference_report": str((args.reference / "results.json").resolve()),
    "candidate_report": str((args.candidate / "results.json").resolve()),
    "reference_engine_sha256": reference["engine_sha256"],
    "candidate_engine_sha256": candidate["engine_sha256"],
    "relative_bounce_energy_error": energy_delta,
    "max_scene_mae_rgb255": args.max_mae,
    "max_relative_bounce_energy_error": args.max_energy_delta,
    "images": comparisons,
    "note": "Both settled initial and incrementally scrolled images must meet the fidelity threshold; nonzero indirect light alone is insufficient.",
}
args.output.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
raise SystemExit(0 if report["passed"] else 1)
