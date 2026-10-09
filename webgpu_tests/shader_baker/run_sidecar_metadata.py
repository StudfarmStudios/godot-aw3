#!/usr/bin/env python3
"""Compare every exported seed's metadata with production runtime source analysis."""

import argparse
import ctypes
import ctypes.util
import hashlib
import json
import struct
import subprocess
import sys
from pathlib import Path

from run_export import pack_entries
from run_wgsl_cache import records


def murmur(data, seed=0x7F07C65):
    mask = 0xFFFFFFFF

    def rotate(value, bits):
        return ((value << bits) | (value >> (32 - bits))) & mask

    value = seed
    for (word,) in struct.iter_unpack("<I", data):
        word = rotate((word * 0xCC9E2D51) & mask, 15) * 0x1B873593 & mask
        value = (rotate(value ^ word, 13) * 5 + 0xE6546B64) & mask
    value ^= len(data)
    value ^= value >> 16
    value = value * 0x85EBCA6B & mask
    value ^= value >> 13
    value = value * 0xC2B2AE35 & mask
    return value ^ (value >> 16)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", type=Path)
    parser.add_argument("--tint-cli", type=Path, required=True)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    captured = output / "captured"
    captured.mkdir()
    wrapper = output / "capturing-tint"
    wrapper.write_text(
        "#!" + sys.executable + "\nimport os,shutil,sys\nfrom pathlib import Path\n"
        "for source in sys.argv[1:]:\n"
        " if source.endswith('.spv'): shutil.copyfile(source,Path(" + repr(str(captured)) + ")/Path(source).name)\n"
        "os.execv("
        + repr(str(args.tint_cli.resolve()))
        + ", ["
        + repr(str(args.tint_cli.resolve()))
        + "]+sys.argv[1:])\n"
    )
    wrapper.chmod(0o755)
    run = subprocess.run(
        [
            sys.executable,
            str(Path(__file__).with_name("run_export.py")),
            str(args.engine.resolve()),
            "--wgsl",
            "--tint-cli",
            str(wrapper),
            "--output",
            str(output / "export"),
            "--timeout",
            "600",
        ],
        text=True,
        capture_output=True,
    )
    (output / "export-run.log").write_text(run.stdout + run.stderr)
    if run.returncode:
        raise SystemExit("Export failed; inspect " + str(output / "export-run.log"))
    modules = sorted(captured.glob("*.spv"))
    analysis = [
        json.loads(line)
        for line in subprocess.check_output([str(args.probe.resolve()), *map(str, modules)], text=True).splitlines()
    ]
    expected = {}
    for path, item in zip(modules, analysis):
        data = path.read_bytes()
        key = (murmur(data, 0x9E3779B9) << 32) | murmur(data)
        expected[key] = item
    seed = pack_entries(output / "export/coverage.pck")[".godot/shader_cache/wgsl_seed.bin"]
    library = ctypes.util.find_library("zstd")
    if not library:
        raise SystemExit("libzstd required to inspect exported metadata")
    zstd = ctypes.CDLL(library)
    zstd.ZSTD_decompress.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t]
    zstd.ZSTD_decompress.restype = ctypes.c_size_t
    failures = []
    changed = 0
    checked = 0
    for start, end, key in records(seed):
        compressed_size, raw_size = struct.unpack_from("<II", seed, start + 8)
        raw = ctypes.create_string_buffer(raw_size)
        compressed = seed[start + 20 : end]
        if zstd.ZSTD_decompress(raw, raw_size, compressed, compressed_size) != raw_size:
            raise RuntimeError("Invalid compressed record")
        data = raw.raw
        wgsl_size = struct.unpack_from("<I", data)[0]
        cursor = 4 + wgsl_size
        version, count = struct.unpack_from("<II", data, cursor)
        cursor += 8
        keys = sorted(struct.unpack_from("<" + "I" * count, data, cursor))
        cursor += count * 4
        image_count = struct.unpack_from("<I", data, cursor)[0]
        cursor += 4
        images = sorted(list(struct.unpack_from("<IIIII", data, cursor + i * 20)) for i in range(image_count))
        item = expected[key]
        checked += 1
        changed += item["raw"] != item["normalized"]
        if version != 1 or keys != item["normalized"] or images != sorted(item["images"]):
            failures.append({"hash": hex(key), "actual": keys, "expected": item["normalized"]})
    result = {
        "passed": checked == len(modules) and changed > 0 and not failures,
        "checked": checked,
        "captured_modules": len(modules),
        "anisotropic_alias_changes": changed,
        "failures": failures,
        "fingerprint": seed[8:40].hex(),
        "engine_sha256": hashlib.sha256(args.engine.read_bytes()).hexdigest(),
        "probe_sha256": hashlib.sha256(args.probe.read_bytes()).hexdigest(),
        "export": json.loads((output / "export/result.json").read_text()),
    }
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "export"}), flush=True)
    raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
