#!/usr/bin/env python3
"""Compare two particle-visual-probe metadata files without dependencies."""

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
    if len(sys.argv) != 3:
        print("usage: compare.py RUN_A[/metadata.json] RUN_B[/metadata.json]", file=sys.stderr)
        return 2

    path_a, a = load(sys.argv[1])
    path_b, b = load(sys.argv[2])
    required_equal = (
        "format",
        "rendering_method",
        "rendering_driver",
        "adapter",
        "viewport",
        "required_fixed_fps",
        "prewarm_frames",
        "capture_frames",
        "seeds",
        "taa",
        "no_taa",
        "coverage",
        "skipped_coverage",
    )
    failed = False
    for key in required_equal:
        if a.get(key) != b.get(key):
            failed = True
            print(f"CONFIG_MISMATCH {key}: {a.get(key)!r} != {b.get(key)!r}")

    hashes_a = a.get("sha256", {})
    hashes_b = b.get("sha256", {})
    frames = sorted(set(hashes_a) | set(hashes_b), key=lambda value: int(value))
    for frame in frames:
        digest_a = hashes_a.get(frame)
        digest_b = hashes_b.get(frame)
        if digest_a == digest_b and digest_a is not None:
            print(f"FRAME {int(frame):03d} MATCH {digest_a}")
        else:
            failed = True
            print(f"FRAME {int(frame):03d} MISMATCH {digest_a} != {digest_b}")

    if len(frames) != len(a.get("capture_frames", [])):
        failed = True
        print(f"FRAME_COUNT_MISMATCH compared={len(frames)} expected={len(a.get('capture_frames', []))}")

    print(f"PARTICLE_VISUAL_COMPARE {'FAIL' if failed else 'PASS'} a={path_a} b={path_b}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
