#!/usr/bin/env python3
"""Prepare browser fixture assets using bundled Inter and an authored SVG font."""

import argparse
import hashlib
import importlib.util
import json
import shutil
from pathlib import Path

from fontTools.ttLib import TTFont

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
source = Path(__file__).resolve().parent
output = args.output.resolve()
if output.exists():
    raise SystemExit("Choose a fresh output directory")
shutil.copytree(source / "project", output)
shutil.copyfile(root / "thirdparty/fonts/Inter_Regular.woff2", output / "inter.woff2")
spec = importlib.util.spec_from_file_location("font_fixture", root / "webgpu_tests/font_atlas/run_extended.py")
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.make_svg_font(output / "authored-svg.ttf")
# FontBuilder defaults to wall-clock timestamps. Fix these so the prepared
# fixture and exported asset hashes can be reproduced on another machine.

font = TTFont(output / "authored-svg.ttf", recalcTimestamp=False)
font["head"].created = font["head"].modified = 3406620153
font.save(output / "authored-svg.ttf")
print(
    json.dumps({
        "project": str(output),
        "assets": {
            path.name: hashlib.sha256(path.read_bytes()).hexdigest()
            for path in output.iterdir()
            if path.suffix in (".ttf", ".woff2")
        },
    })
)
