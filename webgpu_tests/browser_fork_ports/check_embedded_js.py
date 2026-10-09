#!/usr/bin/env python3
"""Parse embedded WebGPU JavaScript, including normally disabled verbose diagnostics."""

import json
import re
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
pattern = re.compile(r"\b(?:MAIN_THREAD_EM_ASM|EM_ASM(?:_INT|_PTR)?|WEBGPU_DIAG(?:_INT)?)\s*\(\s*\{")
checks = []
for source in sorted((root / "drivers/webgpu").glob("*.cpp")):
    text = source.read_text()
    for match in pattern.finditer(text):
        start = match.end() - 1
        position, depth, quote, comment = start, 0, "", ""
        while position < len(text):
            char, pair = text[position], text[position : position + 2]
            if comment:
                if comment == "//" and char == "\n":
                    comment = ""
                elif comment == "/*" and pair == "*/":
                    comment = ""
                    position += 1
            elif quote:
                if char == "\\":
                    position += 1
                elif char == quote:
                    quote = ""
            elif pair in ("//", "/*"):
                comment = pair
                position += 1
            elif char in ("'", '"', "`"):
                quote = char
            elif char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    break
            position += 1
        if depth != 0:
            raise RuntimeError(f"Unterminated embedded JavaScript in {source}:{text.count(chr(10), 0, start) + 1}")
        with tempfile.NamedTemporaryFile(mode="w", suffix=".js") as candidate:
            candidate.write("function embedded_webgpu_js() " + text[start : position + 1] + "\n")
            candidate.flush()
            result = subprocess.run(["node", "--check", candidate.name], text=True, capture_output=True)
        checks.append({
            "file": source.relative_to(root).as_posix(),
            "line": text.count("\n", 0, start) + 1,
            "passed": result.returncode == 0,
            "error": result.stderr,
        })
assert checks, "No embedded WebGPU JavaScript found"
print(json.dumps({"passed": all(check["passed"] for check in checks), "checks": checks}, indent=2))
raise SystemExit(0 if all(check["passed"] for check in checks) else 1)
