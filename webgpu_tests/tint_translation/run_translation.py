#!/usr/bin/env python3
"""Validate real GLSL→SPIR-V→production Tint translation across module versions."""

import argparse
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHADERS = {
    "atomic_matrix.comp": """#version 450
layout(local_size_x=4) in;
layout(set=0,binding=0,std430) buffer Data { uint counter; mat4 matrix; float values[4]; } data;
void main() {
 uint i=gl_GlobalInvocationID.x;
 atomicAdd(data.counter,1u);
 data.values[i]=data.matrix[1][2]+data.matrix[2][1]+float(i);
}
""",
    "opaque_texture_helper.comp": """#version 450
layout(local_size_x=1) in;
layout(set=0,binding=0) uniform texture2D source_texture;
layout(set=0,binding=1) uniform sampler source_sampler;
layout(set=0,binding=2,rgba32f) writeonly uniform image2D destination;
vec4 sample_value(texture2D t,sampler s,vec2 uv) { return textureLod(sampler2D(t,s),uv,0.0); }
void main() { imageStore(destination,ivec2(0),sample_value(source_texture,source_sampler,vec2(0.5))); }
""",
    "nested_logical_copy.comp": """#version 450
struct Leaf { vec4 value; };
struct Tree { Leaf leaves[2]; };
layout(local_size_x=1) in;
layout(set=0,binding=0,std140) uniform Input { Tree tree; } input_data;
layout(set=0,binding=1,std430) buffer Output { vec4 value; } output_data;
void main() { Tree local_tree=input_data.tree; output_data.value=local_tree.leaves[1].value; }
""",
    "initialized_local_arrays.comp": """#version 450
struct Leaf { vec4 value; };
layout(local_size_x=4) in;
layout(set=0,binding=0,std430) buffer Output { vec4 values[4]; } output_data;
void main() {
 vec4 a[3]=vec4[3](vec4(1.0),vec4(2.0),vec4(3.0));
 Leaf b[2]=Leaf[2](Leaf(vec4(4.0)),Leaf(vec4(5.0)));
 uint i=gl_GlobalInvocationID.x;
 output_data.values[i]=a[i%3u]+b[i%2u].value;
}
""",
    "vertex_storage_read.vert": """#version 450
layout(set=0,binding=0,std430) buffer Data { mat4 transform; vec4 position[3]; } data;
void main() { gl_Position=data.transform*data.position[gl_VertexIndex]; }
""",
    "vertex_storage_helper.vert": """#version 450
layout(set=0,binding=0,std430) buffer Data { vec4 position[3]; } data;
vec4 passthrough(in vec4 value) { return value; }
void main() { gl_Position=passthrough(data.position[gl_VertexIndex]); }
""",
    "fragment_atomic.frag": """#version 450
layout(set=0,binding=0,std430) buffer Data { uint counter; } data;
layout(location=0) out vec4 color;
void main() { color=vec4(float(atomicAdd(data.counter,1u))); }
""",
    "vertex_storage_write.vert": """#version 450
layout(set=0,binding=0,std430) buffer Data { vec4 position[3]; } data;
void main() { data.position[gl_VertexIndex]=vec4(1.0); gl_Position=vec4(0.0,0.0,0.0,1.0); }
""",
}
TARGETS = [("1.0", "vulkan1.0"), ("1.3", "vulkan1.1"), ("1.4", "spirv1.4"), ("1.5", "vulkan1.2")]

for prefix, scalar, format_name in [("u", "uint", "rgba8ui"), ("i", "int", "rgba8i")]:
    SHADERS[f"integer_image_{prefix}.comp"] = f"""#version 450
layout(local_size_x=1) in;
layout(set=0,binding=0,{format_name}) readonly uniform {prefix}image2D source_image;
layout(set=0,binding=1,{format_name}) writeonly uniform {prefix}image2D output_image;
layout(set=0,binding=2,std430) buffer Output {{ {prefix}vec4 value; }} output_data;
void main() {{
 {prefix}vec4 value=imageLoad(source_image,ivec2(0));
 imageStore(output_image,ivec2(0),value);
 output_data.value=value;
}}
"""
    SHADERS[f"integer_fetch_{prefix}.comp"] = f"""#version 450
layout(local_size_x=1) in;
layout(set=0,binding=0) uniform {prefix}texture2D source_texture;
layout(set=0,binding=1) uniform sampler source_sampler;
layout(set=0,binding=2,std430) buffer Output {{ {prefix}vec4 value; }} output_data;
void main() {{ output_data.value=texelFetch({prefix}sampler2D(source_texture,source_sampler),ivec2(0),1); }}
"""


def use_variable_initializers(binary):
    """Exercise OpVariable's initializer operand, not glslang's ordinary OpStore."""
    words = list(struct.unpack("<%dI" % (binary.stat().st_size // 4), binary.read_bytes()))
    instructions = []
    pos = 5
    while pos < len(words):
        size = words[pos] >> 16
        assert size and pos + size <= len(words)
        instructions.append(words[pos : pos + size])
        pos += size
    arrays = {i[1] for i in instructions if (i[0] & 65535) == 28}
    pointers = {i[1] for i in instructions if (i[0] & 65535) == 32 and i[2] == 7 and i[3] in arrays}
    variables = {i[2] for i in instructions if (i[0] & 65535) == 59 and i[1] in pointers and len(i) == 4}
    constants = {i[2] for i in instructions if (i[0] & 65535) == 44}
    stores = {i[1]: i[2] for i in instructions if (i[0] & 65535) == 62 and i[1] in variables and i[2] in constants}
    assert len(stores) == 2
    result = words[:5]
    for i in instructions:
        opcode = i[0] & 65535
        if opcode == 59 and i[2] in stores:
            i = [(5 << 16) | opcode, *i[1:], stores[i[2]]]
        elif opcode == 62 and stores.get(i[1]) == i[2]:
            continue
        result.extend(i)
    binary.write_bytes(struct.pack("<%dI" % len(result), *result))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tint", type=Path, default=ROOT / "bin/tint_convert_cli")
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    glslang = shutil.which("glslang")
    validator = shutil.which("spirv-val")
    assert glslang and validator, "glslang and SPIRV-Tools required"
    records = []
    shaders = {**SHADERS, "initialized_operand_arrays.comp": SHADERS["initialized_local_arrays.comp"]}
    for name, source in shaders.items():
        source_path = out / name
        source_path.write_text(source)
        for version, target in TARGETS:
            stem = name + "." + version
            binary = out / (stem + ".spv")
            command = [glslang, "-V", "--target-env", target, str(source_path), "-o", str(binary)]
            build = subprocess.run(command, capture_output=True, text=True, timeout=60)
            assert build.returncode == 0, build.stdout + build.stderr
            if name == "initialized_operand_arrays.comp":
                use_variable_initializers(binary)
            valid = subprocess.run(
                [validator, "--target-env", "vulkan1.2", str(binary)], capture_output=True, text=True, timeout=30
            )
            assert valid.returncode == 0, valid.stdout + valid.stderr
            dumped = out / (stem + ".preprocessed.spv")
            env = {**os.environ, "AW3_DUMP_PREPROCESSED": str(dumped)}
            result = subprocess.run(
                [str(args.tint.resolve()), str(binary)], capture_output=True, text=True, timeout=60, env=env
            )
            (out / (stem + ".log")).write_text(result.stderr)
            (out / (stem + ".wgsl")).write_text(result.stdout)
            reject = name == "vertex_storage_write.vert"
            valid = subprocess.run(
                [validator, "--target-env", "vulkan1.2", str(dumped)], capture_output=True, text=True, timeout=30
            )
            ok = valid.returncode == 0 and (
                (result.returncode > 0 and ("read" in result.stderr.lower() or "writ" in result.stderr.lower()))
                if reject
                else result.returncode == 0 and "@" in result.stdout
            )
            if not reject and name.startswith("vertex_"):
                ok &= "var<storage, read>" in result.stdout and "var<storage, read_write>" not in result.stdout
            if not reject and "atomic" in name:
                ok &= "atomicAdd(" in result.stdout and "var<storage, read_write>" in result.stdout
            record = {
                "name": name,
                "spirv_version": version,
                "expected": "reject real vertex write" if reject else "translate",
                "passed": bool(ok),
                "returncode": result.returncode,
                "preprocessed_valid": valid.returncode == 0,
            }
            if not ok:
                record["error"] = (result.stderr + valid.stderr)[-5000:]
            if args.baseline:
                old = subprocess.run(
                    [str(args.baseline.resolve()), str(binary)], capture_output=True, text=True, timeout=60
                )
                record["baseline_returncode"] = old.returncode
                record["baseline_translated"] = old.returncode == 0 and "@" in old.stdout
                (out / (stem + ".baseline.log")).write_text(old.stderr)
            records.append(record)
            print(json.dumps(record), flush=True)
    report = {
        "passed": all(r["passed"] for r in records),
        "checks": len(records),
        "tint_sha256": hashlib.sha256(args.tint.read_bytes()).hexdigest(),
        "results": records,
    }
    (out / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    return int(not report["passed"])


if __name__ == "__main__":
    sys.exit(main())
