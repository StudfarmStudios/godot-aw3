#!/usr/bin/env python3
"""Execute the actual CLI build helpers with controlled compiler failures."""

import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path


class CliBuildTest(unittest.TestCase):
    def test_later_background_failure_cannot_link_stale_object(self):
        source = (Path(__file__).resolve().parents[2] / "drivers/webgpu/tint_cli/build.sh").read_text()
        helpers = source[source.index("compile_one() {") : source.index("# 1. Compile SPIRV-Tools")]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / "build"
            (build / "cli").mkdir(parents=True)
            bad_object = build / "cli/bad.o"
            bad_object.write_text("old valid object")
            os.utime(bad_object, (1, 1))
            (build / "cli.inputs").write_text("new inputs")
            for name in ("good.cpp", "bad.cpp"):
                (root / name).write_text(name)
            compiler = root / "compiler.py"
            compiler.write_text(
                "#!/usr/bin/env python3\nimport pathlib, sys, time\n"
                "args = sys.argv[1:]\noutput = pathlib.Path(args[args.index('-o') + 1])\n"
                "output.write_text('partial output')\ntime.sleep(0.03)\n"
                "if args[args.index('-c') + 1].endswith('bad.cpp'): sys.exit(7)\n"
                "output.write_text('compiled object')\n"
            )
            compiler.chmod(0o755)
            script = f"set -euo pipefail\nBUILD_DIR={shlex.quote(str(build))}\nCXX={shlex.quote(str(compiler))}\nCOMMON_FLAGS=''\nJOBS=2\n"
            script += helpers
            script += (
                f"start_compile {shlex.quote(str(root / 'good.cpp'))} {shlex.quote(str(build / 'cli/good.o'))} c++17\n"
            )
            script += f"start_compile {shlex.quote(str(root / 'bad.cpp'))} {shlex.quote(str(bad_object))} c++17\n"
            script += f"wait_compiles\ntouch {shlex.quote(str(root / 'linked'))}\n"
            process = subprocess.run(["/bin/bash", "-c", script], text=True, capture_output=True)
            self.assertNotEqual(process.returncode, 0, process.stdout + process.stderr)
            self.assertFalse((root / "linked").exists())
            self.assertEqual(bad_object.read_text(), "old valid object")
            self.assertEqual((build / "cli/good.o").read_text(), "compiled object")
            self.assertFalse(list(build.rglob("*.tmp.*")))

    def test_empty_wait_succeeds_with_bash_nounset(self):
        source = (Path(__file__).resolve().parents[2] / "drivers/webgpu/tint_cli/build.sh").read_text()
        helpers = source[source.index("compile_one() {") : source.index("# 1. Compile SPIRV-Tools")]
        process = subprocess.run(
            ["/bin/bash", "-c", "set -euo pipefail\n" + helpers + "\nwait_compiles\n"], capture_output=True, text=True
        )
        self.assertEqual(process.returncode, 0, process.stderr)


if __name__ == "__main__":
    unittest.main()
