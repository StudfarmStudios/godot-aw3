#!/usr/bin/env python3
"""Convert one Godot RD shader to WGSL the way the runtime driver would.

The build-time precompiler (wgsl_precompile.py) only walks its own registry of
shaders and variants. When a shader fails in the browser, this drives the exact
same GLSL -> SPIR-V -> preprocess -> Tint chain for a single file, so a failure
that would otherwise cost a re-export and a browser run is a two-second answer.

    ./drivers/webgpu/try_shader.py <glsl-path> <stage> [-D DEFINE ...] [--wgsl]

Stage is vertex/fragment/compute. Exit status is non-zero when the conversion
fails, so this can be scripted over a list of shaders.
"""

import argparse
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from wgsl_precompile import assemble_glsl, compile_glsl_to_spirv, parse_glsl_file  # noqa: E402

STAGE_ABBREV = {"vertex": "vert", "fragment": "frag", "compute": "comp"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("glsl", help="Path to the .glsl file, relative to the repo root.")
    parser.add_argument("stage", choices=list(STAGE_ABBREV), help="Shader stage to convert.")
    parser.add_argument("-D", dest="defines", action="append", default=[],
                        help="Preprocessor define, e.g. -D NO_SUBGROUPS or -D MAX_LIGHTMAPS=32.")
    parser.add_argument("--wgsl", action="store_true", help="Print the WGSL on success.")
    parser.add_argument("--glslang", default="glslangValidator")
    args = parser.parse_args()

    repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    tint_cli = os.path.join(repo_root, "bin", "tint_convert_cli")
    if not os.path.isfile(tint_cli):
        print("ERROR: bin/tint_convert_cli not found. Run drivers/webgpu/tint_cli/build.sh.",
              file=sys.stderr)
        return 2

    stages = parse_glsl_file(args.glsl)
    if stages[args.stage] is None:
        print(f"ERROR: {args.glsl} has no {args.stage} stage.", file=sys.stderr)
        return 2

    defines = "".join(f"#define {d.replace('=', ' ', 1)}\n" for d in args.defines)
    source = assemble_glsl(stages[args.stage], defines, "")

    spv, err = compile_glsl_to_spirv(source, STAGE_ABBREV[args.stage], args.glslang)
    if spv is None:
        print(f"GLSL FAILED:\n{err}", file=sys.stderr)
        return 1

    with tempfile.NamedTemporaryFile(suffix=".spv", delete=False) as f:
        f.write(spv)
        spv_path = f.name
    try:
        # Not --batch: the single-file mode reports the Tint diagnostic verbatim,
        # and a crash here is the same internal compiler error the browser hits.
        result = subprocess.run([tint_cli, spv_path], capture_output=True, text=True, timeout=120)
    finally:
        os.unlink(spv_path)

    if result.returncode != 0:
        print(f"TINT FAILED (exit {result.returncode}):\n{result.stderr or result.stdout}",
              file=sys.stderr)
        return 1

    print(f"OK: {args.glsl}:{args.stage} -> {len(result.stdout)} bytes of WGSL")
    if args.wgsl:
        print(result.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
