"""Local, content-addressed cache for the PGO helper's self-contained LLVM inputs.

No headers or libraries are compiled here: entries cover one exported bitcode
module, its inspected/translated IR, and the resulting object. Unknown compiler
setups bypass the cache instead of guessing at their dependencies.
"""

import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def cache_toolchain(emcc):
    """Fingerprint the activated SDK's driver and compiler, not just its version."""
    executable = shutil.which(emcc)
    if not executable:
        return None
    driver = Path(executable).resolve().parent
    if not (driver / "emcc.py").is_file() or not (driver / "tools/config.py").is_file():
        return None
    # Arbitrary flags/wrappers can refer to additional files. A cache miss is
    # preferable to accepting an incomplete dependency model for those setups.
    overrides = (
        "EMCC_CFLAGS",
        "EMMAKEN_CFLAGS",
        "CCC_OVERRIDE_OPTIONS",
        "CLANG_CONFIG_FILE_SYSTEM_DIR",
        "CLANG_CONFIG_FILE_USER_DIR",
    )
    if any(os.environ.get(name) for name in overrides):
        return None
    probe = """import json, sys
sys.path.insert(0, sys.argv[1])
from tools import config, shared
print(json.dumps({'clang': shared.CLANG_CC, 'config': config.EM_CONFIG,
                  'wrapper': config.COMPILER_WRAPPER}))
"""
    config = json.loads(subprocess.check_output([sys.executable, "-c", probe, str(driver)], text=True))
    if config["wrapper"]:
        return None
    clang = Path(config["clang"]).resolve()
    # Clang's optional default configuration can include arbitrary files.
    if list(clang.parent.glob("*.cfg")) or list((Path.home() / ".config/clang").glob("*.cfg")):
        return None
    files = {
        Path(executable).resolve(),
        clang,
        Path(config["config"]),
        *driver.glob("*.py"),
        *driver.glob("tools/**/*.py"),
    }
    # Official SDKs use a standalone clang. Also fingerprint shared LLVM builds.
    for pattern in ("libLLVM*", "libclang*"):
        files.update(path for path in (clang.parent.parent / "lib").glob(pattern) if path.is_file())
    return {
        "files": {str(path): digest(path) for path in sorted(files)},
        "environment": {
            key: value
            for key, value in sorted(os.environ.items())
            if key.startswith(("EM", "LLVM", "CLANG")) or key in ("SOURCE_DATE_EPOCH", "PATH")
        },
        "platform": platform.platform(),
        "python": sys.version,
    }


class ModuleCache:
    def __init__(self, directory, context):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.context = context

    def entry(self, module, bitcode_hash):
        key = {"context": self.context, "module": module, "bitcodeSha256": bitcode_hash}
        hashed = hashlib.sha256(json.dumps(key, sort_keys=True).encode()).hexdigest()
        return self.directory / hashed, key

    def restore(self, module, bitcode_hash, output):
        entry, key = self.entry(module, bitcode_hash)
        try:
            data = json.loads((entry / "cache.json").read_text())
            expected = {module.replace(".bc", ".o"), module + ".log"}
            if data["record"]["intrinsicUpgrades"]:
                expected.add(module + ".ll")
            if data["key"] != key or set(data["files"]) != expected:
                return None
            payloads = {name: (entry / name).read_bytes() for name in expected}
            if any(hashlib.sha256(value).hexdigest() != data["files"][name] for name, value in payloads.items()):
                return None
            if (
                data["record"]["bitcodeSha256"] != bitcode_hash
                or data["record"]["module"] != module
                or data["record"]["objectSha256"] != data["files"][module.replace(".bc", ".o")]
            ):
                return None
            compile_hash = data["files"].get(module + ".ll", bitcode_hash)
            if data["record"]["compileInputSha256"] != compile_hash:
                return None
            for name, contents in payloads.items():
                (output / name).write_bytes(contents)
            os.utime(entry, None)
            return data["record"]
        except (OSError, ValueError, KeyError, TypeError):
            return None

    def store(self, record, output):
        module = record["module"]
        entry, key = self.entry(module, record["bitcodeSha256"])
        files = [module.replace(".bc", ".o"), module + ".log"]
        if record["intrinsicUpgrades"]:
            files.append(module + ".ll")
        # Publish a complete directory atomically. Never overwrite a concurrent
        # writer; invalid existing entries remain misses until pruned.
        with tempfile.TemporaryDirectory(prefix=".writing-", dir=self.directory) as temporary:
            staging = Path(temporary) / "entry"
            staging.mkdir()
            for name in files:
                shutil.copy2(output / name, staging / name)
            (staging / "cache.json").write_text(
                json.dumps(
                    {"key": key, "record": record, "files": {name: digest(staging / name) for name in files}},
                    sort_keys=True,
                )
            )
            try:
                staging.rename(entry)
            except OSError:
                if not entry.is_dir():
                    raise

    def prune(self, maximum_bytes=8 * 1024**3):
        entries = []
        for entry in self.directory.iterdir():
            if len(entry.name) != 64 or not entry.is_dir():
                continue
            try:
                entries.append((
                    entry.stat().st_mtime_ns,
                    entry,
                    sum(path.stat().st_size for path in entry.iterdir() if path.is_file()),
                ))
            except FileNotFoundError:
                pass
        size = sum(item[2] for item in entries)
        for _, entry, length in sorted(entries):
            if size <= maximum_bytes:
                break
            shutil.rmtree(entry, ignore_errors=True)
            size -= length
