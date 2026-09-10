#!/usr/bin/env python3
"""Compile every exported C# AOT module with the engine's LLVM toolchain.

This consumes a completed release export, never a method-selection profile.
Keep the source export unchanged between baseline, training, and profile use.
The output directory is suitable for Godot's mono_aot_dir SCons option.
"""

import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def upgrade_intrinsics(ir):
    # .NET 9's AOT LLVM emits these retired Wasm-specific names. Newer LLVM
    # uses the target-independent saturating subtraction intrinsics instead.
    # Arguments/results are the same vectors; no function or method is removed.
    # The disassembler's input-path comment differs between output directories.
    ir = re.sub(r"^; ModuleID = .*\n", "", ir, count=1)
    upgrades = {}
    for signedness, prefix in (("signed", "s"), ("unsigned", "u")):
        for vector in ("v16i8", "v8i16"):
            old = f"@llvm.wasm.sub.sat.{signedness}.{vector}("
            new = f"@llvm.{prefix}sub.sat.{vector}("
            if old in ir:
                upgrades[old[1:-1]] = ir.count(old)
                ir = ir.replace(old, new)
    unknown = re.findall(r"; Unknown intrinsic\n(?:[^\n]*\n)*?declare[^\n]*?@(llvm\.[^(]+)", ir)
    remaining = [name for name in unknown if not name.startswith(("llvm.ssub.sat.", "llvm.usub.sat."))]
    if remaining:
        raise RuntimeError(f"Unsupported LLVM intrinsics: {', '.join(remaining)}")
    return ir, upgrades


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("baseline", "generate", "use"))
    parser.add_argument("--aot-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--profile", type=Path)
    parser.add_argument("--emcc", default="emcc")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    source, output = args.aot_dir.resolve(), args.output.resolve()
    if source == output or source in output.parents or output in source.parents:
        parser.error("use a separate output directory outside the source export")
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    profile = args.profile.resolve() if args.profile else None
    if args.mode == "use" and (profile is None or not profile.is_file()):
        parser.error("use requires --profile pointing to merged LLVM .profdata")
    if args.mode != "use" and profile:
        parser.error("--profile is only valid in use mode")
    modules = sorted(source.glob("*.dll.bc"))
    if not modules or not (source / "driver-gen.c").is_file():
        parser.error("--aot-dir must contain a completed export's bitcode and driver-gen.c")
    objects = {p.name.removesuffix(".o") for p in source.glob("*.dll.o")}
    if {p.name.removesuffix(".bc") for p in modules} != objects:
        parser.error("bitcode and AOT object lists differ; refusing to omit an assembly")
    if output.exists() and any(output.iterdir()):
        parser.error("output must be empty; retain each run's inputs and build record")
    output.mkdir(parents=True, exist_ok=True)

    # Generated registration and interop tables must match these exact assemblies.
    for pattern in ("*.c", "*.h", "*.dll.bc"):
        for path in source.glob(pattern):
            shutil.copy2(path, output / path.name)
    flags = ["-O2", "-fwasm-exceptions", "-pthread", "-msimd128"]
    if args.mode == "generate":
        flags += ["-fprofile-generate", "-fprofile-update=atomic"]
    elif args.mode == "use":
        flags += [f"-fprofile-use={profile}", "-Werror=profile-instr-out-of-date"]

    def compile_module(path):
        target = output / path.name.replace(".bc", ".o")
        # Disassemble without optimization to check the older runtime's IR.
        # Most modules are compiled from the byte-identical original bitcode.
        ir_path = output / (path.name + ".ll")
        disassemble = subprocess.run([
            args.emcc, "-S", "-emit-llvm", "-O0", "-Xclang", "-disable-llvm-passes",
            "-fwasm-exceptions", "-pthread", "-msimd128", str(output / path.name), "-o", str(ir_path),
        ], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if disassemble.returncode:
            (output / (path.name + ".log")).write_text(disassemble.stdout)
            raise RuntimeError(f"{path.name} IR inspection failed; see {path.name}.log")
        normalized, upgrades = upgrade_intrinsics(ir_path.read_text())
        if upgrades:
            ir_path.write_text(normalized)
            compile_input = ir_path
        else:
            ir_path.unlink()
            compile_input = output / path.name
        command = [args.emcc, *flags, "-c", str(compile_input), "-o", str(target)]
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (output / (path.name + ".log")).write_text(disassemble.stdout + result.stdout)
        if result.returncode:
            raise RuntimeError(f"{path.name} failed; see {path.name}.log")
        print(f"{args.mode}: {path.name}", flush=True)
        return {"module": path.name, "bitcodeSha256": digest(path),
                "compileInputSha256": digest(compile_input), "intrinsicUpgrades": upgrades,
                "objectSha256": digest(target)}

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        records = list(pool.map(compile_module, modules))
    record = {
        "mode": args.mode,
        "source": str(source),
        "compiler": subprocess.check_output([args.emcc, "--version"], text=True).strip(),
        "flags": flags,
        "profileSha256": digest(profile) if profile else None,
        "modules": records,
    }
    (output / "pgo-build.json").write_text(json.dumps(record, indent=2) + "\n")
    print(f"Compiled all {len(records)} assemblies. mono_aot_dir={output}")


if __name__ == "__main__":
    main()
