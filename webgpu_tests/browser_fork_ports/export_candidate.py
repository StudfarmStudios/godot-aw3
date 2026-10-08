#!/usr/bin/env python3
"""Export a copied fixture with the exact candidate template; never install it globally."""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", type=Path)
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--threads", action="store_true")
    parser.add_argument("--bake", action="store_true")
    parser.add_argument("--tint-cli", type=Path)
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    source = args.project.resolve()
    output = args.output.resolve()
    if output == source or source in output.parents:
        raise SystemExit("Output must be outside the source fixture")
    args.template = args.template.resolve(strict=True)
    args.engine = args.engine.resolve(strict=True)
    if args.bake and not args.tint_cli:
        raise SystemExit("--bake requires the matching --tint-cli")
    project = output / "project"
    if project.exists():
        raise SystemExit("Choose a fresh output directory; the copied project already exists")
    output.mkdir(parents=True, exist_ok=True)
    shutil.copytree(
        source,
        project,
        ignore=shutil.ignore_patterns(
            ".godot", "export", "exports", "artifacts", "results", "node_modules", "__pycache__"
        ),
    )
    config = project / "project.godot"
    text = config.read_text()
    if "[rendering]" not in text:
        text += "\n[rendering]\n"
    for key, value in (("renderer/rendering_method.web", "forward_plus"), ("rendering_device/driver.web", "webgpu")):
        text = re.sub(r"^" + re.escape(key) + r"=.*\n?", "", text, flags=re.MULTILINE)
        text = text.replace("[rendering]", "[rendering]\n" + key + "=" + json.dumps(value), 1)
    config.write_text(text)
    preset = """[preset.0]
name="Candidate WebGPU"
platform="Web"
runnable=true
export_filter="all_resources"
include_filter="*.woff2,*.ttf,*.ttc"
exclude_filter=""
export_path=""

[preset.0.options]
variant/extensions_support=false
vram_texture_compression/for_desktop=true
vram_texture_compression/for_mobile=false
html/export_icon=false
html/canvas_resize_policy=1
progressive_web_app/enabled=false
"""
    preset += "custom_template/release=" + json.dumps(str(args.template)) + "\n"
    preset += "variant/thread_support=" + str(args.threads).lower() + "\n"
    preset += "shader_baker/enabled=" + str(args.bake).lower() + "\n"
    if args.tint_cli:
        preset += "shader_baker/tint_cli=" + json.dumps(str(args.tint_cli.resolve(strict=True))) + "\n"
    (project / "export_presets.cfg").write_text(preset)
    exported = output / "export"
    exported.mkdir()
    result = {
        "passed": False,
        "engine": str(args.engine),
        "template": str(args.template),
        "threads": args.threads,
        "bake": args.bake,
        "source": str(source),
        "runs": [],
    }
    for label, path in (("engine", args.engine), ("template", args.template)):
        result[label + "_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    driver = (
        ["--rendering-driver", "webgpu", "--rendering-method", "forward_plus", "--render-thread", "separate"]
        if args.bake
        else ["--headless"]
    )
    try:
        for label, arguments in (
            ("import", ["--editor", "--import", "--quit"]),
            ("export", ["--export-release", "Candidate WebGPU", str(exported / "index.html")]),
        ):
            command = [str(args.engine), "--path", str(project), "--verbose", *driver, *arguments]
            started = time.monotonic()
            process = subprocess.run(command, capture_output=True, text=True, timeout=args.timeout)
            log = process.stdout + process.stderr
            (output / (label + ".log")).write_text(log)
            errors = [
                line
                for line in log.splitlines()
                if re.search(r"ERROR:|SCRIPT ERROR:|GPUValidationError|Program crashed", line)
            ]
            result["runs"].append({
                "stage": label,
                "command": command,
                "returncode": process.returncode,
                "errors": errors,
                "seconds": time.monotonic() - started,
            })
            if process.returncode or errors:
                raise RuntimeError(label + " failed; see " + str(output / (label + ".log")))
        files = [exported / ("index." + extension) for extension in ("html", "js", "wasm", "pck")]
        if not all(path.is_file() and path.stat().st_size for path in files):
            raise RuntimeError("Export did not produce all nonempty HTML/JS/Wasm/PCK files")
        if args.bake:
            summary = re.search(
                r"WGSL seed: (\d+) translated, (\d+) failed, (\d+) source modules; translator/profile ([0-9a-f]{64})",
                log,
            )
            if summary is None or int(summary[2]) != 0 or int(summary[1]) == 0:
                raise RuntimeError("WGSL bake did not complete without translation failures")
            result["wgsl"] = {
                "entries": int(summary[1]),
                "failed": int(summary[2]),
                "source_modules": int(summary[3]),
                "fingerprint": summary[4],
            }
        result["files"] = {
            path.name: {"bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            for path in files
        }
        result["passed"] = True
    except Exception as error:
        result["error"] = str(error)
    (output / "export-result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)
    raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
