#!/usr/bin/env python3
"""Check extracted production bind-group state transitions under ASan/UBSan."""

import argparse
import hashlib
import json
import os
import platform
import subprocess
from pathlib import Path

DRIVER = "drivers/webgpu/rendering_device_driver_webgpu.cpp"
OBJECTS = "drivers/webgpu/webgpu_objects.h"


def block(source: str, start: int) -> tuple[str, int]:
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end], end


def render_branches(source: str) -> str:
    start = source.index("\t\t\tif (is_pc_merged) {")
    _, end = block(source, start)
    while source[end:].startswith(" else"):
        _, end = block(source, end)
    return source[start:end]


HARNESS = r"""
#include <array>
#include <cassert>
#include <cstdint>
#include <iostream>
#include <string>
#include <vector>
using WGPUBindGroup = uintptr_t;
struct WGShader { uint32_t push_constant_size = 0; uint32_t push_constant_bind_group = 0; void *merged_pc_group_layout = nullptr; };
struct WGUniformSet {};
struct GPUState {
    struct Slot { WGPUBindGroup group = 0; std::vector<uint32_t> offsets; };
    std::array<Slot, 5> slots;
    uint32_t calls = 0;
};
void wgpuRenderPassEncoderSetBindGroup(GPUState *gpu, uint32_t index, WGPUBindGroup group, uint32_t count, const uint32_t *offsets) {
    ++gpu->calls;
    gpu->slots.at(index).group = group;
    gpu->slots.at(index).offsets.clear();
    if (count) gpu->slots.at(index).offsets.assign(offsets, offsets + count);
}
struct WGCommandBuffer {
    GPUState *render_encoder = nullptr;
    WGPUBindGroup current_pc_bind_group = 0;
    uint32_t last_flushed_pc_offset = 0;
    uint32_t pc_group_material_dyn_count = 0;
    static constexpr uint32_t MAX_PC_GROUP_MATERIAL_DYN = 8;
    uint32_t pc_group_material_dyn_offsets[MAX_PC_GROUP_MATERIAL_DYN] = {};
STATE
};
struct { uint32_t set_bind_group_calls = 0; } perf;
void bind_group(WGCommandBuffer *cmd, uint32_t set_idx, WGPUBindGroup bg_to_bind, const std::vector<uint32_t> &offsets, int pc_mode = 0) {
    WGShader shader;
    shader.push_constant_size = pc_mode ? 16 : 0;
    shader.push_constant_bind_group = set_idx;
    shader.merged_pc_group_layout = pc_mode == 2 ? &shader : nullptr;
    WGShader *pipeline_shader = &shader;
    bool is_pc_merged = pc_mode == 2;
    constexpr uint32_t MAX_DYNAMIC_BUFFERS = 8;
    uint32_t set_dyn_offsets[MAX_DYNAMIC_BUFFERS] = {};
    uint32_t num_dyn = offsets.size();
    assert(num_dyn <= MAX_DYNAMIC_BUFFERS);
    for (uint32_t i = 0; i < num_dyn; ++i) set_dyn_offsets[i] = offsets[i];
    for (int once = 0; once < 1; ++once) {
BRANCHES
    }
}
uint32_t checks = 0;
void check(bool value) { ++checks; if (!value) std::cerr << "failed check " << checks << "\n"; assert(value); }
void expected(const GPUState &gpu, uint32_t slot, WGPUBindGroup group, const std::vector<uint32_t> &offsets) {
    check(gpu.slots.at(slot).group == group && gpu.slots.at(slot).offsets == offsets);
}
int main(int argc, char **argv) {
    assert(argc == 2);
    std::string test = argv[1];
    GPUState gpu;
    WGCommandBuffer cmd;
    cmd.render_encoder = &gpu;
    if (test == "transitions") {
        // Repeat each state so both correctness and eliminated API calls are observable.
        const std::vector<std::vector<uint32_t>> values = {
            {0}, {256}, {0}, {0, 256}, {256, 256}, {256, 512},
            {0, 256, 512, 768, 1024, 1280, 1536, 1792},
            {0, 256, 512, 768, 1024, 1280, 1536, 2048},
            {0, 256, 512, 1024, 1024, 1280, 1536, 2048},
            {256, 256, 512, 1024, 1024, 1280, 1536, 2048}};
        for (const auto &offsets : values) {
            for (int i = 0; i < 3; ++i) {
                bind_group(&cmd, 1, 11, offsets);
                expected(gpu, 1, 11, offsets);
            }
        }
        check(gpu.calls == (OPTIMIZED ? values.size() : values.size() * 3));
        for (uint32_t slot = 0; slot < 4; ++slot) {
            bind_group(&cmd, slot, 12, {256, 512});
            expected(gpu, slot, 12, {256, 512});
        }
        // A different compatible group or shader invalidation must not reuse old state.
        bind_group(&cmd, 1, 13, {256, 512});
        expected(gpu, 1, 13, {256, 512});
        uint32_t previous = gpu.calls;
        cmd.invalidate_bind_groups();
        bind_group(&cmd, 1, 13, {256, 512});
        expected(gpu, 1, 13, {256, 512});
        check(gpu.calls == previous + 1);
        // Static groups remain deduplicated and replace stale dynamic tuples.
        bind_group(&cmd, 1, 14, {});
        previous = gpu.calls;
        bind_group(&cmd, 1, 14, {});
        expected(gpu, 1, 14, {});
        check(gpu.calls == previous);
        bind_group(&cmd, 1, 15, {768});
        expected(gpu, 1, 15, {768});
        // Untracked slots bind every time; no out-of-bounds state access.
        previous = gpu.calls;
        bind_group(&cmd, 4, 16, {768});
        bind_group(&cmd, 4, 16, {768});
        expected(gpu, 4, 16, {768});
        check(gpu.calls == previous + 2);
    } else if (test == "push_constants") {
        for (int mode : {1, 2}) {
            cmd.invalidate_bind_groups();
            cmd.last_flushed_pc_offset = 1792;
            uint32_t previous = gpu.calls;
            bind_group(&cmd, 1, 31, {256, 512}, mode);
            bind_group(&cmd, 1, 31, {256, 512}, mode);
            expected(gpu, 1, 31, mode == 2 ? std::vector<uint32_t>{256, 512, 1792} : std::vector<uint32_t>{256, 512});
            check(gpu.calls == previous + 2);
            check(cmd.bound_bind_groups[1] == 0);
            if (mode == 2) {
                check(cmd.current_pc_bind_group == 31);
                check(cmd.pc_group_material_dyn_count == 2);
                check(cmd.pc_group_material_dyn_offsets[0] == 256 && cmd.pc_group_material_dyn_offsets[1] == 512);
            }
            // Switching the shader from PC to non-PC invalidates even a reused
            // compatible group handle and an identical dynamic offset count.
            cmd.invalidate_bind_groups();
            previous = gpu.calls;
            bind_group(&cmd, 1, 31, {256, 512});
            expected(gpu, 1, 31, {256, 512});
            check(gpu.calls == previous + 1);
        }
    } else if (test == "restart") {
        bind_group(&cmd, 1, 41, {512, 768});
        const auto saved = cmd.last_bound_state[1];
        gpu.slots = {};
        // Actual ring-overflow path restores the recorded tuple then clears validity.
        wgpuRenderPassEncoderSetBindGroup(&gpu, 1, saved.group, saved.dynamic_offset_count, saved.dynamic_offsets);
        cmd.bound_bind_groups[1] = 0;
        expected(gpu, 1, 41, {512, 768});
        uint32_t previous = gpu.calls;
        bind_group(&cmd, 1, 41, {512, 768});
        expected(gpu, 1, 41, {512, 768});
        check(gpu.calls == previous + 1);
        // A new encoder has no groups even if last_bound_state still holds a tuple.
        gpu.slots = {};
        cmd.invalidate_bind_groups();
        bind_group(&cmd, 1, 41, {512, 768});
        expected(gpu, 1, 41, {512, 768});
    } else if (test == "subpass") {
        bind_group(&cmd, 0, 51, {});
        gpu.slots = {};
        SUBPASS_INVALIDATION
        bind_group(&cmd, 0, 51, {});
        expected(gpu, 0, 51, {});
    } else {
        return 2;
    }
    check(gpu.calls == perf.set_bind_group_calls + (test == "restart" ? 1 : 0));
    std::cout << "DYNAMIC_BIND_GROUP_STATE_PASS " << test << " checks=" << checks << " calls=" << gpu.calls << "\n";
}
"""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", default="clang++")
    parser.add_argument("--baseline-ref", default="20f7c82ba6a502e39a6218729060272c574faf21")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    args.output.mkdir(parents=True, exist_ok=True)
    report = {"host": platform.platform(), "baseline_ref": args.baseline_ref, "variants": []}
    for variant in ("baseline", "current", "offset_blind_control"):

        def read(path: str) -> str:
            if variant == "baseline":
                return subprocess.check_output(["git", "show", f"{args.baseline_ref}:{path}"], cwd=root, text=True)
            return (root / path).read_text()

        driver = read(DRIVER)
        objects = read(OBJECTS)
        state = objects[objects.index("\t// Bind group state tracking") : objects.index("\t// Track query pools")]
        branches = render_branches(driver)
        subpass, _ = block(driver, driver.index("void RenderingDeviceDriverWebGPU::command_next_render_subpass("))
        # Handles are integer test tokens rather than WebGPU pointers; logic is otherwise verbatim.
        state = state.replace("WGPUBindGroup group = nullptr", "WGPUBindGroup group = 0")
        state = state.replace("bound_bind_groups[i] = nullptr", "bound_bind_groups[i] = 0")
        state = state.replace("current_pc_bind_group = nullptr", "current_pc_bind_group = 0")
        branches = branches.replace("current_pc_bind_group = nullptr", "current_pc_bind_group = 0")
        branches = branches.replace("bound_bind_groups[set_idx] = nullptr", "bound_bind_groups[set_idx] = 0")
        branches = branches.replace("num_dyn > 0 ? nullptr : bg_to_bind", "num_dyn > 0 ? 0 : bg_to_bind")
        if variant == "offset_blind_control":
            start = state.index("\t\tfor (uint32_t i = 0; i < p_dynamic_offset_count; i++)")
            _, end = block(state, start)
            state = state[:start] + state[end:]
        code = HARNESS.replace("\nSTATE\n", "\n" + state + "\n").replace("\nBRANCHES\n", "\n" + branches + "\n")
        code = code.replace("OPTIMIZED", "false" if variant == "baseline" else "true")
        code = code.replace(
            "SUBPASS_INVALIDATION",
            "cmd.invalidate_bind_groups();" if "cmd->invalidate_bind_groups();" in subpass else "",
        )
        source = args.output / f"{variant}.cpp"
        binary = args.output / variant
        source.write_text(code)
        compile_result = subprocess.run(
            [
                args.compiler,
                "-std=c++17",
                "-O1",
                "-g",
                "-fsanitize=address,undefined",
                "-fno-omit-frame-pointer",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-Wno-unused-parameter",
                str(source),
                "-o",
                str(binary),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if compile_result.returncode:
            raise RuntimeError(compile_result.stdout + compile_result.stderr)
        records = []
        for case in ("transitions", "push_constants", "restart", "subpass"):
            result = subprocess.run(
                [str(binary), case],
                capture_output=True,
                text=True,
                env={**os.environ, "ASAN_OPTIONS": "detect_leaks=0:abort_on_error=1:halt_on_error=1"},
            )
            output = result.stdout + result.stderr
            (args.output / f"{variant}-{case}.log").write_text(output)
            negative = (variant == "baseline" and case == "subpass") or (
                variant == "offset_blind_control" and case == "transitions"
            )
            passed = (
                result.returncode != 0 and "Assertion" in output
                if negative
                else result.returncode == 0 and f"PASS {case}" in output
            )
            records.append({
                "case": case,
                "passed": passed,
                "expected_failure": negative,
                "returncode": result.returncode,
                "stdout": result.stdout.strip(),
            })
        report["variants"].append({
            "name": variant,
            "driver_sha256": hashlib.sha256(driver.encode()).hexdigest(),
            "objects_sha256": hashlib.sha256(objects.encode()).hexdigest(),
            "checks": records,
        })
    report["passed"] = all(check["passed"] for variant in report["variants"] for check in variant["checks"])
    (args.output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if not report["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
