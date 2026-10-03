"""Backport Emscripten's proxy context lifetime fix without modifying the SDK."""

from pathlib import Path

# https://github.com/emscripten-core/emscripten/pull/26582
# Both emscripten_proxy_finish and cancel_ctx must signal before unlocking:
# the waiting thread can otherwise return and reclaim the stack-allocated ctx.
UNSAFE_ORDER = "    pthread_mutex_unlock(&ctx->sync.mutex);\n    pthread_cond_signal(&ctx->sync.cond);"
SAFE_ORDER = "    pthread_cond_signal(&ctx->sync.cond);\n    pthread_mutex_unlock(&ctx->sync.mutex);"

INTERNAL_INCLUDE_PATHS = (
    "system/lib/libc/musl/src/internal",
    "system/lib/libc/musl/src/include",
    "system/lib/libc/musl/include",
    "system/lib/libc",
    "system/lib/pthread",
)


def needs_proxying_fix(source: str) -> bool:
    unsafe = source.count(UNSAFE_ORDER)
    safe = source.count(SAFE_ORDER)
    if unsafe == 2 and safe == 0:
        return True
    if unsafe == 0 and safe == 2:
        return False
    raise ValueError(
        "Unrecognized Emscripten proxy context implementation; verify the lifetime fix in upstream PR #26582"
    )


def patch_proxying(source: str) -> str:
    if not needs_proxying_fix(source):
        return source
    return source.replace(UNSAFE_ORDER, SAFE_ORDER)


def build_proxying_source(target, source, env):
    # Keep the active SDK's ABI and license header. This object provides all of
    # proxying.c's symbols, so the linker does not extract the old libc member.
    Path(str(target[0])).write_text(patch_proxying(Path(str(source[0])).read_text()))


def add_proxying_objects(env):
    if not env["threads"]:
        return []
    from SCons.Util import WhereIs

    sdk = Path(str(WhereIs("emcc"))).resolve().parent
    source = sdk / "system/lib/pthread/proxying.c"
    if not needs_proxying_fix(source.read_text()):
        return []
    # Link a local copy with upstream's fix. Keep the installed SDK and its
    # cached libc archives unchanged, including for concurrent SDK users.
    proxy_env = env.Clone()
    proxy_env.Prepend(CPPPATH=[str(sdk / path) for path in INTERNAL_INCLUDE_PATHS])
    proxy_env.Append(CPPDEFINES=[("_XOPEN_SOURCE", 700)])
    proxy_env.Append(CCFLAGS=["-fno-builtin"])
    generated = proxy_env.Command("emscripten_proxying.gen.c", str(source), build_proxying_source)
    return proxy_env.Object(generated)
