#!/usr/bin/env python3
"""Precompile failures must be explicit, isolated and leave the old table intact."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "drivers/webgpu"))
import wgsl_precompile as precompile


class PrecompileFailuresTest(unittest.TestCase):
    def test_batch_rejects_malformed_protocol_exit_and_timeout(self):
        for result in (
            subprocess.CompletedProcess([], 1, "{}", "failed"),
            subprocess.CompletedProcess([], 0, "invalid json", ""),
            subprocess.CompletedProcess([], 0, "[]", ""),
        ):
            with self.subTest(result=result), patch.object(precompile.subprocess, "run", return_value=result):
                with self.assertRaises(RuntimeError):
                    precompile.convert_spirv_batch([("shader", "/shader.spv")], "/cli")
        with patch.object(precompile.subprocess, "run", side_effect=subprocess.TimeoutExpired("cli", 300)):
            with self.assertRaisesRegex(RuntimeError, "process failed"):
                precompile.convert_spirv_batch([("shader", "/shader.spv")], "/cli")

    def test_batch_rejects_missing_non_string_and_empty_results(self):
        for stdout in ("{}", '{"/shader.spv": null}', '{"/shader.spv": 1}', '{"/shader.spv": ""}'):
            with (
                self.subTest(stdout=stdout),
                patch.object(precompile.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout, "")),
            ):
                self.assertIsNone(precompile.convert_spirv_batch([("shader", "/shader.spv")], "/cli")["shader"])

    def test_glsl_and_tint_failures_preserve_previous_table_and_clean_workspace(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "bin").mkdir()
            (root / "bin/tint_convert_cli").touch()
            (root / "test.glsl").touch()
            output = root / "out.h"
            output.write_text("previous complete table")
            stages = {"compute": ["source"]}
            registry = [("test.glsl", "", [("default", "", ["comp"])])]
            workspaces = []

            def convert(files, unused):
                workspaces.append(Path(files[0][1]).parent)
                self.assertTrue(Path(files[0][1]).is_file())
                return {}

            with (
                patch.object(precompile.cache_identity, "fingerprint", return_value="identity"),
                patch.object(precompile.subprocess, "check_output", return_value="identity"),
                patch.object(precompile, "SHADER_REGISTRY", registry),
                patch.object(precompile, "parse_glsl_file", return_value=stages),
                patch.object(precompile, "convert_spirv_batch", side_effect=convert),
            ):
                for failure in (True, False, False):
                    with patch.object(
                        precompile,
                        "compile_glsl_to_spirv",
                        return_value=(None, "compile failure") if failure else (b"spirv", None),
                    ):
                        with self.assertRaisesRegex(RuntimeError, "Unexpected shader precompilation failures"):
                            precompile.precompile_wgsl(str(root), str(output))
                    self.assertEqual(output.read_text(), "previous complete table")
            self.assertEqual(len(workspaces), 2)
            self.assertNotEqual(workspaces[0], workspaces[1])
            self.assertTrue(all(not path.exists() for path in workspaces))


if __name__ == "__main__":
    unittest.main()
