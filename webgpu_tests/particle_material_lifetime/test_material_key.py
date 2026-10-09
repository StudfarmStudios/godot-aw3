#!/usr/bin/env python3
"""Compile the production particle key and exercise its padding/copy contract."""

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path


def declaration(source, prefix):
    start = source.index(prefix)
    begin = source.index("{", start)
    depth = 1
    end = begin + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--header", type=Path, default=repo / "scene/resources/particle_process_material.h")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compiler", default="clang++")
    parser.add_argument("--expect-failure", action="store_true")
    args = parser.parse_args()
    source = args.header.read_text()
    key = declaration(source, "struct MaterialKey {")
    enums = [declaration(source, "enum " + name + " {") for name in ("Parameter", "ParticleFlags")]
    hash_source = (repo / "core/templates/hashfuncs.h").read_text()
    hash_function = declaration(hash_source, "_FORCE_INLINE_ uint32_t hash_djb2_buffer(")
    fields = re.findall(r"uint64_t (\w+) : (\w+);", key)
    args.output.mkdir(parents=True, exist_ok=True)
    generated = (
        """
#include <cstdint>
#include <cstring>
#include <iostream>
#include <new>
#include <unordered_map>
#define _FORCE_INLINE_ inline
"""
        + ";\n".join([*enums, hash_function, key])
        + ";\n"
    )
    generated += """
static int checks = 0;
static int failures = 0;
static void check(bool ok) { ++checks; if (!ok) { ++failures; } }
struct Hasher { size_t operator()(const MaterialKey &key) const { return MaterialKey::hash(key); } };
using Map = std::unordered_map<MaterialKey, int, Hasher>;
static MaterialKey round_trip(MaterialKey key) { return key; }
static void equivalent(const MaterialKey &a, const MaterialKey &b) {
    check(a == b);
    check(MaterialKey::hash(a) == MaterialKey::hash(b));
    check(!(a < b) && !(b < a));
    Map cache;
    cache.emplace(a, 7);
    const auto found = cache.find(b);
    check(found != cache.end() && found->second == 7);
    check(cache.erase(b) == 1);
}
int main() {
    MaterialKey occupied;
"""
    for name, width in fields:
        generated += f"    occupied.{name} = (uint64_t(1) << {width}) - 1;\n"
    generated += """
    uint8_t mask[sizeof(MaterialKey)];
    std::memcpy(mask, &occupied, sizeof(mask));
    int padding_bits = 0;
    for (uint8_t byte : mask) {
        for (int bit = 0; bit < 8; ++bit) { padding_bits += !(byte & (1 << bit)); }
    }
    check(padding_bits > 0);
    for (int pattern = 0; pattern < 8; ++pattern) {
        MaterialKey a;
"""
    for index, (name, width) in enumerate(fields):
        generated += f"    a.{name} = (uint64_t(pattern * {index + 3}) + 1) & ((uint64_t(1) << {width}) - 1);\n"
    generated += """
        MaterialKey b(a);
        uint8_t *bytes = reinterpret_cast<uint8_t *>(&b);
        for (size_t i = 0; i < sizeof(b); ++i) {
            bytes[i] = (bytes[i] & mask[i]) | (uint8_t(pattern * 37 + 17) & uint8_t(~mask[i]));
        }
        equivalent(a, b);
        MaterialKey copied(b);
        equivalent(a, copied);
        MaterialKey assigned;
        assigned = b;
        equivalent(a, assigned);
        equivalent(a, round_trip(b));
        alignas(MaterialKey) uint8_t placement[sizeof(MaterialKey)];
        std::memset(placement, 0xa5, sizeof(placement));
        auto *placed = new (placement) MaterialKey(b);
        equivalent(a, *placed);
        placed->~MaterialKey();
    }
    Map distinct;
    MaterialKey zero;
    distinct.emplace(zero, 0);
    int expected = 1;
"""
    for name, width in fields:
        generated += f"""
    for (int bit = 0; bit < {width}; ++bit) {{
        MaterialKey changed;
        changed.{name} = uint64_t(1) << bit;
        check(!(zero == changed));
        check((zero < changed) != (changed < zero));
        check(distinct.emplace(changed, expected++).second);
    }}
"""
    generated += """
    check(distinct.size() == size_t(expected));
    std::cout << "{\\"checks\\":" << checks << ",\\"failures\\":" << failures
              << ",\\"padding_bits\\":" << padding_bits << ",\\"distinct_keys\\":" << distinct.size() << "}\\n";
    return failures ? 1 : 0;
}
"""
    cpp = args.output / "material_key.cpp"
    cpp.write_text(generated)
    executable = args.output / "material_key"
    command = [
        args.compiler,
        "-std=c++17",
        "-O2",
        "-g",
        "-fsanitize=address,undefined",
        "-fno-omit-frame-pointer",
        str(cpp),
        "-o",
        str(executable),
    ]
    subprocess.run(command, check=True, capture_output=True, text=True)
    run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)
    result = json.loads(run.stdout)
    result.update({
        "header_sha256": hashlib.sha256(args.header.read_bytes()).hexdigest(),
        "field_count": len(fields),
        "exit_code": run.returncode,
        "sanitizer_errors": bool(run.stderr),
        "expected_failure": args.expect_failure,
    })
    result["pass"] = not run.stderr and (
        (run.returncode == 1 and result["failures"] > 0)
        if args.expect_failure
        else (run.returncode == 0 and result["failures"] == 0)
    )
    (args.output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    raise SystemExit(0 if result["pass"] else 1)


if __name__ == "__main__":
    main()
