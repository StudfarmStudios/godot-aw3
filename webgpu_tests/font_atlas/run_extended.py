#!/usr/bin/env python3
"""Exercise actual LCD, MSDF, bitmap emoji and authored OpenType SVG glyphs."""

import argparse
import hashlib
import json
import platform
import re
import shutil
import subprocess
import time
import uuid
from pathlib import Path


def make_svg_font(path):
    from fontTools.fontBuilder import FontBuilder
    from fontTools.pens.ttGlyphPen import TTGlyphPen
    from fontTools.ttLib import newTable
    from fontTools.ttLib.tables.S_V_G_ import SVGDocument

    builder = FontBuilder(1000, isTTF=True)
    names = [".notdef", "A", "B"]
    builder.setupGlyphOrder(names)
    builder.setupCharacterMap({65: "A", 66: "B"})
    glyphs = {}
    for name in names:
        pen = TTGlyphPen(None)
        if name != ".notdef":
            pen.moveTo((100, 0))
            pen.lineTo((800, 0))
            pen.lineTo((800, 800))
            pen.lineTo((100, 800))
            pen.closePath()
        glyphs[name] = pen.glyph()
    builder.setupGlyf(glyphs)
    builder.setupHorizontalMetrics({name: (1000, 0) for name in names})
    builder.setupHorizontalHeader(ascent=800, descent=-200)
    builder.setupNameTable({
        "familyName": "Godot SVG Regression",
        "styleName": "Regular",
        "uniqueFontIdentifier": "Godot SVG Regression",
        "fullName": "Godot SVG Regression",
        "psName": "GodotSVGRegression",
    })
    builder.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
    builder.setupPost()
    builder.setupMaxp()
    svg = newTable("SVG ")
    svg.docList = [
        SVGDocument(
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -1000 1000 1000"><rect id="glyph{index}" x="100" y="-800" width="700" height="800" fill="{color}"/></svg>',
            index,
            index,
        )
        for index, color in ((1, "#00ff00"), (2, "#0000ff"))
    ]
    builder.font["SVG "] = svg
    builder.save(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", type=Path)
    parser.add_argument("--emoji-font", type=Path, default=Path("/System/Library/Fonts/Apple Color Emoji.ttc"))
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "artifacts/extended")
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    if not args.emoji_font.is_file():
        raise SystemExit("Supply --emoji-font with a bitmap color font containing U+1F600 and U+1F604")
    source = Path(__file__).resolve().parent
    output = args.output.resolve()
    project = output / "project"
    project.mkdir(parents=True, exist_ok=True)
    for name in ("main.gd", "extended.gd"):
        shutil.copyfile(source / name, project / name)
    (project / "project.godot").write_text(
        (source / "project.godot")
        .read_text()
        .replace("WebGPU font atlas regressions", "WebGPU-font-extended-" + uuid.uuid4().hex)
        + "\n[gui]\ntheme/lcd_subpixel_layout=1\n"
    )
    (project / "main.tscn").write_text(
        '[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://extended.gd" id="1"]\n[node name="FontExtended" type="Node"]\nscript = ExtResource("1")\n'
    )
    svg_font = output / "authored-svg.ttf"
    make_svg_font(svg_font)
    font = source.parents[1] / "thirdparty/fonts/Inter_Regular.woff2"
    command = [
        str(args.engine.resolve()),
        "--path",
        str(project),
        "--rendering-method",
        "forward_plus",
        "--rendering-driver",
        "webgpu",
        "--render-thread",
        "separate",
        "--",
        f"--font={font}",
        f"--emoji={args.emoji_font.resolve()}",
        f"--svg={svg_font}",
    ]
    started = time.monotonic()
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    timeout = False
    try:
        log, _ = process.communicate(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        timeout = True
        process.kill()
        log, _ = process.communicate()
    errors = [
        line
        for line in log.splitlines()
        if re.search(r"ERROR:|SCRIPT ERROR:|GPUValidationError|FONT_TEST FAIL|Program crashed", line)
    ]
    complete = re.search(r"FONT_TEST COMPLETE passed=(\d+) failed=(\d+)", log)
    passed = (
        process.returncode == 0
        and not timeout
        and not errors
        and complete is not None
        and int(complete[1]) == 53
        and int(complete[2]) == 0
    )
    images = re.findall(r"FONT_EXT_IMAGE ([^\r\n]+)", log)
    (output / "run.log").write_text(log)
    for image in images:
        if Path(image).is_file():
            shutil.copyfile(image, output / Path(image).name)
        else:
            errors.append("Missing image " + image)
            passed = False
    result = {
        "passed": passed,
        "checks": int(complete[1]) + int(complete[2]) if complete else 0,
        "errors": errors,
        "returncode": process.returncode,
        "timed_out": timeout,
        "seconds": time.monotonic() - started,
        "host": platform.platform(),
        "command": command,
        "engine_sha256": hashlib.sha256(args.engine.read_bytes()).hexdigest(),
        "font_sha256": {
            str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in (font, args.emoji_font, svg_font)
        },
        "images": [Path(image).name for image in images],
    }
    (output / "run.log").write_text(log)
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)
    raise SystemExit(0 if passed else 1)


if __name__ == "__main__":
    main()
