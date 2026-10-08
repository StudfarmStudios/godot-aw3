#!/usr/bin/env python3
"""Compile the SDFGI shader contracts with glslang, SPIRV-Tools and optional Tint."""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHADERS = ROOT / "servers/rendering/renderer_rd/shaders/environment"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--tint", type=Path, help="Also run the built production tint_convert_cli for WebGPU cases")
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
glslang, validator = [shutil.which(name) for name in ("glslang", "spirv-val")]
assert glslang and validator, "Install glslang and SPIRV-Tools first"

variants = {
    "sdfgi_preprocess": [
        "MODE_SCROLL",
        "MODE_SCROLL_OCCLUSION",
        "MODE_INITIALIZE_JUMP_FLOOD",
        "MODE_INITIALIZE_JUMP_FLOOD_HALF",
        "MODE_JUMPFLOOD",
        "MODE_JUMPFLOOD_OPTIMIZED",
        "MODE_UPSCALE_JUMP_FLOOD",
        "MODE_OCCLUSION",
        "MODE_STORE",
        "MODE_CLEAR_LIGHT",
    ],
    "sdfgi_direct_light": ["MODE_PROCESS_STATIC", "MODE_PROCESS_DYNAMIC"],
    "sdfgi_integrate": ["MODE_PROCESS", "MODE_STORE", "MODE_SCROLL", "MODE_SCROLL_STORE"],
    "sdfgi_debug": [""],
    "gi": ["USE_SDFGI", "USE_SDFGI\n#define USE_VOXEL_GI_INSTANCES"],
}
results = []
for backend in ("packed", "webgpu"):
    for shader_name, modes in variants.items():
        for index, mode in enumerate(modes):
            for sky_array in [False, True] if shader_name == "sdfgi_integrate" else [False]:
                label = f"{backend}-{shader_name}-{index}" + ("-sky-array" if sky_array else "")
                defines = "#extension GL_GOOGLE_include_directive : require\n"
                defines += (
                    "#define OCCLUSION_SIZE 8\n#define OCT_SIZE 6\n#define SH_SIZE 16\n#define SDFGI_OCT_SIZE 6\n"
                )
                if mode:
                    defines += "#define " + mode + "\n"
                if backend == "webgpu":
                    defines += "#define SDFGI_NATIVE_STORAGE_FORMAT\n#define SDFGI_BUFFER_STORAGE\n#define SDFGI_CASCADE_ATLAS\n"
                if sky_array:
                    defines += "#define USE_RADIANCE_OCTMAP_ARRAY\n"
                source_path = output / f"{label}.comp"
                source = (
                    (SHADERS / f"{shader_name}.glsl")
                    .read_text()
                    .replace("#[compute]", "")
                    .replace("#VERSION_DEFINES", defines)
                )
                source_path.write_text(source)
                spirv = output / f"{label}.spv"
                command = [
                    glslang,
                    "-V",
                    "--target-env",
                    "vulkan1.1",
                    "-I" + str(SHADERS),
                    "-I" + str(ROOT),
                    "-o",
                    str(spirv),
                    str(source_path),
                ]
                compile_result = subprocess.run(command, capture_output=True, text=True, timeout=60)
                log = compile_result.stdout + compile_result.stderr
                valid, translated = False, None
                texture_bindings = None
                hardware_depth_typed = None
                if compile_result.returncode == 0:
                    validation = subprocess.run(
                        [validator, "--target-env", "vulkan1.1", str(spirv)], capture_output=True, text=True, timeout=60
                    )
                    valid = validation.returncode == 0
                    log += validation.stdout + validation.stderr
                if valid and backend == "webgpu" and args.tint:
                    conversion = subprocess.run(
                        [str(args.tint.resolve()), str(spirv)], capture_output=True, text=True, timeout=90
                    )
                    translated = conversion.returncode == 0 and "@compute" in conversion.stdout
                    log += conversion.stderr
                    if translated:
                        (output / f"{label}.wgsl").write_text(conversion.stdout)
                        texture_bindings = {
                            "sampled": len(re.findall(r"var\s+\w+\s*:\s*texture_(?!storage_)", conversion.stdout)),
                            "storage": len(re.findall(r"var\s+\w+\s*:\s*texture_storage_", conversion.stdout)),
                        }
                        if shader_name == "gi":
                            # Hardware depth must not bind the driver's blank Float fallback.
                            hardware_depth_typed = bool(
                                re.search(r"@binding\(24u\)[^;]*texture_depth_2d", conversion.stdout)
                            )
                            if not hardware_depth_typed:
                                log += "GI hardware depth binding 12 was not translated as texture_depth_2d.\n"
                passed = valid and translated is not False and hardware_depth_typed is not False
                (output / f"{label}.log").write_text(log)
                result = {
                    "shader": label,
                    "passed": passed,
                    "spirv_valid": valid,
                    "tint_translated": translated,
                    "texture_bindings": texture_bindings,
                    "hardware_depth_typed": hardware_depth_typed,
                }
                results.append(result)
                print(json.dumps(result), flush=True)
report = {
    "passed": all(result["passed"] for result in results),
    "checks": len(results),
    "tint_sha256": hashlib.sha256(args.tint.read_bytes()).hexdigest() if args.tint else None,
    "source_sha256": {
        str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in [*(SHADERS / (name + ".glsl") for name in variants), SHADERS.parent / "sdfgi_cascade_inc.glsl"]
    },
    "results": results,
}
(output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
sys.exit(0 if report["passed"] else 1)
