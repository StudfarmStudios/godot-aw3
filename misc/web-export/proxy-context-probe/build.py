#!/usr/bin/env python3
"""Build before/after browser probes without modifying the Emscripten SDK."""

import argparse
import importlib.util
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("proxying", HERE.parents[2] / "platform/web/emscripten_proxying.py")
assert SPEC is not None and SPEC.loader is not None
proxying = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proxying)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emscripten-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    sdk = args.emscripten_dir.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    original = (sdk / "system/lib/pthread/proxying.c").read_text()
    if not proxying.needs_proxying_fix(original):
        parser.error("The selected SDK already has the upstream fix; use an affected SDK for the before/after probe")
    for mode, source in (("before", original), ("after", proxying.patch_proxying(original))):
        source = "void aw3_probe_before_lock(void);\nvoid aw3_probe_after_unlock(void *, void *);\n" + source
        before_lock = "  pthread_mutex_lock(&ctx.sync.mutex);"
        after_unlock = "    pthread_mutex_unlock(&ctx->sync.mutex);"
        assert source.count(before_lock) == 1 and source.count(after_unlock) == 2
        source = source.replace(before_lock, "  aw3_probe_before_lock();\n" + before_lock)
        source = source.replace(after_unlock, after_unlock + "\n    aw3_probe_after_unlock(ctx, &ctx->sync.cond);")
        path = output / f"proxying-{mode}.c"
        path.write_text(source)
        subprocess.run(
            [
                str(sdk / "emcc"),
                str(path),
                str(HERE / "probe.c"),
                *["-I" + str(sdk / include) for include in proxying.INTERNAL_INCLUDE_PATHS],
                "-pthread",
                "-O2",
                "-DNDEBUG",
                "-flto=thin",
                "-fno-builtin",
                "-sPROXY_TO_PTHREAD=1",
                "-sPTHREAD_POOL_SIZE=6",
                "-sEXIT_RUNTIME=1",
                "--profiling-funcs",
                "-o",
                str(output / f"{mode}.js"),
            ],
            check=True,
        )
        (output / f"{mode}.html").write_text(
            f'<!doctype html><meta charset="utf-8"><title>Proxy context {mode}</title><script src="{mode}.js"></script>'
        )


if __name__ == "__main__":
    main()
