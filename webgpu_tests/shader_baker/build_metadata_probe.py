#!/usr/bin/env python3
"""Link a private metadata oracle from an already-built matching Tint CLI's objects."""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
objects = [
    root / "drivers/webgpu/tint_cli/.build/cli/spirv_preprocess.o",
    *sorted((root / "drivers/webgpu/tint_cli/.build/spirv_tools").rglob("*.o")),
]
if len(objects) < 2 or not all(path.is_file() for path in objects):
    raise SystemExit("Build the matching native Tint CLI first; this helper never builds shared objects")
copied = []
for index, path in enumerate(objects):
    destination = output / (str(index) + ".o")
    shutil.copyfile(path, destination)
    copied.append(str(destination))
command = [os.environ.get("CXX", "c++"), "-std=c++17"]
if sys.platform == "darwin":
    command += ["-isysroot", subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()]
command += [
    "-I" + str(root / "drivers/webgpu/tint_cli"),
    "-I" + str(root),
    str(Path(__file__).with_name("metadata_probe.cpp")),
    *copied,
]
command += ["-Wl,-dead_strip" if sys.platform == "darwin" else "-Wl,--gc-sections", "-o", str(output / "probe")]
subprocess.run(command, check=True)
(output / "build.json").write_text(
    json.dumps(
        {
            "command": command,
            "objects": {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in objects},
            "probe_sha256": hashlib.sha256((output / "probe").read_bytes()).hexdigest(),
        },
        indent=2,
    )
    + "\n"
)
print(output / "probe")
