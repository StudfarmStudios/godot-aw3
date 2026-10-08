#!/usr/bin/env python3
"""Measure native R8 image-kernel versus WebGPU packed-buffer GPU readbacks.

Run run_occlusion.py normally and with --texture-reference first. Differences
are reported at both intermediate UNORM8 and original final UNORM4 precision;
this comparison does not assert bit-identical arithmetic across GPU backends.
"""

import argparse
import json
import struct
from pathlib import Path


def unorm4(value):
    """Original GLSL: uint(clamp((float(value) / 255.0) * 15.0, 0, 15))."""

    def f32(number):
        return struct.unpack("f", struct.pack("f", number))[0]

    return int(f32(f32(value / 255.0) * 15.0))


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("buffer_output", type=Path)
parser.add_argument("texture_output", type=Path)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
buffer_report = json.loads((args.buffer_output / "results.json").read_text())
texture_report = json.loads((args.texture_output / "results.json").read_text())
assert buffer_report["passed"] and texture_report["passed"]
assert not buffer_report["texture_reference"] and texture_report["texture_reference"]
assert buffer_report["shader_sha256"] == texture_report["shader_sha256"]

results = []
for case in json.loads((args.buffer_output / "cases.json").read_text()):
    name = case["name"]
    count = (args.buffer_output / (name + ".expected")).stat().st_size
    buffer_values = (args.buffer_output / (name + ".actual")).read_bytes()[:count]
    texture_values = (args.texture_output / (name + ".actual")).read_bytes()[:count]
    assert len(buffer_values) == len(texture_values) == count
    assert (args.buffer_output / (name + ".facing")).read_bytes() == (
        args.texture_output / (name + ".facing")
    ).read_bytes()
    differences = [abs(a - b) for a, b in zip(buffer_values, texture_values)]
    # The original MODE_STORE truncates each normalized component to four bits.
    four_bit = [abs(unorm4(a) - unorm4(b)) for a, b in zip(buffer_values, texture_values)]
    results.append({
        "case": name,
        "values": count,
        "different_values": sum(value != 0 for value in differences),
        "max_error_unorm8": max(differences),
        "mean_error_unorm8": sum(differences) / count,
        "buffer_greater_values": sum(a > b for a, b in zip(buffer_values, texture_values)),
        "buffer_less_values": sum(a < b for a, b in zip(buffer_values, texture_values)),
        "original_unorm4_threshold_crossings": sum(value != 0 for value in four_bit),
        "max_error_original_unorm4": max(four_bit),
    })

report = {
    "description": "Actual GPU readback comparison; measured fidelity difference, not a bit-identity claim.",
    "host": buffer_report["host"],
    "buffer_engine_sha256": buffer_report["engine_sha256"],
    "texture_engine_sha256": texture_report["engine_sha256"],
    "shader_sha256": buffer_report["shader_sha256"],
    "cases": results,
}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
