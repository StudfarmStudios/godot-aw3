#!/usr/bin/env python3
"""Run extracted production fence lifetime code under AddressSanitizer."""

import argparse
import hashlib
import json
import os
import platform
import re
import subprocess
from pathlib import Path

DRIVER = "drivers/webgpu/rendering_device_driver_webgpu.cpp"
OBJECTS = "drivers/webgpu/webgpu_objects.h"
CASES = ("empty", "single_pending", "free_before_first", "free_after_first", "last_signal", "resubmit")
EXPECTED_NEGATIVE_FAILURES = {"free_before_first", "free_after_first", "last_signal", "resubmit"}
TEST_BODY = r"""
void submit_fence(WGFence *fence) {
SUBMISSION
}
void complete(WGFence *fence) {
    _fence_work_done_callback(0, WGPUStringView{}, fence, nullptr);
}
int main(int argc, char **argv) {
    assert(argc == 2);
    std::string test = argv[1];
    RenderingDeviceDriverWebGPU driver;
    WGFence *fence = new WGFence;
    auto release = [&]() { driver.fence_free(FenceID(fence)); };
    if (test == "empty") {
        release();
    } else if (test == "single_pending") {
        submit_fence(fence);
        release();
        assert(destructions == 0);
        complete(fence);
    } else if (test == "free_before_first") {
        for (int i = 0; i < 3; i++) submit_fence(fence);
        release();
        assert(destructions == 0);
        for (int i = 0; i < 3; i++) complete(fence);
    } else if (test == "free_after_first") {
        for (int i = 0; i < 3; i++) submit_fence(fence);
        complete(fence);
        release();
        complete(fence);
        complete(fence);
    } else if (test == "last_signal") {
        for (int i = 0; i < 3; i++) submit_fence(fence);
        assert(!fence->signaled);
        complete(fence);
        assert(!fence->signaled);
        complete(fence);
        assert(!fence->signaled);
        complete(fence);
        assert(fence->signaled);
        release();
    } else if (test == "resubmit") {
        submit_fence(fence);
        submit_fence(fence);
        complete(fence);
        submit_fence(fence);
        release();
        complete(fence);
        complete(fence);
    } else {
        return 2;
    }
    assert(destructions == 1);
    std::cout << "FENCE_LIFETIME_PASS " << test << " destructions=1\n";
}
"""


def block(text: str, marker: str) -> str:
    start = text.index(marker)
    opening = text.index("{", start)
    depth = 1
    position = opening + 1
    while depth:
        depth += (text[position] == "{") - (text[position] == "}")
        position += 1
    return text[start:position]


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--compiler", default="clang++")
parser.add_argument("--baseline-ref", default="74d783e44d")
parser.add_argument("--output", type=Path, default=Path(__file__).parent / "artifacts")
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
args.output.mkdir(parents=True, exist_ok=True)
report = {"host": platform.platform(), "compiler": args.compiler, "baseline_ref": args.baseline_ref, "variants": []}
for variant in ("baseline", "current"):

    def read(path: str) -> str:
        if variant == "baseline":
            return subprocess.check_output(["git", "show", f"{args.baseline_ref}:{path}"], cwd=root, text=True)
        return (root / path).read_text()

    driver_source = read(DRIVER)
    object_source = read(OBJECTS)
    fence = block(object_source, "struct WGFence {")
    # Add only a destructor observation; field layout and ownership code remain verbatim.
    fence = fence[:-1] + "~WGFence() { ++destructions; }\n};"
    callbacks = driver_source[
        driver_source.index("static void _fence_work_done_callback(") : driver_source.index('// Parse "@group(')
    ]
    free = block(driver_source, "void RenderingDeviceDriverWebGPU::fence_free(")
    submission = re.search(
        r"fence->signaled = false;\s+fence->(?:work_done_pending = true|pending_work_done_callbacks\+\+);",
        driver_source,
    )
    assert submission, "Review production submission extraction after source changes"
    code = (
        """#include <cassert>
#include <cstdint>
#include <iostream>
#include <string>
#define __EMSCRIPTEN__
#define DEV_ASSERT assert
using WGPUQueueWorkDoneStatus = int;
struct WGPUStringView { const char *data = nullptr; size_t length = 0; };
struct WGPUFuture { uint64_t id = 0; };
#define WGPU_FUTURE_INIT {}
int destructions = 0;
struct FenceID { uintptr_t id; explicit FenceID(void *p) : id(reinterpret_cast<uintptr_t>(p)) {} };
class RenderingDeviceDriverWebGPU { public: void fence_free(FenceID); };
"""
        + fence
        + callbacks
        + free
        + TEST_BODY.replace("SUBMISSION", submission[0])
    )
    source = args.output.resolve() / (variant + ".cpp")
    binary = args.output.resolve() / variant
    source.write_text(code)
    build = subprocess.run(
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
    )
    if build.returncode:
        raise RuntimeError(build.stdout + build.stderr)
    records = []
    for case in CASES:
        process = subprocess.run(
            [str(binary), case],
            text=True,
            capture_output=True,
            env={**os.environ, "ASAN_OPTIONS": "detect_leaks=0:abort_on_error=1:halt_on_error=1"},
        )
        output = process.stdout + process.stderr
        (args.output / (variant + "-" + case + ".log")).write_text(output)
        expected_failure = variant == "baseline" and case in EXPECTED_NEGATIVE_FAILURES
        memory_error = "AddressSanitizer: heap-use-after-free" in output
        early_signal = (
            "Assertion failed: (!fence->signaled)" in output or "Assertion `!fence->signaled' failed" in output
        )
        passed = (
            process.returncode != 0 and (early_signal if case == "last_signal" else memory_error)
            if expected_failure
            else process.returncode == 0 and f"FENCE_LIFETIME_PASS {case} destructions=1" in output
        )
        record = {
            "case": case,
            "passed": passed,
            "expected_failure": expected_failure,
            "returncode": process.returncode,
            "heap_use_after_free": memory_error,
            "premature_signal": early_signal,
        }
        records.append(record)
        print(json.dumps({"variant": variant, **record}), flush=True)
    report["variants"].append({
        "variant": variant,
        "driver_sha256": hashlib.sha256(driver_source.encode()).hexdigest(),
        "objects_sha256": hashlib.sha256(object_source.encode()).hexdigest(),
        "extracted_test_sha256": hashlib.sha256(code.encode()).hexdigest(),
        "checks": records,
    })
report["passed"] = all(check["passed"] for variant in report["variants"] for check in variant["checks"])
(args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
raise SystemExit(0 if report["passed"] else 1)
