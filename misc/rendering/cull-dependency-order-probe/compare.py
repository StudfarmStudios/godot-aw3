#!/usr/bin/env python3
import json
import sys
from pathlib import Path


def load(path: str) -> dict:
    root = Path(path)
    with (root / "metadata.json").open(encoding="utf-8") as handle:
        data = json.load(handle)
    if data.get("failures"):
        raise SystemExit(f"{root}: fixture failures: {data['failures']}")
    expected = {"0", "1", "2", "4", "8"}
    actual = set(data.get("sha256", {}))
    if actual != expected:
        raise SystemExit(f"{root}: capture keys {sorted(actual)} != {sorted(expected)}")
    return data


def main() -> int:
    if len(sys.argv) < 3:
        print(f"usage: {Path(sys.argv[0]).name} RESULT_DIR RESULT_DIR [RESULT_DIR ...]", file=sys.stderr)
        return 2
    runs = [(Path(path), load(path)) for path in sys.argv[1:]]
    reference_path, reference = runs[0]
    comparable_keys = ("sha256", "foreground", "sample_colors", "events")
    failed = False
    for path, candidate in runs[1:]:
        for key in comparable_keys:
            if candidate.get(key) != reference.get(key):
                print(f"MISMATCH {key}: {reference_path} != {path}")
                failed = True
    if failed:
        return 1
    print(f"CULL_DEPENDENCY_ORDER_COMPARE PASS runs={len(runs)} frames={len(reference['sha256'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
