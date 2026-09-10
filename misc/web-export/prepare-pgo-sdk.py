#!/usr/bin/env python3
"""Fix Emscripten's JS spelling of LLVM PGO metadata exports.

LLVM retains COMDAT profile data with names containing a dot and CFG hash.
Emscripten 4.0.20 exports these as bare JS identifiers and rejects the link.
Only the JS identifier is escaped; the WASM export, counters, and CFG hashes
remain intact. Ordinary non-PGO symbols are unchanged.
"""
import argparse
from pathlib import Path
import shutil


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emscripten-dir", type=Path, required=True)
    args = parser.parse_args()
    path = args.emscripten_dir / "tools/shared.py"
    text = path.read_text()
    marker = "# AW3: escape LLVM PGO metadata identifiers without changing WASM names."
    if marker in text:
        print("Emscripten PGO identifier fix already present")
        return
    old = "  if is_user_export(name):\n    return '_' + name\n  return name\n"
    if text.count(old) != 1:
        parser.error("unexpected Emscripten asmjs_mangle implementation; inspect this SDK before patching")
    new = """  # AW3: escape LLVM PGO metadata identifiers without changing WASM names.
  if name.startswith(('__profd_', '__profc_', '__profb_', '__profvp_')):
    name = ''.join(c if c.isascii() and (c.isalnum() or c == '_')
                   else '$%x$' % ord(c) for c in name)
  if is_user_export(name):
    return '_' + name
  return name
"""
    backup = path.with_name(path.name + ".aw3-pgo-original")
    if backup.exists():
        parser.error(f"backup already exists at {backup}; inspect before applying again")
    shutil.copy2(path, backup)
    path.write_text(text.replace(old, new))
    print(f"Applied PGO identifier fix; original saved at {backup}")


if __name__ == "__main__":
    main()
