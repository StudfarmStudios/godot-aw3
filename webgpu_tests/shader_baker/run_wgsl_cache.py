#!/usr/bin/env python3
"""Check the real WGSL v4 identity, atomic parsing and bundled-cache priority."""

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


def records(data):
    if len(data) < 40 or data[:8] != b"WGSC\x04\0\0\0":
        raise ValueError("Expected WGSL cache v4")
    result, offset = [], 40
    while offset < len(data):
        if len(data) - offset < 20:
            raise ValueError("Truncated record")
        key, compressed, raw, checksum = struct.unpack_from("<QIII", data, offset)
        end = offset + 20 + compressed
        if not compressed or not raw or end > len(data):
            raise ValueError("Invalid record size")
        result.append((offset, end, key))
        offset = end
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", type=Path)
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "artifacts/wgsl")
    parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()
    # Native runs must not consume an unrelated global deployment seed.
    if Path("/tmp/wgsl_seed.bin").exists():
        raise SystemExit("Move the existing /tmp/wgsl_seed.bin before running this isolated fixture")
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
        config.read_text().replace("WebGPU shader baker regressions", "WebGPU-wgsl-test-" + uuid.uuid4().hex)
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
    runs = []
    result = {
        "passed": False,
        "host": platform.platform(),
        "command": command,
        "runs": runs,
        "engine_sha256": hashlib.sha256(args.engine.read_bytes()).hexdigest(),
    }

    def run(name, expected=(), forbidden=()):
        started = time.monotonic()
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        timeout = False
        try:
            log, _ = process.communicate(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            timeout = True
            process.kill()
            log, _ = process.communicate()
        (output / (name + ".log")).write_text(log)
        errors = [
            line
            for line in log.splitlines()
            if re.search(r"ERROR:|SCRIPT ERROR:|GPUValidationError|Program crashed", line)
        ]
        errors += ["Missing expected log: " + pattern for pattern in expected if not re.search(pattern, log)]
        errors += ["Unexpected log: " + pattern for pattern in forbidden if re.search(pattern, log)]
        passed = (
            process.returncode == 0
            and not timeout
            and not errors
            and "SHADER_CACHE_COMPLETE" in log
            and "WebGPU 1.0 - Forward+" in log
        )
        record = {
            "name": name,
            "passed": passed,
            "returncode": process.returncode,
            "timed_out": timeout,
            "seconds": time.monotonic() - started,
            "errors": errors,
            "cache_log": [line for line in log.splitlines() if "[WGSLCACHE]" in line],
        }
        runs.append(record)
        print(json.dumps(record), flush=True)
        if not passed:
            raise RuntimeError(name + " failed")
        return log

    try:
        log = run("01-cold")
        user = Path(re.search(r"SHADER_CACHE_USER ([^\r\n]+)", log)[1])
        fingerprint = re.search(r"\[WGSLCACHE\] translator/profile ([0-9a-f]{64})", log)[1]
        caches = list((user / "wgsl_cache").glob("*-v4.bin"))
        if len(caches) != 1:
            raise RuntimeError("Expected one newly written v4 cache")
        cache = caches[0]
        original = cache.read_bytes()
        entries = records(original)
        if len(entries) < 2 or original[8:40].hex() != fingerprint:
            raise RuntimeError("Engine cache has missing entries or wrong translator identity")
        result.update(user_data=str(user), fingerprint=fingerprint, entry_count=len(entries))
        bundled = project / ".godot/shader_cache/wgsl_seed.bin"
        bundled.parent.mkdir(parents=True, exist_ok=True)
        bundled.write_bytes(original)
        seeded = rf"\[WGSLCACHE\] seeded {len(entries)} entries"
        loaded = rf"\[WGSLCACHE\] loaded {len(entries)} entries"
        run("02-both-valid-bundled-first", [seeded], [r"\[WGSLCACHE\] loaded [1-9]"])
        # Same hashes but deliberately mismatched WGSL records in the disk file.
        # Every valid bundled entry must win before these are ever considered.
        swapped = bytearray(original)
        for index, (offset, _, _) in enumerate(entries):
            struct.pack_into("<Q", swapped, offset, entries[(index + 1) % len(entries)][2])
        cache.write_bytes(swapped)
        run("03-bundled-wins-over-conflicting-disk", [seeded], [r"\[WGSLCACHE\] loaded [1-9]"])
        cache.write_bytes(original)
        for version in (2, 3):
            bundled.write_bytes(b"WGSC" + struct.pack("<I", version) + original[40:])
            run(f"04-legacy-v{version}-falls-back", ["ignored incompatible bundled cache", loaded], ["seeded"])
        changed = bytearray(original)
        changed[8] ^= 1
        bundled.write_bytes(changed)
        run("05-stale-profile-falls-back", ["ignored incompatible bundled cache", loaded], ["seeded"])
        bundled.write_bytes(original[:39])
        run("06-short-identity-falls-back", ["ignored incompatible bundled cache", loaded], ["seeded"])
        bundled.write_bytes(original[:-1])
        run("07-late-record-truncation-is-atomic", ["ignored corrupt bundled cache", loaded], ["seeded"])
        changed = bytearray(original)
        changed[entries[-1][0] + 16] ^= 1
        bundled.write_bytes(changed)
        run("08-late-checksum-failure-is-atomic", ["ignored corrupt bundled cache", loaded], ["seeded"])
        bundled.unlink()
        cache.write_bytes(b"WGSC\x03\0\0\0" + original[40:])
        run("09-legacy-disk-is-regenerated", ["incompatible translator/profile cache discarded"])
        if records(cache.read_bytes()) == [] or cache.read_bytes()[8:40].hex() != fingerprint:
            raise RuntimeError("Legacy disk cache was not regenerated")
        changed = bytearray(original)
        changed[8] ^= 1
        cache.write_bytes(changed)
        run("10-stale-disk-is-regenerated", ["incompatible translator/profile cache discarded"])
        if not records(cache.read_bytes()) or cache.read_bytes()[8:40].hex() != fingerprint:
            raise RuntimeError("Stale disk cache was not regenerated")
        result["passed"] = True
    except Exception as exc:
        result["failure"] = str(exc)
    finally:
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
