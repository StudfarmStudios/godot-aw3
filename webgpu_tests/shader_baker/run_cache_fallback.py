#!/usr/bin/env python3
"""Exercise real ShaderRD packaged-cache precedence and transactional fallback."""

import argparse
import hashlib
import json
import platform
import re
import shutil
import struct
import subprocess
import time
import uuid
from pathlib import Path


def variants(data):
    if len(data) < 12 or data[:4] != b"GDSC" or struct.unpack_from("<I", data, 4)[0] != 4:
        raise ValueError("not GDSC v4")
    count = struct.unpack_from("<I", data, 8)[0]
    offset, entries = 12, []
    for _ in range(count):
        size = struct.unpack_from("<I", data, offset)[0]
        entries.append((offset, offset + 4, size))
        offset += 4 + size
    if offset != len(data):
        raise ValueError("invalid GDSC framing")
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", type=Path)
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "artifacts/cache")
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument(
        "--placeholders",
        action="store_true",
        help="Enable TAA late to exercise existing Forward+ advanced-group placeholders",
    )
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    project = output / "project"
    if project.exists():
        shutil.rmtree(project)
    project.mkdir()
    for name in ("project.godot", "main.tscn", "main.gd"):
        shutil.copyfile(Path(__file__).parent / name, project / name)
    config = project / "project.godot"
    config.write_text(
        config.read_text().replace("WebGPU shader baker regressions", f"WebGPU-cache-test-{uuid.uuid4().hex}")
    )
    command = [
        str(args.engine.resolve()),
        "--path",
        str(project),
        "--rendering-driver",
        "webgpu",
        "--rendering-method",
        "forward_plus",
        "--render-thread",
        "separate",
        "--verbose",
    ]
    if args.placeholders:
        command.extend(["--", "--placeholders"])
    runs = []

    def run(name, expected_path=None, allow_container_error=False):
        started = time.monotonic()
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        timed_out = False
        try:
            log, _ = process.communicate(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            process.kill()
            log, _ = process.communicate()
        (output / f"{name}.log").write_text(log)
        errors = [
            line
            for line in log.splitlines()
            if re.search(r"ERROR:|SCRIPT ERROR:|GPUValidationError|Program crashed", line)
        ]
        if allow_container_error:
            errors = [
                line
                for line in errors
                if not any(
                    text in line
                    for text in (
                        "Unsupported version in shader container.",
                        "Failed to parse shader container from binary.",
                        "Not enough bytes for header extra data in shader container.",
                        "Invalid shader count in shader container.",
                        "Invalid uniform set count in shader container.",
                        "Invalid specialization count in shader container.",
                        "Invalid uniform count in shader container.",
                        "Not enough bytes for stages in shader container.",
                        "Invalid reflected shader stage in shader container.",
                    )
                )
            ]
        if args.placeholders and expected_path:
            log_after_enable = log.partition("SHADER_CACHE_ADVANCED_ENABLE")[2]
            if expected_path not in log_after_enable:
                errors.append("Expected cache was not loaded after enabling the advanced group")
        hits = re.findall(r"Loaded shader cache file ([^\r\n]+)", log)
        passed = (
            process.returncode == 0
            and not timed_out
            and not errors
            and "SHADER_CACHE_COMPLETE" in log
            and "WebGPU 1.0 - Forward+" in log
            and (expected_path is None or expected_path in hits)
        )
        record = {
            "name": name,
            "passed": passed,
            "returncode": process.returncode,
            "timed_out": timed_out,
            "seconds": time.monotonic() - started,
            "expected_cache_hit": expected_path,
            "cache_hits": hits,
            "errors": errors,
        }
        runs.append(record)
        print(json.dumps({key: value for key, value in record.items() if key != "cache_hits"}), flush=True)
        if not passed:
            raise RuntimeError(f"{name} failed; inspect {output / (name + '.log')}")
        return log

    result = {
        "passed": False,
        "host": platform.platform(),
        "engine_sha256": hashlib.sha256(args.engine.read_bytes()).hexdigest(),
        "command": command,
        "runs": runs,
    }
    try:
        log = run("01-cold")
        user_data = Path(re.search(r"SHADER_CACHE_USER ([^\r\n]+)", log)[1])
        result["user_data"] = str(user_data)
        user_cache = user_data / "shader_cache"
        packaged = project / ".godot/shader_cache"
        shutil.copytree(user_cache, packaged)
        candidates = []
        advanced_group = None
        if args.placeholders:
            match = re.search(r"Shader 'SceneForwardClusteredShaderRD' \(group 1\) SHA256: ([0-9a-f]+)", log)
            if match is None:
                raise RuntimeError("Could not identify advanced shader group")
            advanced_group = match[1]
        for file in user_cache.rglob("*.webgpu.cache"):
            if advanced_group and (
                "SceneForwardClusteredShaderRD" not in file.parts or advanced_group not in file.parts
            ):
                continue
            entries = [entry for entry in variants(file.read_bytes()) if entry[2]]
            if len(entries) >= 2:
                candidates.append((file.stat().st_size, file, entries))
        if not candidates:
            raise RuntimeError("No multi-variant cache was produced")
        _, target, entries = min(candidates)
        relative = target.relative_to(user_cache)
        result["target"] = str(relative)
        result["nonempty_variants"] = len(entries)
        original = target.read_bytes()
        bundled = packaged / relative
        packaged_hit = "res://.godot/shader_cache/" + relative.as_posix()
        user_hit = "user://shader_cache/" + relative.as_posix()
        run("02-both-valid-packaged-first", packaged_hit)
        bundled.write_bytes(b"BAD!" + original[4:])
        run("03-bad-header-falls-back", user_hit)
        bundled.write_bytes(original[:-1])
        run("04-truncated-falls-back", user_hit)
        size_pos, code_pos, size = entries[-1]
        bundled.write_bytes(original[:size_pos] + struct.pack("<I", 0) + original[code_pos + size :])
        run("05-missing-late-variant-falls-back", user_hit)
        damaged = bytearray(original)
        struct.pack_into("<I", damaged, code_pos + 4, 0x7FFFFFFF)
        bundled.write_bytes(damaged)
        run("06-late-container-failure-falls-back", user_hit, allow_container_error=True)
        run("07-repeat-late-container-failure", user_hit, allow_container_error=True)
        # Keep the outer GDSC valid while corrupting one later container.
        # These counts must be rejected before vector allocation or memcpy.
        code = original[code_pos : code_pos + size]
        mutations = [("short-header-extension", code[:20])]
        for label, offset in (
            ("shader-count", 16),
            ("set-count", 72),
            ("specialization-count", 44),
            ("stage-count", 84),
        ):
            changed = bytearray(code)
            struct.pack_into("<I", changed, offset, 0x7FFFFFFF)
            mutations.append((label, changed))
        name_size = struct.unpack_from("<I", code, 88)[0]
        first_set = 96 + (name_size + 3) // 4 * 4
        if struct.unpack_from("<I", code, 72)[0]:
            changed = bytearray(code)
            struct.pack_into("<I", changed, first_set, 0x7FFFFFFF)
            mutations.append(("uniform-count", changed))
        for index, (label, changed) in enumerate(mutations, 8):
            bundled.write_bytes(
                original[:size_pos] + struct.pack("<I", len(changed)) + changed + original[code_pos + size :]
            )
            run(f"{index:02d}-inner-{label}-falls-back", user_hit, allow_container_error=True)
        target.write_bytes(b"BAD!" + original[4:])
        bundled.write_bytes(b"BAD!" + original[4:])
        run("99-both-invalid-recompile")
        if target.read_bytes()[:4] != b"GDSC":
            raise RuntimeError("Source fallback did not regenerate valid user cache")
        result["passed"] = True
    except Exception as exc:
        result["failure"] = str(exc)
    finally:
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
