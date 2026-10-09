#!/usr/bin/env python3
"""Prove SPIR-V literals equal to a sampled-image ID do not request filtering."""

import argparse
import hashlib
import json
import platform
import re
import subprocess
import sys
from pathlib import Path

HEADER = """OpCapability Shader
%glsl = OpExtInstImport "GLSL.std.450"
OpMemoryModel Logical GLSL450
OpEntryPoint GLCompute %main "main"
OpExecutionMode %main LocalSize 1 1 1
%file = OpString "literal-collision.glsl"
OpName %source "source_texture"
OpDecorate %source DescriptorSet 0
OpDecorate %source Binding 0
OpDecorate %output DescriptorSet 0
OpDecorate %output Binding 1
OpDecorate %runtime_array ArrayStride 4
OpMemberDecorate %output_type 0 Offset 0
OpDecorate %output_type Block
%void = OpTypeVoid
%function = OpTypeFunction %void
%float = OpTypeFloat 32
%int = OpTypeInt 32 1
%uint = OpTypeInt 32 0
%zero = OpConstant %int 0
%uint_zero = OpConstant %uint 0
%float_zero = OpConstant %float 0
%sixty_four = OpConstant %uint 64
%ivec2 = OpTypeVector %int 2
%vec4 = OpTypeVector %float 4
%origin = OpConstantComposite %ivec2 %zero %zero
%image_type = OpTypeImage %float 2D 0 0 0 1 Unknown
%sampled_type = OpTypeSampledImage %image_type
%source_pointer = OpTypePointer UniformConstant %sampled_type
%source = OpVariable %source_pointer UniformConstant
%array64 = OpTypeArray %float %sixty_four
%runtime_array = OpTypeRuntimeArray %float
%output_type = OpTypeStruct %runtime_array
%output_pointer = OpTypePointer StorageBuffer %output_type
%output = OpVariable %output_pointer StorageBuffer
%float_pointer = OpTypePointer StorageBuffer %float
%main = OpFunction %void None %function
%entry = OpLabel
%40 = OpLoad %sampled_type %source
%image = OpImage %image_type %40
%pixel = OpImageFetch %vec4 %image %origin Lod %zero
%fetched = OpCompositeExtract %float %pixel 0
"""
TAIL = """%address = OpAccessChain %float_pointer %output %zero %zero
OpStore %address %result
OpReturn
OpFunctionEnd
"""
BODIES = {
    "fmax": "%result = OpExtInst %float %glsl FMax %fetched %float_zero\n",
    "composite": "%aggregate = OpCompositeConstruct %array64 "
    + " ".join(["%fetched"] * 64)
    + "\n%result = OpCompositeExtract %float %aggregate 40\n",
    "switch": "OpSelectionMerge %merge None\nOpSwitch %uint_zero %default 40 %case\n%case = OpLabel\nOpBranch %merge\n%default = OpLabel\nOpBranch %merge\n%merge = OpLabel\n%result = OpPhi %float %fetched %case %fetched %default\n",
    "debug": "OpLine %file 40 1\n%result = OpCopyObject %float %fetched\n",
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("engine", type=Path)
parser.add_argument("--output", type=Path, default=Path(__file__).parent / "artifacts")
parser.add_argument(
    "--modes",
    nargs="+",
    choices=["native", "fallback", "nofilter", "combined"],
    default=["native", "fallback", "nofilter", "combined"],
)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
proofs = []
for name, body in BODIES.items():
    source = args.output / (name + ".spvasm")
    binary = args.output / (name + ".spv")
    source.write_text(HEADER + body + TAIL)
    subprocess.run(
        ["spirv-as", "--preserve-numeric-ids", "--target-env", "spv1.3", str(source), "-o", str(binary)], check=True
    )
    subprocess.run(["spirv-val", "--target-env", "vulkan1.1", str(binary)], check=True)
    assembly = subprocess.check_output(["spirv-dis", "--raw-id", str(binary)], text=True)
    assert re.search(r"%40 = OpLoad", assembly)
    assert (
        " FMax " in assembly if name == "fmax" else re.search(r"Op(?:CompositeExtract|Switch|Line).*\b40\b", assembly)
    )
    proofs.append({
        "case": name,
        "passed": True,
        "spirv_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "collision_handle_id": 40,
    })
runs = []
for mode in args.modes:
    command = [
        str(args.engine.resolve()),
        "--path",
        str(Path(__file__).resolve().parent),
        "--rendering-method",
        "forward_plus",
        "--rendering-driver",
        "webgpu",
        "--script",
        "res://main.gd",
        "--",
        "--literal-directory=" + str(args.output.resolve()),
    ]
    if mode in ("fallback", "combined"):
        command.append("--webgpu-force-fallbacks")
    if mode in ("nofilter", "combined"):
        command.append("--webgpu-no-float32-filterable")
    output = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    (args.output / (mode + ".log")).write_text(output.stdout)
    errors = [
        line
        for line in output.stdout.splitlines()
        if re.search(
            r"ERROR:|SCRIPT ERROR:|GPUValidationError|handle_crash|Program crashed|was leaked|\[WebGPU.*(?:[Ee]rror|[Vv]alidation)",
            line,
        )
    ]
    complete = re.search(r"SAMPLED_LITERALS COMPLETE passed=(\d+) failed=(\d+)", output.stdout)
    passed = (
        output.returncode == 0
        and not errors
        and complete is not None
        and complete.groups() == ("12", "0")
        and "WebGPU 1.0 - Forward+" in output.stdout
    )
    result = {
        "mode": mode,
        "passed": passed,
        "returncode": output.returncode,
        "errors": errors,
        "command": command,
        "checks": [line for line in output.stdout.splitlines() if line.startswith("SAMPLED_LITERALS ")],
    }
    runs.append(result)
    print(json.dumps(result), flush=True)
report = {
    "passed": all(run["passed"] for run in runs),
    "engine_sha256": hashlib.sha256(args.engine.read_bytes()).hexdigest(),
    "host": platform.platform(),
    "literal_proofs": proofs,
    "runs": runs,
}
(args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
sys.exit(0 if report["passed"] else 1)
