#!/usr/bin/env python3
"""Content identity and stale-tool regression tests; no GPU or engine build."""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "drivers/webgpu"))
import cache_identity
import wgsl_precompile


class CacheIdentityTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in cache_identity.LOCAL_INPUTS:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
        for name in (
            "thirdparty/tint/reader.h",
            "thirdparty/spirv-tools/optimizer.cpp",
            "thirdparty/spirv-headers/spirv.h",
        ):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)

    def test_each_translation_input_changes_identity(self):
        original = cache_identity.fingerprint(self.root)
        for name in (
            "drivers/webgpu/spirv_preprocess.cpp",
            "drivers/webgpu/tint_wrapper.cpp",
            "drivers/webgpu/rendering_device_driver_webgpu.cpp",
            "drivers/webgpu/target_profile.json",
            "thirdparty/tint/reader.h",
            "thirdparty/spirv-tools/optimizer.cpp",
        ):
            with self.subTest(name=name):
                path = self.root / name
                old = path.read_text()
                path.write_text(old + "changed")
                self.assertNotEqual(original, cache_identity.fingerprint(self.root))
                path.write_text(old)
                self.assertEqual(original, cache_identity.fingerprint(self.root))

    def test_precompiler_rejects_cli_with_stale_identity(self):
        cli = self.root / "bin/tint_convert_cli"
        cli.parent.mkdir()
        cli.write_text("#!/bin/sh\nprintf '%s\\n' stale-translator\n")
        cli.chmod(0o755)
        with self.assertRaisesRegex(RuntimeError, "identity differs"):
            wgsl_precompile.precompile_wgsl(str(self.root), str(self.root / "out.h"))
        self.assertFalse((self.root / "out.h").exists())

    def test_generated_header_does_not_change_its_own_identity(self):
        original = cache_identity.fingerprint(self.root)
        header = self.root / "drivers/webgpu/generated/wgsl_cache_identity.gen.h"
        cache_identity.write_header(self.root, header)
        modified = header.stat().st_mtime_ns
        self.assertIn(original, header.read_text())
        self.assertEqual(original, cache_identity.fingerprint(self.root))
        cache_identity.write_header(self.root, header)
        self.assertEqual(modified, header.stat().st_mtime_ns)

    def test_runtime_change_rebuilds_cli_without_rebuilding_vendor_components(self):
        directory = self.root / "stamps"
        cache_identity.write_build_stamps(self.root, directory)
        before = {path.name: path.read_text() for path in directory.iterdir()}
        path = self.root / "drivers/webgpu/rendering_device_driver_webgpu.cpp"
        path.write_text(path.read_text() + " changed")
        cache_identity.write_build_stamps(self.root, directory)
        after = {path.name: path.read_text() for path in directory.iterdir()}
        self.assertNotEqual(before["cli.inputs"], after["cli.inputs"])
        self.assertEqual(before["tint.inputs"], after["tint.inputs"])
        self.assertEqual(before["spirv_tools.inputs"], after["spirv_tools.inputs"])

    def test_vendored_header_changes_rebuild_components(self):
        directory = self.root / "stamps"
        cache_identity.write_build_stamps(self.root, directory)
        before = {path.name: path.read_text() for path in directory.iterdir()}
        path = self.root / "thirdparty/spirv-headers/spirv.h"
        path.write_text(path.read_text() + " changed")
        cache_identity.write_build_stamps(self.root, directory)
        for path in directory.iterdir():
            self.assertNotEqual(before[path.name], path.read_text())


if __name__ == "__main__":
    unittest.main()
