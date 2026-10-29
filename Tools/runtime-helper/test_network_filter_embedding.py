"""Synthetic network filter bundles. No app build, no system extension is installed."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools/network-filter/embed-network-filter.sh"
NAME = "com.coreykozarski.nollie.network-filter.systemextension"
EXECUTABLE = "Contents/MacOS/com.coreykozarski.nollie.network-filter"


class NetworkFilterEmbeddingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="nollie-filter-embedding-")
        self.addCleanup(self.temporary.cleanup)
        root = Path(os.path.realpath(self.temporary.name))
        self.root = root
        self.products, self.parent = root / "products", root / "parent"
        self.parent.mkdir()
        self.filter = self.products / NAME
        self.destination = self.parent / "Nollie.app/Contents/Library/SystemExtensions" / NAME
        for relative, data in (("Contents/Info.plist", b"fixture-info"), (EXECUTABLE, b"fixture-executable")):
            file = self.filter / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(data)

    def environment(self, configuration="DirectRelease", ready="YES", **extra):
        return {"PATH": "/usr/bin:/bin", "CONFIGURATION": configuration, "SRCROOT": str(ROOT),
                "BUILT_PRODUCTS_DIR": str(self.products), "TARGET_BUILD_DIR": str(self.parent),
                "CONTENTS_FOLDER_PATH": "Nollie.app/Contents", "NOLLIE_NETWORK_FILTER_READY": ready,
                "CODE_SIGNING_ALLOWED": "NO", **extra}

    def run_phase(self, configuration="DirectRelease", ready="YES", prefix=(), **extra):
        return subprocess.run([*prefix, "/bin/sh", str(SCRIPT)], env=self.environment(configuration, ready, **extra),
                              capture_output=True, text=True)

    def sandboxed(self, configuration, readable):
        """Like Xcode's script sandbox: the products folder is out of reach unless the phase lists it."""
        rules = ["(version 1)", "(allow default)"]
        if not readable:
            rules.append(f'(deny file-read* (subpath "{self.products}"))')
        return self.run_phase(configuration, prefix=("/usr/bin/sandbox-exec", "-p", " ".join(rules)))

    def test_the_direct_edition_embeds_an_exact_copy(self):
        result = self.run_phase()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / EXECUTABLE).read_bytes(), b"fixture-executable")
        self.assertEqual((self.destination / "Contents/Info.plist").read_bytes(), b"fixture-info")

    def test_the_store_edition_never_reads_the_products_folder(self):
        if not Path("/usr/bin/sandbox-exec").exists():
            self.skipTest("sandbox-exec is not on this Mac")
        result = self.sandboxed("Release", readable=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.destination.exists())

    def test_the_direct_edition_still_needs_the_listed_products(self):
        if not Path("/usr/bin/sandbox-exec").exists():
            self.skipTest("sandbox-exec is not on this Mac")
        self.assertNotEqual(self.sandboxed("DirectRelease", readable=False).returncode, 0)
        self.assertFalse(self.destination.exists())
        self.assertEqual(self.sandboxed("DirectRelease", readable=True).returncode, 0)

    def test_the_store_edition_still_checks_its_own_path(self):
        self.destination.parent.parent.parent.mkdir(parents=True)
        outside = self.root / "outside"
        outside.mkdir()
        (self.parent / "Nollie.app/Contents/Library").symlink_to(outside, target_is_directory=True)
        self.assertNotEqual(self.run_phase("Release").returncode, 0)

    def test_the_store_edition_refuses_a_leftover_filter(self):
        self.assertEqual(self.run_phase().returncode, 0)
        self.assertNotEqual(self.run_phase("Release").returncode, 0)
        self.assertTrue(self.destination.exists())

    def test_not_ready_removes_the_filter_without_reading_the_products(self):
        self.assertEqual(self.run_phase().returncode, 0)
        shutil.rmtree(self.products)
        result = self.run_phase(ready="NO")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.destination.exists())

    def test_a_linked_product_outside_xcodes_folder_is_refused(self):
        elsewhere = self.root / "elsewhere" / NAME
        elsewhere.parent.mkdir()
        self.filter.rename(elsewhere)
        self.filter.symlink_to(elsewhere, target_is_directory=True)
        self.assertNotEqual(self.run_phase().returncode, 0)
        self.assertFalse(self.destination.exists())

    def test_an_archive_link_into_xcodes_uninstalled_products_is_followed(self):
        uninstalled = self.root / "uninstalled"
        (uninstalled / "macosx").mkdir(parents=True)
        self.filter.rename(uninstalled / "macosx" / NAME)
        self.filter.symlink_to(uninstalled / "macosx" / NAME, target_is_directory=True)
        result = self.run_phase(UNINSTALLED_PRODUCTS_DIR=str(uninstalled), PLATFORM_NAME="macosx")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / EXECUTABLE).read_bytes(), b"fixture-executable")

    def test_a_link_inside_the_built_filter_is_refused(self):
        executable = self.filter / EXECUTABLE
        real = self.root / "real-executable"
        executable.rename(real)
        executable.symlink_to(real)
        self.assertNotEqual(self.run_phase().returncode, 0)
        self.assertFalse(self.destination.exists())

    def test_overlapping_roots_are_refused(self):
        result = subprocess.run(["/bin/sh", str(SCRIPT)], env=self.environment(
            TARGET_BUILD_DIR=str(self.filter), CONTENTS_FOLDER_PATH="Contents"), capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)

    def test_xcode_lets_the_phase_read_the_built_filter(self):
        project = (ROOT / "Nollie.xcodeproj/project.pbxproj").read_text()
        start = project.index('name = "Embed Network Filter";')
        start = project.rindex("isa = PBXShellScriptBuildPhase;", 0, start)
        phase = project[start:project.index("\n\t\t};", start)]
        for path in ("Contents/Info.plist", EXECUTABLE):
            self.assertIn(f'"$(BUILT_PRODUCTS_DIR)/{NAME}/{path}"', phase)
        self.assertIn(f'"$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Library/SystemExtensions"', phase)


if __name__ == "__main__":
    unittest.main()
