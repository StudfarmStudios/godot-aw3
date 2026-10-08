#!/usr/bin/env python3
"""Build nested material fixtures and inspect a native WebGPU export-pack bake."""

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

from run_wgsl_cache import records as wgsl_records


def pack_entries(path):
    data = path.read_bytes()
    if data[:4] != b"GDPC":
        raise ValueError("Not a Godot PCK")
    version = struct.unpack_from("<I", data, 4)[0]
    if version != 4:
        raise ValueError(f"Unsupported PCK version {version}")
    flags = struct.unpack_from("<I", data, 20)[0]
    file_base = struct.unpack_from("<Q", data, 24)[0]
    offset = struct.unpack_from("<Q", data, 32)[0]
    count = struct.unpack_from("<I", data, offset)[0]
    offset += 4
    entries = {}
    for _ in range(count):
        length = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        name = data[offset : offset + length].rstrip(b"\x00").decode()
        offset += length
        position, size = struct.unpack_from("<QQ", data, offset)
        offset += 32  # Two u64 values and 16 MD5 bytes.
        entry_flags = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        if flags & 1 or entry_flags & 1:
            raise ValueError("Encrypted PCK not supported")
        if ".godot/shader_cache/" in name:
            entries[name] = data[file_base + position : file_base + position + size]
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", type=Path)
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "artifacts/export")
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument(
        "--wgsl", action="store_true", help="Require the optional WGSL sidecar and render using its extracted cache"
    )
    parser.add_argument(
        "--wgsl-fallbacks", action="store_true", help="Also export with missing, stale and malformed CLI tools"
    )
    parser.add_argument("--tint-cli", type=Path, default=Path(__file__).resolve().parents[2] / "bin/tint_convert_cli")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    project = output / "project"
    if project.exists():
        shutil.rmtree(project)
    project.mkdir()
    source = Path(__file__).parent
    for name in (
        "project.godot",
        "nested_materials.gd",
        "material_holder.gd",
        "generate_export_scene.gd",
        "export_presets.cfg",
    ):
        shutil.copyfile(source / name, project / name)
    config = project / "project.godot"
    config.write_text(config.read_text().replace("res://main.tscn", "res://coverage.tscn"))
    if args.wgsl:
        with (project / "export_presets.cfg").open("a") as preset:
            preset.write("\nshader_baker/tint_cli=" + json.dumps(str(args.tint_cli.resolve())) + "\n")
    result = {
        "passed": False,
        "host": platform.platform(),
        "engine_sha256": hashlib.sha256(args.engine.read_bytes()).hexdigest(),
        "runs": [],
    }

    def run(name, arguments, directory=project):
        command = [str(args.engine.resolve()), "--path", str(directory), *arguments]
        started = time.monotonic()
        proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            log, _ = proc.communicate(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            log, _ = proc.communicate()
        (output / f"{name}.log").write_text(log)
        errors = [
            line
            for line in log.splitlines()
            if re.search(r"ERROR:|SCRIPT ERROR:|GPUValidationError|Program crashed", line)
        ]
        record = {
            "name": name,
            "command": command,
            "returncode": proc.returncode,
            "seconds": time.monotonic() - started,
            "errors": errors,
        }
        result["runs"].append(record)
        print(json.dumps(record), flush=True)
        if proc.returncode != 0 or errors:
            raise RuntimeError(f"{name} failed; inspect its log")
        return log

    try:
        run("generate", ["--headless", "--script", "res://generate_export_scene.gd"])
        native = [
            "--rendering-driver",
            "webgpu",
            "--rendering-method",
            "forward_plus",
            "--render-thread",
            "separate",
            "--verbose",
        ]
        run("import", [*native, "--editor", "--import", "--quit"])
        pack = output / "coverage.pck"
        log = run("export", [*native, "--export-pack", "WebGPU", str(pack)])
        expected = json.loads((project / "expected_materials.json").read_text())
        collected = re.findall(r'Shader baker collected material "([^"\r\n]+)"', log)
        missing = sorted(set(expected) - set(collected))
        result["expected_materials"] = expected
        result["collected_materials"] = collected
        result["missing_materials"] = missing
        entries = pack_entries(pack)
        result["cache_files"] = {name: len(data) for name, data in entries.items()}
        if missing or not entries:
            raise RuntimeError("Export missed named materials or produced no packaged shader cache")
        for name, data in entries.items():
            if name.endswith("/wgsl_seed.bin"):
                wgsl_records(data)
                continue
            if data[:4] != b"GDSC" or struct.unpack_from("<I", data, 4)[0] != 4:
                raise RuntimeError(f"Unexpected cache framing: {name}")
        if args.wgsl:
            seed = entries.get(".godot/shader_cache/wgsl_seed.bin")
            if not seed:
                raise RuntimeError("Export did not package a WGSL seed")
            count = len(wgsl_records(seed))
            summary = re.search(
                r"WGSL seed: (\d+) translated, (\d+) failed, (\d+) source modules; translator/profile ([0-9a-f]{64})",
                log,
            )
            if summary is None or int(summary[1]) != count or seed[8:40].hex() != summary[4]:
                raise RuntimeError("WGSL seed summary or translator identity does not match packaged records")
            result["wgsl"] = {
                "entries": count,
                "failed": int(summary[2]),
                "source_modules": int(summary[3]),
                "fingerprint": summary[4],
            }
            runtime = output / "runtime"
            runtime.mkdir(exist_ok=True)
            for name in ("project.godot", "main.tscn", "main.gd"):
                shutil.copyfile(source / name, runtime / name)
            runtime_config = runtime / "project.godot"
            runtime_config.write_text(
                runtime_config.read_text().replace(
                    "WebGPU shader baker regressions", "WebGPU-baked-seed-" + uuid.uuid4().hex
                )
            )
            for name, data in entries.items():
                path = runtime / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            runtime_log = run("baked-seed-render", native, runtime)
            if (
                "SHADER_CACHE_COMPLETE" not in runtime_log
                or f"seeded {count} entries from bundled cache ({count} with SPIR-V binding metadata)"
                not in runtime_log
            ):
                raise RuntimeError("Packaged WGSL/analysis did not load or scene did not render")
            if args.wgsl_fallbacks:
                presets = project / "export_presets.cfg"
                original_presets = presets.read_text()
                stale = output / "stale-tint-cli"
                stale.write_text("#!/usr/bin/env python3\nprint('stale-translator')\n")
                stale.chmod(0o755)
                malformed = output / "malformed-tint-cli"
                malformed.write_text(
                    "#!/usr/bin/env python3\nimport sys\nprint("
                    + repr(summary[4])
                    + " if sys.argv[1] == '--fingerprint' else 'malformed JSON')\n"
                )
                malformed.chmod(0o755)
                try:
                    for label, cli in (
                        ("missing", output / "missing-tint-cli"),
                        ("stale", stale),
                        ("malformed", malformed),
                    ):
                        presets.write_text(
                            re.sub(
                                r"^shader_baker/tint_cli=.*$",
                                "shader_baker/tint_cli=" + json.dumps(str(cli)),
                                original_presets,
                                flags=re.MULTILINE,
                            )
                        )
                        fallback_pack = output / (label + ".pck")
                        fallback_log = run(
                            "fallback-" + label, [*native, "--export-pack", "WebGPU", str(fallback_pack)]
                        )
                        fallback_entries = pack_entries(fallback_pack)
                        if not fallback_entries or any(name.endswith("wgsl_seed.bin") for name in fallback_entries):
                            raise RuntimeError(label + " CLI fallback lost compact SPIR-V or shipped invalid WGSL")
                        expected = "WGSL seed is partial" if label == "malformed" else "WGSL baking skipped"
                        if expected not in fallback_log:
                            raise RuntimeError(label + " CLI fallback did not report its limitation")
                finally:
                    presets.write_text(original_presets)
        result["passed"] = True
    except Exception as exc:
        result["failure"] = str(exc)
    finally:
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
