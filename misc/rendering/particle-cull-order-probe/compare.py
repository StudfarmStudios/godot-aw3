#!/usr/bin/env python3
"""Compare particle-cull-order captures for exact equality or a positive mismatch."""

import argparse
import json
import pathlib
import sys
from typing import Any


def load(argument: str) -> tuple[pathlib.Path, dict[str, Any]]:
    path = pathlib.Path(argument)
    if path.is_dir():
        path /= "metadata.json"
    with path.open(encoding="utf-8") as handle:
        return path, json.load(handle)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("expect", choices=("equal", "different"))
    parser.add_argument("run_a")
    parser.add_argument("run_b")
    args = parser.parse_args()

    path_a, a = load(args.run_a)
    path_b, b = load(args.run_b)
    failed = False
    required_equal = (
        "format",
        "rendering_method",
        "rendering_driver",
        "adapter",
        "filler_instance_count",
        "viewports",
        "viewport_size",
        "required_fixed_fps",
        "prewarm_frames",
        "pipeline_quiescent_frames",
        "confirmed_draws",
        "capture_frames",
        "seeds",
        "particle_amounts",
        "coverage",
    )
    for key in required_equal:
        if a.get(key) != b.get(key):
            failed = True
            print(f"CONFIG_MISMATCH {key}: {a.get(key)!r} != {b.get(key)!r}")

    mismatches = 0
    comparisons = 0
    expected_frames = {str(frame) for frame in a.get("capture_frames", [])}
    expected_views = set(a.get("viewports", []))
    for view in sorted(expected_views):
        hashes_a = a.get("sha256", {}).get(view, {})
        hashes_b = b.get("sha256", {}).get(view, {})
        if set(hashes_a) != expected_frames or set(hashes_b) != expected_frames:
            failed = True
            print(
                f"FRAME_SET_MISMATCH view={view} "
                f"a={sorted(hashes_a)} b={sorted(hashes_b)} expected={sorted(expected_frames)}"
            )
        for frame in sorted(expected_frames, key=int):
            digest_a = hashes_a.get(frame)
            digest_b = hashes_b.get(frame)
            comparisons += 1
            if digest_a == digest_b and digest_a is not None:
                print(f"FRAME {view} {int(frame):03d} MATCH {digest_a}")
            else:
                mismatches += 1
                print(f"FRAME {view} {int(frame):03d} MISMATCH {digest_a} != {digest_b}")

    if comparisons != len(expected_frames) * len(expected_views):
        failed = True
        print(f"COMPARISON_COUNT_MISMATCH {comparisons}")
    if args.expect == "equal" and mismatches:
        failed = True
    if args.expect == "different" and mismatches == 0:
        failed = True
        print("POSITIVE_CONTROL_FAILED: runs were exactly equal")

    print(
        f"PARTICLE_CULL_ORDER_COMPARE {'FAIL' if failed else 'PASS'} "
        f"expect={args.expect} comparisons={comparisons} mismatches={mismatches} a={path_a} b={path_b}"
    )
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
