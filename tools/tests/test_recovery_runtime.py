"""Regression tests for stock-init/PBRP library separation; no Android build."""

import importlib.util
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[2] / "device/xiaomi/rodin/tools"
sys.path.insert(0, str(TOOLS))


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, TOOLS / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


isolate = load("isolate", "isolate-recovery-runtime.py")
validate = load("validate", "validate-recovery-runtime.py")


class StagingTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name) / "root"
        self.libs = self.root / "system/lib64"
        self.libs.mkdir(parents=True)
        for name in isolate.REQUIRED_LIBRARIES:
            (self.libs / name).write_bytes(b"PBRP-" + name.encode())
        binaries = self.root / "system/bin"
        binaries.mkdir()
        for name in ("recovery", "adbd", "fastbootd", "init"):
            (binaries / name).write_bytes(name.encode())
        (self.root / "init.recovery.hardware.rc").write_text("# Existing recovery hook\n")

    def test_private_libraries_match_originals_without_recursive_copy(self):
        private = isolate.prepare(self.root)
        for name in isolate.REQUIRED_LIBRARIES:
            self.assertEqual((private / name).read_bytes(), (self.libs / name).read_bytes())
        self.assertFalse((private / "pbrp").exists())
        self.assertEqual((self.root / "system/bin/init").read_bytes(), b"init")

    def test_library_environment_is_per_service_not_global(self):
        isolate.prepare(self.root)
        runtime = (self.root / "init.recovery.pbrp-runtime.rc").read_text()
        self.assertEqual(runtime.count("    override\n"), 3)
        self.assertEqual(runtime.count("    setenv LD_LIBRARY_PATH " + isolate.LIBRARY_PATH), 3)
        self.assertNotIn("export LD_LIBRARY_PATH", runtime)
        self.assertNotIn("service init ", runtime)
        self.assertNotIn("service ueventd ", runtime)
        hardware = (self.root / "init.recovery.hardware.rc").read_text()
        self.assertIn("# Existing recovery hook", hardware)
        self.assertEqual(hardware.count(isolate.IMPORT), 1)

    def test_missing_trimmed_dependency_fails_before_staging(self):
        (self.libs / "libprotobuf-cpp-lite.so").unlink()
        with self.assertRaisesRegex(ValueError, "libprotobuf-cpp-lite"):
            isolate.prepare(self.root)
        self.assertFalse((self.libs / "pbrp").exists())

    def test_second_staging_is_rejected(self):
        isolate.prepare(self.root)
        with self.assertRaisesRegex(ValueError, "already exists"):
            isolate.prepare(self.root)

    def test_absolute_library_symlink_targets_private_runtime(self):
        (self.libs / "alias.so").symlink_to("/system/lib64/libfs_mgr.so")
        private = isolate.prepare(self.root)
        self.assertEqual((private / "alias.so").readlink().as_posix(),
                         "/system/lib64/pbrp/libfs_mgr.so")
        self.assertEqual((self.libs / "alias.so").readlink().as_posix(),
                         "/system/lib64/libfs_mgr.so")


class DependencyTests(unittest.TestCase):
    def setUp(self):
        self.mode = stat.S_IFREG | 0o755
        self.blobs = {
            b"\x7fELF-init": (["libfs_mgr.so"], set(), {"fs_mgr_mount_15"}),
            b"\x7fELF-recovery": (["libfs_mgr.so", "libcutils.so"], set(),
                                  {"fs_mgr_mount_14", "android_memset16"}),
            b"\x7fELF-fs15": ([], {"fs_mgr_mount_15"}, set()),
            b"\x7fELF-fs14": ([], {"fs_mgr_mount_14"}, set()),
            b"\x7fELF-cu15": ([], set(), set()),
            b"\x7fELF-cu14": ([], {"android_memset16"}, set()),
        }
        self.files = {
            path: (self.mode, blob) for path, blob in (
                ("system/bin/init", b"\x7fELF-init"),
                ("system/bin/recovery", b"\x7fELF-recovery"),
                ("system/lib64/libfs_mgr.so", b"\x7fELF-fs15"),
                ("system/lib64/libcutils.so", b"\x7fELF-cu15"),
                ("system/lib64/pbrp/libfs_mgr.so", b"\x7fELF-fs14"),
                ("system/lib64/pbrp/libcutils.so", b"\x7fELF-cu14"),
            )
        }

    def parse(self, data):
        return self.blobs[data]

    def test_mixed_library_clean_is_rejected(self):
        missing, unresolved = validate.check_closure(
            self.files, "system/bin/recovery", ("system/lib64",), self.parse)
        self.assertFalse(missing)
        self.assertEqual(unresolved["system/bin/recovery"],
                         ["android_memset16", "fs_mgr_mount_14"])

    def test_private_runtime_resolves_recovery_without_changing_init(self):
        for entry, search in (
            ("system/bin/init", ("system/lib64",)),
            ("system/bin/recovery", ("system/lib64/pbrp", "system/lib64")),
        ):
            self.assertEqual(validate.check_closure(self.files, entry, search, self.parse),
                             (set(), {}))

    def test_missing_library_is_reported(self):
        del self.files["system/lib64/libfs_mgr.so"]
        missing, _ = validate.check_closure(self.files, "system/bin/init",
                                          ("system/lib64",), self.parse)
        self.assertEqual(missing, {"libfs_mgr.so"})

    def test_readelf_ifunc_exports_and_weak_imports(self):
        dynamic = "0x1 (NEEDED) Shared library: [libc.so]\n"
        symbols = (
            "1059: 00000000000d3090 72 <OS specific>: 10 GLOBAL DEFAULT 15 memcpy@@LIBC\n"
            "1060: 0000000000000000 0 FUNC GLOBAL DEFAULT UND required@LIBC (2)\n"
            "1061: 0000000000000000 0 FUNC WEAK DEFAULT UND optional\n"
        )
        with patch.object(validate.subprocess, "check_output", side_effect=[dynamic, symbols]):
            needed, exports, imports = validate.elf_symbols(b"test")
        self.assertEqual(needed, ["libc.so"])
        self.assertEqual(exports, {"memcpy"})
        self.assertEqual(imports, {"required"})


if __name__ == "__main__":
    unittest.main()
