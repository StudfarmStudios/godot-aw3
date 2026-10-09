#!/usr/bin/env python3
"""Verify valid image semantics that cannot be lowered are rejected without aborting."""

import argparse
import hashlib
import json
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--tint", type=Path, required=True)
parser.add_argument("--corpus", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
source = subprocess.check_output(["spirv-dis", str(args.corpus / "integer_image_u.comp.1.5.spv")], text=True)
assert "ZeroExtend" in source
cases = {
    "unsigned_sign_extension": (
        source.replace("ZeroExtend", "SignExtend").replace("Rgba8ui", "Rgba8i"),
        "extension must match",
    ),
    "volatile_image_access": (
        source
        .replace("OpCapability Shader", "OpCapability Shader\nOpCapability VulkanMemoryModel")
        .replace("OpMemoryModel Logical GLSL450", "OpMemoryModel Logical Vulkan")
        .replace("ZeroExtend", "ZeroExtend|VolatileTexel"),
        "unsupported image operand semantics",
    ),
}
records = []
for name, (assembly, diagnostic) in cases.items():
    text = args.output / (name + ".spvasm")
    text.write_text(assembly)
    binary = text.with_suffix(".spv")
    subprocess.run(["spirv-as", "--target-env", "spv1.5", str(text), "-o", str(binary)], check=True)
    subprocess.run(["spirv-val", "--target-env", "vulkan1.2", str(binary)], check=True)
    result = subprocess.run([str(args.tint.resolve()), str(binary)], capture_output=True, text=True, timeout=60)
    record = {
        "name": name,
        "passed": result.returncode > 0 and diagnostic in result.stderr,
        "returncode": result.returncode,
        "diagnostic": result.stderr.strip(),
    }
    records.append(record)
    print(json.dumps(record), flush=True)
report = {
    "passed": all(r["passed"] for r in records),
    "checks": len(records),
    "tint_sha256": hashlib.sha256(args.tint.read_bytes()).hexdigest(),
    "results": records,
}
(args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
raise SystemExit(not report["passed"])
