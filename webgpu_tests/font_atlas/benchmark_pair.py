#!/usr/bin/env python3
"""Alternate baseline/candidate font upload trials with GPU completion included.

The Advanced server is used for both binaries because baseline builds commonly
omit Fallback. Each trial creates 16 fresh fonts, adds 94 glyphs individually,
generates mipmaps, submits the frame, and reads every resulting GPU mip. Four
warm-up font batches are excluded, then 12 batch times are retained. The result
reports paired ratios as well as absolute medians; run without other GPU work.
"""

import argparse
import json
import statistics
import subprocess
import sys
from pathlib import Path
from typing import Any

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("baseline", type=Path)
parser.add_argument("candidate", type=Path)
parser.add_argument("--trials", type=int, default=3)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
runner = Path(__file__).with_name("run_native.py")
results: dict[str, list[dict[str, Any]]] = {"baseline": [], "candidate": []}
for trial in range(args.trials):
    for label in ["baseline", "candidate"] if trial % 2 == 0 else ["candidate", "baseline"]:
        directory = args.output / f"{trial}-{label}"
        subprocess.run(
            [
                sys.executable,
                str(runner),
                str(getattr(args, label)),
                "--benchmark",
                "--server",
                "advanced",
                "--output",
                str(directory),
            ],
            check=True,
        )
        result = json.loads((directory / "result.json").read_text())
        results[label].append(result)
medians = {label: [trial["benchmarks"][0]["median_ms"] for trial in trials] for label, trials in results.items()}
paired_ratios = [candidate / baseline for candidate, baseline in zip(medians["candidate"], medians["baseline"])]
summary = {
    "trials": results,
    "median_trial_ms": {k: statistics.median(v) for k, v in medians.items()},
    "paired_candidate_baseline_ratios": paired_ratios,
    "median_paired_ratio": statistics.median(paired_ratios),
}
(args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps({k: v for k, v in summary.items() if k != "trials"}), flush=True)
