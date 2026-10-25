"""Synthetic helper bundles only. No app build, signing, registration or launch."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools/runtime-helper/embed-runtime-helper.sh"


class RuntimeEmbeddingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="nollie-embedding-")
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.products, self.parent, self.source = root / "products", root / "parent", root / "source"
        self.parent.mkdir()
        self.helper = self.products / "Nollie Runtime.app"
        self.destination = self.parent / "Nollie.app/Contents/Helpers/Nollie Runtime.app"
        self.agent = self.parent / "Nollie.app/Contents/Library/LaunchAgents/com.coreykozarski.nollie.runtime.plist"
        self.entry = Path("Contents/Resources/runtime_entry.py")
        self.addons = Path("Contents/Resources/managed_addons.py")
        for relative, data in ((self.entry, b"current-entry"),
                               (self.addons, b"current-addons"),
                               (Path("Contents/MacOS/Nollie Runtime"), b"current-executable"),
                               (Path("Contents/Info.plist"), b"fixture-info"),
                               (Path("Contents/_CodeSignature/CodeResources"), b"fixture-seal")):
            file = self.helper / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(data)
        (self.source / "Services/Runtime").mkdir(parents=True)
        (self.source / "Services/Runtime/runtime_entry.py").write_bytes(b"current-entry")
        (self.source / "Services/Runtime/managed_addons.py").write_bytes(b"current-addons")
        (self.source / "Services/Runtime/com.coreykozarski.nollie.runtime.plist.template").write_bytes(b"fixture-agent")

    def run_phase(self, configuration="DirectDebug", contents="Nollie.app/Contents", extra=None):
        environment = {"PATH": "/usr/bin:/bin", "CONFIGURATION": configuration,
                       "BUILT_PRODUCTS_DIR": str(self.products), "TARGET_BUILD_DIR": str(self.parent),
                       "CONTENTS_FOLDER_PATH": contents, "SRCROOT": str(self.source), **(extra or {})}
        return subprocess.run(["/bin/sh", str(SCRIPT)], env=environment, capture_output=True, text=True)

    def test_incremental_copy_replaces_stale_entry_even_with_unchanged_signature_seal(self):
        self.assertEqual(self.run_phase().returncode, 0)
        original_seal = (self.helper / "Contents/_CodeSignature/CodeResources").read_bytes()
        (self.helper / self.entry).write_bytes(b"new-entry")
        (self.source / "Services/Runtime/runtime_entry.py").write_bytes(b"new-entry")
        (self.helper / "Contents/MacOS/Nollie Runtime").write_bytes(b"new-executable")
        self.assertEqual(self.run_phase().returncode, 0)
        self.assertEqual((self.destination / self.entry).read_bytes(), b"new-entry")
        self.assertEqual((self.destination / "Contents/MacOS/Nollie Runtime").read_bytes(), b"new-executable")
        self.assertEqual((self.destination / "Contents/_CodeSignature/CodeResources").read_bytes(), original_seal)
        self.assertEqual(self.agent.read_bytes(), b"fixture-agent")

    def test_stale_built_resource_fails_before_replacing_embedded_helper(self):
        self.assertEqual(self.run_phase().returncode, 0)
        (self.source / "Services/Runtime/runtime_entry.py").write_bytes(b"new-source")
        self.assertNotEqual(self.run_phase().returncode, 0)
        self.assertEqual((self.destination / self.entry).read_bytes(), b"current-entry")

    def test_stale_addon_helper_fails_before_replacing_embedded_helper(self):
        self.assertEqual(self.run_phase().returncode, 0)
        (self.source / "Services/Runtime/managed_addons.py").write_bytes(b"new-addons")
        self.assertNotEqual(self.run_phase().returncode, 0)
        self.assertEqual((self.destination / self.addons).read_bytes(), b"current-addons")

    def test_missing_addon_helper_fails_closed(self):
        (self.helper / self.addons).unlink()
        self.assertNotEqual(self.run_phase().returncode, 0)
        self.assertFalse(self.destination.exists())

    def archive_layout(self, link_into_uninstalled=True):
        """Archives leave a link in the products folder to Xcode's uninstalled products."""
        uninstalled = Path(self.temporary.name) / "objroot/UninstalledProducts"
        target_root = uninstalled / "macosx" if link_into_uninstalled else Path(self.temporary.name) / "elsewhere"
        target_root.mkdir(parents=True)
        built = target_root / "Nollie Runtime.app"
        self.helper.rename(built)
        self.helper.symlink_to(built, target_is_directory=True)
        return {"UNINSTALLED_PRODUCTS_DIR": str(uninstalled), "PLATFORM_NAME": "macosx"}

    def test_archive_link_to_uninstalled_products_is_followed(self):
        result = self.run_phase("DirectRelease", extra=self.archive_layout())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / self.entry).read_bytes(), b"current-entry")
        self.assertFalse(self.destination.is_symlink())

    def test_link_anywhere_else_fails_closed(self):
        self.assertNotEqual(self.run_phase("DirectRelease", extra=self.archive_layout(False)).returncode, 0)
        self.assertFalse(self.destination.exists())

    def test_missing_signature_seal_fails_closed(self):
        (self.helper / "Contents/_CodeSignature/CodeResources").unlink()
        self.assertNotEqual(self.run_phase().returncode, 0)
        self.assertFalse(self.destination.exists())

    def test_linked_destination_ancestor_cannot_modify_an_outside_bundle(self):
        outside = self.parent.parent / "outside"
        protected = outside / "Nollie Runtime.app/sentinel"
        protected.parent.mkdir(parents=True)
        protected.write_bytes(b"keep")
        self.destination.parent.parent.mkdir(parents=True)
        self.destination.parent.symlink_to(outside, target_is_directory=True)
        self.assertNotEqual(self.run_phase().returncode, 0)
        self.assertEqual(protected.read_bytes(), b"keep")

    def test_linked_launch_agent_leaf_does_not_overwrite_its_target(self):
        outside = self.parent.parent / "outside.plist"
        outside.write_bytes(b"keep")
        self.agent.parent.mkdir(parents=True)
        self.agent.symlink_to(outside)
        self.assertNotEqual(self.run_phase().returncode, 0)
        self.assertEqual(outside.read_bytes(), b"keep")

    def test_alias_of_trusted_build_root_is_supported(self):
        actual = self.parent
        alias = self.parent.parent / "parent-alias"
        alias.symlink_to(actual, target_is_directory=True)
        self.parent = alias
        self.assertEqual(self.run_phase().returncode, 0)
        self.assertEqual((self.destination / self.entry).read_bytes(), b"current-entry")

    def test_destination_inside_source_is_rejected_before_mutation(self):
        self.parent = self.products
        self.assertNotEqual(self.run_phase(contents="Nollie Runtime.app/Contents").returncode, 0)
        self.assertEqual((self.helper / self.entry).read_bytes(), b"current-entry")
        self.assertFalse((self.helper / "Contents/Library").exists())

    def test_store_never_embeds_and_rejects_leftover_direct_artifacts(self):
        self.assertEqual(self.run_phase("Release").returncode, 0)
        self.assertFalse(self.destination.exists())
        self.assertEqual(self.run_phase("DirectRelease").returncode, 0)
        self.assertNotEqual(self.run_phase("Release").returncode, 0)

    def test_xcode_embed_phase_is_not_skipped_by_incremental_dependency_analysis(self):
        project = (ROOT / "Nollie.xcodeproj/project.pbxproj").read_text()
        start = project.index("97B911FBB5F4B2415C1B0812 /* ShellScript */ = {")
        phase = project[start:project.index("\n\t\t};", start)]
        self.assertIn("alwaysOutOfDate = 1;", phase)
        self.assertIn("embed-runtime-helper.sh", phase)


if __name__ == "__main__":
    unittest.main()
