import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("pgo_cache", Path(__file__).with_name("pgo-cache.py"))
assert spec is not None and spec.loader is not None
cache_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache_module)


class CacheBoundaries(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.output = self.root / "output"
        self.output.mkdir()
        self.context = {"mode": "use", "profileSha256": "profile-one", "compiler": "clang-one"}
        self.cache = cache_module.ModuleCache(self.root / "cache", self.context)
        self.module = "Game.dll.bc"
        (self.output / "Game.dll.o").write_bytes(b"compiled object")
        (self.output / "Game.dll.bc.log").write_text("compiler diagnostics")
        self.record = {
            "module": self.module,
            "bitcodeSha256": "bitcode-one",
            "compileInputSha256": "bitcode-one",
            "intrinsicUpgrades": {},
            "objectSha256": cache_module.digest(self.output / "Game.dll.o"),
        }
        self.cache.store(self.record, self.output)
        self.restored = self.root / "restored"
        self.restored.mkdir()

    def test_only_matching_module_profile_and_compiler_can_restore(self):
        self.assertEqual(self.cache.restore(self.module, "bitcode-one", self.restored), self.record)
        self.assertEqual((self.restored / "Game.dll.o").read_bytes(), b"compiled object")
        self.assertIsNone(self.cache.restore(self.module, "changed-bitcode", self.restored))
        self.assertIsNone(self.cache.restore("Other.dll.bc", "bitcode-one", self.restored))
        for name in self.context:
            changed = cache_module.ModuleCache(self.root / "cache", {**self.context, name: "changed"})
            self.assertIsNone(changed.restore(self.module, "bitcode-one", self.restored))

    def test_corrupt_or_incomplete_cache_is_a_miss_without_partial_restore(self):
        entry, _ = self.cache.entry(self.module, "bitcode-one")
        (entry / "Game.dll.o").write_bytes(b"corrupt")
        self.assertIsNone(self.cache.restore(self.module, "bitcode-one", self.restored))
        self.assertEqual(list(self.restored.iterdir()), [])
        (entry / "Game.dll.o").unlink()
        self.assertIsNone(self.cache.restore(self.module, "bitcode-one", self.restored))
        (entry / "cache.json").write_text("truncated {")
        self.assertIsNone(self.cache.restore(self.module, "bitcode-one", self.restored))

    def test_translated_ir_and_diagnostics_are_retained_and_validated(self):
        (self.output / "Game.dll.bc.ll").write_text("translated IR")
        record = {
            **self.record,
            "bitcodeSha256": "older-intrinsics",
            "intrinsicUpgrades": {"llvm.wasm.old": 1},
            "compileInputSha256": cache_module.digest(self.output / "Game.dll.bc.ll"),
        }
        self.cache.store(record, self.output)
        self.assertEqual(self.cache.restore(self.module, "older-intrinsics", self.restored), record)
        self.assertEqual((self.restored / "Game.dll.bc.ll").read_text(), "translated IR")
        entry, _ = self.cache.entry(self.module, "older-intrinsics")
        (entry / "Game.dll.bc.ll").write_text("changed")
        self.assertIsNone(self.cache.restore(self.module, "older-intrinsics", self.restored))

    def test_pruning_removes_entries_without_touching_other_directories(self):
        writing = self.cache.directory / ".writing-in-progress"
        writing.mkdir()
        self.cache.prune(maximum_bytes=0)
        self.assertTrue(writing.is_dir())
        self.assertIsNone(self.cache.restore(self.module, "bitcode-one", self.restored))


if __name__ == "__main__":
    unittest.main()
