"""Synthetic notification helper bundles. No app build or service changes."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools/runtime-helper/embed-notification-helper.sh"


class NotificationEmbeddingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="nollie-notification-embedding-")
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.products, self.parent = root / "products", root / "parent"
        self.parent.mkdir()
        self.helper = self.products / "Nollie Notifications.app"
        self.destination = self.parent / "Nollie.app/Contents/Library/LoginItems/Nollie Notifications.app"
        for relative, data in (("Contents/MacOS/Nollie Notifications", b"current-executable"),
                               ("Contents/Info.plist", b"fixture-info"),
                               ("Contents/_CodeSignature/CodeResources", b"fixture-seal"),
                               ("Contents/Resources/fixture", b"current-resource")):
            file = self.helper / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(data)

    def run_phase(self, configuration="DirectDebug"):
        environment = {"PATH": "/usr/bin:/bin", "CONFIGURATION": configuration,
                       "BUILT_PRODUCTS_DIR": str(self.products), "TARGET_BUILD_DIR": str(self.parent),
                       "CONTENTS_FOLDER_PATH": "Nollie.app/Contents"}
        return subprocess.run(["/bin/sh", str(SCRIPT)], env=environment, capture_output=True, text=True)

    def test_incremental_copy_replaces_changed_executable_and_resources_with_same_seal(self):
        self.assertEqual(self.run_phase().returncode, 0)
        executable = "Contents/MacOS/Nollie Notifications"
        resource = "Contents/Resources/fixture"
        (self.helper / executable).write_bytes(b"updated-executable")
        (self.helper / resource).write_bytes(b"updated-resource")
        self.assertEqual(self.run_phase().returncode, 0)
        self.assertEqual((self.destination / executable).read_bytes(), b"updated-executable")
        self.assertEqual((self.destination / resource).read_bytes(), b"updated-resource")
        self.assertEqual((self.destination / "Contents/_CodeSignature/CodeResources").read_bytes(), b"fixture-seal")

    def test_incomplete_helper_fails_before_replacing_the_embedded_copy(self):
        self.assertEqual(self.run_phase().returncode, 0)
        (self.helper / "Contents/_CodeSignature/CodeResources").unlink()
        self.assertNotEqual(self.run_phase().returncode, 0)
        self.assertEqual((self.destination / "Contents/_CodeSignature/CodeResources").read_bytes(), b"fixture-seal")

    def test_linked_login_items_cannot_modify_an_outside_bundle(self):
        outside = self.parent.parent / "outside"
        protected = outside / "Nollie Notifications.app/sentinel"
        protected.parent.mkdir(parents=True)
        protected.write_bytes(b"keep")
        self.destination.parent.parent.mkdir(parents=True)
        self.destination.parent.symlink_to(outside, target_is_directory=True)
        self.assertNotEqual(self.run_phase().returncode, 0)
        self.assertEqual(protected.read_bytes(), b"keep")

    def test_source_product_link_is_rejected_before_mutation(self):
        real = self.helper.with_name("Elsewhere.app")
        self.helper.rename(real)
        self.helper.symlink_to(real, target_is_directory=True)
        self.assertNotEqual(self.run_phase().returncode, 0)
        self.assertFalse(self.destination.exists())

    def test_traversal_outside_the_trusted_build_root_is_rejected(self):
        original = self.parent
        self.parent = self.products
        environment = {"PATH": "/usr/bin:/bin", "CONFIGURATION": "DirectDebug",
                       "BUILT_PRODUCTS_DIR": str(self.products), "TARGET_BUILD_DIR": str(self.parent),
                       "CONTENTS_FOLDER_PATH": "../escape.app/Contents"}
        result = subprocess.run(["/bin/sh", str(SCRIPT)], env=environment, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((original.parent / "escape.app").exists())

    def test_store_never_embeds_and_rejects_leftover_direct_helper(self):
        self.assertEqual(self.run_phase("Release").returncode, 0)
        self.assertFalse(self.destination.exists())
        self.assertEqual(self.run_phase("DirectRelease").returncode, 0)
        self.assertNotEqual(self.run_phase("Release").returncode, 0)

    def test_xcode_notification_phase_always_verifies_the_embedded_artifact(self):
        project = (ROOT / "Nollie.xcodeproj/project.pbxproj").read_text()
        start = project.index("F99D35F1DBDC2746BD36513E /* ShellScript */ = {")
        phase = project[start:project.index("\n\t\t};", start)]
        self.assertIn("alwaysOutOfDate = 1;", phase)
        self.assertIn("embed-notification-helper.sh", phase)


if __name__ == "__main__":
    unittest.main()
