#!/usr/bin/env python3
import json
import pathlib
import sys


def load(path: pathlib.Path) -> dict:
    with (path / "metadata.json").open("r", encoding="utf-8") as handle:
        return json.load(handle)


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: compare.py REFERENCE_DIR RESULT_DIR [RESULT_DIR ...]", file=sys.stderr)
        return 2
    reference = load(pathlib.Path(sys.argv[1]))
    if reference.get("failures"):
        print(f"reference fixture failures: {reference['failures']}", file=sys.stderr)
        return 1
    failed = False
    keys = ("sha256", "foreground", "center_colors", "events", "config")
    for raw_path in sys.argv[2:]:
        path = pathlib.Path(raw_path)
        result = load(path)
        mismatches = [key for key in keys if result.get(key) != reference.get(key)]
        if result.get("failures") or mismatches:
            print(f"FAIL {path}: failures={result.get('failures')} mismatches={mismatches}")
            failed = True
        else:
            print(f"PASS {path}: {len(result['sha256'])} exact image hashes")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
