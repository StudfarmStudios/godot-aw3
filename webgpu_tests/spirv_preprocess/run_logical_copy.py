#!/usr/bin/env python3
"""Validate production OpCopyLogical lowering with SPIRV-Tools and the Tint CLI."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).resolve().parent


def run(command, *, success=True):
    result = subprocess.run(list(map(str, command)), capture_output=True, text=True, timeout=90)
    if success and result.returncode:
        raise AssertionError(f"Command failed: {' '.join(map(str, command))}\n{result.stdout}\n{result.stderr}")
    if "AddressSanitizer" in result.stderr or "runtime error:" in result.stderr:
        raise AssertionError(result.stderr)
    return result


def read_words(path):
    data = path.read_bytes()
    return list(struct.unpack(f"<{len(data) // 4}I", data))


def write_words(path, words):
    path.write_bytes(struct.pack(f"<{len(words)}I", *words))


def instructions(words):
    pos = 5
    while pos < len(words):
        size = words[pos] >> 16
        assert size and pos + size <= len(words)
        yield pos, words[pos] & 0xFFFF, words[pos:pos + size]
        pos += size


def tint_13_fixture(words):
    """Only for fixtures: Tint currently requires SPIR-V1.3 entry interfaces.

    Lowered fixtures contain only 1.3 instructions. Remove non-I/O interface
    variables (1.4 requires these; 1.3 forbids them), then validate separately.
    This is deliberately not an unreviewed production normalization pass.
    """
    variable_storage = {inst[2]: inst[3] for _, op, inst in instructions(words) if op == 59}
    output = words[:5]
    output[1] = 0x00010300
    for _, op, inst in instructions(words):
        if op == 15:
            end = 3
            while 0 not in struct.pack("<I", inst[end]):
                end += 1
            end += 1
            inst = inst[:end] + [value for value in inst[end:] if variable_storage.get(value) in (1, 3)]
            inst[0] = len(inst) << 16 | op
        output += inst
    return output


def assembly(producer="constant", length=2, integer_width=32, levels=1):
    capabilities = "OpCapability Shader\n"
    if integer_width == 64:
        capabilities += "OpCapability Int64\n"
    lines = [capabilities, '''OpMemoryModel Logical GLSL450
OpEntryPoint GLCompute %main "main" %out
OpExecutionMode %main LocalSize 1 1 1
OpDecorate %out DescriptorSet 0
OpDecorate %out Binding 0
OpDecorate %block Block
OpMemberDecorate %block 0 Offset 0
OpDecorate %src_array ArrayStride 16
OpMemberDecorate %src_leaf 0 Offset 0
%void = OpTypeVoid
%float = OpTypeFloat 32
%uint = OpTypeInt 32 0
%bool = OpTypeBool
%yes = OpConstantTrue %bool
%zero = OpConstant %uint 0
%one = OpConstant %float 1
%two = OpConstant %float 2
%fn = OpTypeFunction %void
%block = OpTypeStruct %float
%block_ptr = OpTypePointer StorageBuffer %block
%float_ptr = OpTypePointer StorageBuffer %float
%out = OpVariable %block_ptr StorageBuffer
%src_leaf = OpTypeStruct %float
%dst_leaf = OpTypeStruct %float
''']
    int_type = "%uint"
    if integer_width != 32:
        lines += [f"%length_type = OpTypeInt {integer_width} 0\n"]
        int_type = "%length_type"
    lines += [f"%length = OpConstant {int_type} {length}\n",
              "%src_array = OpTypeArray %src_leaf %length\n",
              "%dst_array = OpTypeArray %dst_leaf %length\n",
              "%src = OpTypeStruct %src_array\n", "%dst = OpTypeStruct %dst_array\n"]
    src_type, dst_type = "%src", "%dst"
    indices = "0 1 0" if length > 1 else "0 0 0"
    for level in range(1, levels):
        lines += [f"%src{level} = OpTypeStruct {src_type}\n", f"%dst{level} = OpTypeStruct {dst_type}\n"]
        src_type, dst_type = f"%src{level}", f"%dst{level}"
        indices = "0 " + indices
    # Large-array guards use OpConstantNull to keep their input tiny.
    if producer == "constant" and length == 2 and levels == 1:
        lines += ["%a = OpConstantComposite %src_leaf %one\n",
                  "%b = OpConstantComposite %src_leaf %two\n",
                  "%array = OpConstantComposite %src_array %a %b\n",
                  f"%source = OpConstantComposite {src_type} %array\n"]
    elif producer == "undef":
        lines += [f"%source = OpUndef {src_type}\n"]
    else:
        lines += [f"%source = OpConstantNull {src_type}\n"]
    lines += [f"%holder = OpTypeStruct {src_type}\n",
              "%holder_value = OpConstantNull %holder\n",
              f"%local_ptr = OpTypePointer Function {src_type}\n",
              f"%call_type = OpTypeFunction {src_type}\n",
              f"%parameter_type = OpTypeFunction {dst_type} {src_type}\n",
              "%main = OpFunction %void None %fn\n%entry = OpLabel\n"]
    operand = "%source"
    tail = ""
    if producer == "load":
        lines += [f"%local = OpVariable %local_ptr Function %source\n%loaded = OpLoad {src_type} %local\n"]
        operand = "%loaded"
    elif producer == "extract":
        lines += [f"%extracted = OpCompositeExtract {src_type} %holder_value 0\n"]
        operand = "%extracted"
    elif producer == "copy_object":
        lines += [f"%copied = OpCopyObject {src_type} %source\n"]
        operand = "%copied"
    elif producer == "construct":
        lines += ["%part = OpCompositeExtract %src_array %source 0\n",
                  f"%made = OpCompositeConstruct {src_type} %part\n"]
        operand = "%made"
    elif producer == "insert":
        lines += [f"%inserted = OpCompositeInsert {src_type} %two %source 0 1 0\n"]
        operand = "%inserted"
    elif producer == "select":
        lines += [f"%selected = OpSelect {src_type} %yes %source %source\n"]
        operand = "%selected"
    elif producer == "phi":
        lines += ["OpSelectionMerge %merge None\nOpBranchConditional %yes %left %right\n",
                  "%left = OpLabel\nOpBranch %merge\n%right = OpLabel\nOpBranch %merge\n",
                  f"%merge = OpLabel\n%merged = OpPhi {src_type} %source %left %source %right\n"]
        operand = "%merged"
    elif producer == "call":
        lines += [f"%called = OpFunctionCall {src_type} %helper\n"]
        operand = "%called"
        tail = f"%helper = OpFunction {src_type} None %call_type\n%helper_label = OpLabel\nOpReturnValue %source\nOpFunctionEnd\n"
    if producer == "parameter":
        lines += [f"%result = OpFunctionCall {dst_type} %helper %source\n"]
        tail = (f"%helper = OpFunction {dst_type} None %parameter_type\n"
                f"%parameter = OpFunctionParameter {src_type}\n%helper_label = OpLabel\n"
                f"%helper_result = OpCopyLogical {dst_type} %parameter\nOpReturnValue %helper_result\nOpFunctionEnd\n")
    elif producer == "chain":
        lines += [f"%first = OpCopyLogical {dst_type} %source\n",
                  f"%second = OpCopyLogical {src_type} %first\n",
                  f"%result = OpCopyLogical {dst_type} %second\n"]
    else:
        lines += [f"%result = OpCopyLogical {dst_type} {operand}\n"]
    lines += [f"%value = OpCompositeExtract %float %result {indices}\n",
              "%target = OpAccessChain %float_ptr %out %zero\nOpStore %target %value\nOpReturn\nOpFunctionEnd\n", tail]
    return "".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--helper", type=Path, help="Existing harness, otherwise build with ASan/UBSan")
    parser.add_argument("--tint", type=Path, default=ROOT / "bin/tint_convert_cli")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    assembler, validator, glslang = [shutil.which(name) for name in ("spirv-as", "spirv-val", "glslang")]
    assert all((assembler, validator, glslang)), "Install SPIRV-Tools and glslang first"
    if args.helper:
        helper = args.helper.resolve()
    else:
        # Reuse the bundled SPIRV-Tools objects produced by tint_cli/build.sh.
        # Only the production preprocessor and this harness need rebuilding.
        objects = sorted((ROOT / "drivers/webgpu/tint_cli/.build/spirv_tools").rglob("*.o"))
        assert objects, "Build drivers/webgpu/tint_cli/build.sh first"
        helper = out / "logical_copy_cli"
        flags = ["-std=c++17", "-O1", "-g", "-fsanitize=address,undefined"]
        if sys.platform == "darwin":
            flags += ["-isysroot", run(["xcrun", "--show-sdk-path"]).stdout.strip()]
        run(["clang++", *flags, "-I" + str(ROOT / "drivers/webgpu/tint_cli"), "-I" + str(ROOT),
             "-I" + str(ROOT / "thirdparty/spirv-tools/include"), FIXTURES / "logical_copy_cli.cpp",
             ROOT / "drivers/webgpu/spirv_preprocess.cpp", *objects, "-o", helper])
    assert args.tint.is_file(), "Build tint_convert_cli first"
    results = []

    def assembled(name, source):
        path = out / f"{name}.spv"
        text_path = out / f"{name}.spvasm"
        text_path.write_text(source)
        run([assembler, "--target-env", "spv1.4", text_path, "-o", path])
        return path

    def positive(name, path, *, tint=True):
        run([validator, "--target-env", "vulkan1.2", path])
        original = read_words(path)
        copy_ids = {inst[2] for _, op, inst in instructions(original) if op == 400}
        assert copy_ids, f"{name} is not a logical-copy regression"
        lowered = out / f"{name}-lowered.spv"
        result = run([helper, path, lowered])
        assert not result.stderr or (not tint and "64-bit integers" in result.stderr), result.stderr
        run([validator, "--target-env", "vulkan1.2", lowered])
        rewritten = read_words(lowered)
        assert all(op != 400 for _, op, _ in instructions(rewritten))
        result_ids = {inst[2] for _, op, inst in instructions(rewritten) if op in (80, 83)}
        assert copy_ids <= result_ids, "Original result IDs must remain defined"
        assert rewritten[3] >= original[3]
        again = out / f"{name}-again.spv"
        run([helper, lowered, again])
        assert again.read_bytes() == lowered.read_bytes(), "Lowering must be idempotent"
        # Prove the old implementation fails the same validation gate.
        old = original[:]
        for pos, op, inst in instructions(old):
            if op == 400:
                old[pos] = len(inst) << 16 | 83
        old_path = out / f"{name}-old-opcode-swap.spv"
        write_words(old_path, old)
        old_result = run([validator, "--target-env", "vulkan1.2", old_path], success=False)
        assert old_result.returncode, "Regression also passed the old lowering"
        (out / f"{name}-old-validation.txt").write_text(old_result.stderr)
        if tint:
            portable = out / f"{name}-tint13.spv"
            write_words(portable, tint_13_fixture(rewritten))
            run([validator, "--target-env", "vulkan1.1", portable])
            translated = run([args.tint.resolve(), portable])
            assert "@compute" in translated.stdout and "fn" in translated.stdout
            (out / f"{name}.wgsl").write_text(translated.stdout)
        results.append({"name": name, "kind": "positive", "tint_13_fixture": tint,
                        "input_words": len(original), "output_words": len(rewritten), "passed": True})

    for producer in ("constant", "null", "undef", "load", "extract", "copy_object", "construct", "insert", "select", "phi", "call", "parameter", "chain"):
        positive(producer, assembled(producer, assembly(producer)), tint=producer != "select")
    positive("uint64_length", assembled("uint64_length", assembly(integer_width=64)), tint=False)
    positive("maximum_constructor", assembled("maximum_constructor", assembly("null", length=65532)), tint=False)
    positive("deep_nested", assembled("deep_nested", assembly("null", levels=32)))
    nested = out / "nested_ubo.spv"
    run([glslang, "-V", "--target-env", "vulkan1.2", "-o", nested, FIXTURES / "nested_ubo.comp"])
    positive("nested_ubo", nested)

    seed = read_words(out / "constant.spv")

    def unchanged(name, data, *, diagnostic=True):
        path = out / f"{name}.spv"
        path.write_bytes(data if isinstance(data, bytes) else struct.pack(f"<{len(data)}I", *data))
        target = out / f"{name}-unchanged.spv"
        result = run([helper, path, target])
        assert target.read_bytes() == path.read_bytes(), f"{name}: unsafe partial rewrite"
        if diagnostic:
            assert "OpCopyLogical" in result.stderr, result.stderr
        results.append({"name": name, "kind": "guard", "passed": True})

    unchanged("truncated_header", b"\x03\x02", diagnostic=False)
    unchanged("unaligned", (out / "constant.spv").read_bytes() + b"\x00", diagnostic=False)
    unchanged("zero_word_count_suffix", seed + [0])
    unchanged("truncated_suffix", seed + [5 << 16 | 81])
    malformed = seed[:]
    malformed[3] = 1
    unchanged("invalid_bound", malformed)
    malformed = seed[:]
    malformed[3] = 0xFFFFFFFF
    unchanged("overflow_bound", malformed)
    malformed = seed[:]
    malformed[0] = 0
    unchanged("bad_magic", malformed)
    malformed = seed[:]
    malformed[3] = 0x3FFFFF
    unchanged("no_free_ids", malformed)
    malformed = seed[:]
    for pos, op, inst in instructions(malformed):
        if op == 400:
            malformed[pos + 3] = seed[3] + 10
            break
    unchanged("unknown_source", malformed)
    # Leaf type mismatch: a rejected malformed module must not become a copy.
    malformed = seed[:]
    uint_type = next(inst[1] for _, op, inst in instructions(seed) if op == 21 and inst[2] == 32)
    structs = [(pos, inst) for pos, op, inst in instructions(seed) if op == 30 and len(inst) == 3]
    malformed[structs[2][0] + 2] = uint_type  # Destination leaf (block, source leaf, destination leaf).
    unchanged("mismatched_leaf", malformed)
    duplicate = seed[:]
    copy_inst = next(inst for _, op, inst in instructions(seed) if op == 400)
    duplicate += copy_inst
    unchanged("duplicate_result", duplicate)
    unresolved = assembled("unresolved", assembly("null").replace("%length = OpConstant %uint 2", "%length = OpSpecConstant %uint 2"))
    unchanged("unresolved_specialization", unresolved.read_bytes())
    huge_length = assembled("huge_length", assembly("null", length=2**32 + 2, integer_width=64))
    unchanged("length_high_bits", huge_length.read_bytes(), diagnostic=False)
    too_deep = assembled("too_deep", assembly("null", levels=70))
    unchanged("depth_budget", too_deep.read_bytes())
    too_wide = assembled("too_wide", assembly("null", length=65533))
    unchanged("instruction_word_count_budget", too_wide.read_bytes())
    # Nested 1024x1024 arrays have tiny input, but >1M source leaves to expand.
    huge_text = assembly("null", length=1024).replace(
        "%src = OpTypeStruct %src_array\n%dst = OpTypeStruct %dst_array\n",
        "%src_outer = OpTypeArray %src_array %length\n%dst_outer = OpTypeArray %dst_array %length\n"
        "%src = OpTypeStruct %src_outer\n%dst = OpTypeStruct %dst_outer\n").replace(
        "%result 0 1 0", "%result 0 0 1 0")
    huge = assembled("huge", huge_text)
    unchanged("expansion_budget", huge.read_bytes())
    # Same-type input is not valid OpCopyLogical, but can safely canonicalize
    # to OpCopyObject without allocating any IDs.
    identical = seed[:]
    source_types = {inst[2]: inst[1] for _, op, inst in instructions(seed) if op == 44}
    for pos, op, inst in instructions(identical):
        if op == 400:
            identical[pos + 1] = source_types[inst[3]]
    path = out / "identical.spv"
    write_words(path, identical)
    target = out / "identical-lowered.spv"
    run([helper, path, target])
    run([validator, "--target-env", "vulkan1.2", target])
    assert read_words(target)[3] == identical[3]
    results.append({"name": "identical_type", "kind": "canonicalization", "passed": True})
    report = {"checks": len(results), "passed": True, "results": results,
              "helper_sha256": hashlib.sha256(helper.read_bytes()).hexdigest(),
              "spirv_val_version": run([validator, "--version"]).stdout.splitlines()[0],
              "tint_cli_sha256": hashlib.sha256(args.tint.read_bytes()).hexdigest(),
              "tint_note": "WGSL translation validates an explicit test-only SPIR-V1.3/interface normalization; production normalization is unchanged."}
    (out / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
