import importlib.util
import io
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


vendor = load("vendor-crates")
notices = load("third-party-notices")


class PinTests(unittest.TestCase):
    def test_pin_names_one_checked_release(self):
        pin = dict(re.findall(r"^([A-Z0-9_]+)=(\S+)$", (HERE / "pin.env").read_text(), re.M))
        self.assertEqual(pin["DRIVER_TAG"], f"cua-driver-rs-v{pin['DRIVER_VERSION']}")
        self.assertTrue(pin["DRIVER_VERSION"].startswith("0.36."))
        for key in ("DRIVER_COMMIT", "DRIVER_TREE", "TELEMETRY_TREE"):
            self.assertRegex(pin[key], r"^[0-9a-f]{40}$")
        for key in ("DRIVER_LOCK_SHA256", "RUST_SHA256"):
            self.assertRegex(pin[key], r"^[0-9a-f]{64}$")
        self.assertTrue(pin["RUST_URL"].startswith("https://static.rust-lang.org/"))


class VendorTests(unittest.TestCase):
    def test_reads_only_registry_packages(self):
        lock = '''
[[package]]
name = "serde"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "abc"

[[package]]
name = "cua-driver"
version = "0.36.0"
'''
        self.assertEqual(vendor.registry_packages(lock), [{"name": "serde", "version": "1.0.0",
                                                           "source": "registry+https://github.com/rust-lang/crates.io-index",
                                                           "checksum": "abc"}])

    def test_refuses_archives_that_escape_or_link(self):
        for name, kind in (("../evil", tarfile.REGTYPE), ("/abs", tarfile.REGTYPE), ("ok/link", tarfile.SYMTYPE)):
            with tempfile.TemporaryDirectory() as folder:
                path = os.path.join(folder, "c.crate")
                with tarfile.open(path, "w:gz") as archive:
                    member = tarfile.TarInfo(name)
                    member.type = kind
                    archive.addfile(member, io.BytesIO(b""))
                with tarfile.open(path) as archive, self.assertRaises(ValueError):
                    vendor.safe_members(archive)

    def test_a_crate_with_the_wrong_checksum_is_never_unpacked(self):
        with tempfile.TemporaryDirectory() as out, tempfile.TemporaryDirectory() as seed:
            Path(seed, "x-1.0.0.crate").write_bytes(b"not the crate")
            os.makedirs(os.path.join(out, ".download"))
            def download(command, **_):
                Path(command[command.index("-o") + 1]).write_bytes(b"a tampered download")
                return subprocess.CompletedProcess(command, 0)
            with patch.object(vendor.subprocess, "run", side_effect=download):
                problem = vendor.vendor({"name": "x", "version": "1.0.0", "checksum": "0" * 64}, out, seed)
            self.assertIn("checksum mismatch", problem)
            self.assertFalse(os.path.exists(os.path.join(out, "x-1.0.0")))
            self.assertFalse(os.path.exists(os.path.join(out, ".download", "x-1.0.0.crate")))
            with patch.object(vendor.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
                problem = vendor.vendor({"name": "x", "version": "1.0.0", "checksum": "0" * 64}, out, None)
            self.assertIn("download failed", problem)


class NoticeTests(unittest.TestCase):
    def crate(self, root, name, version, licence):
        folder = Path(root, f"{name}-{version}")
        folder.mkdir()
        (folder / "Cargo.toml").write_text(f'[package]\nname = "{name}"\nlicense = "{licence}"\n')
        (folder / "LICENSE").write_text(f"{licence} text for {name}")

    def run_notices(self, crates):
        with tempfile.TemporaryDirectory() as vendor_dir, tempfile.TemporaryDirectory() as out:
            for name, version, licence in crates:
                self.crate(vendor_dir, name, version, licence)
            listing = Path(out, "crates.txt")
            listing.write_text("".join(f"{n} v{v}\n" for n, v, _ in crates))
            with patch("sys.stdout", io.StringIO()), patch("sys.stderr", io.StringIO()):
                code = notices.main(str(listing), vendor_dir, os.path.join(out, "none"), out)
            return code, Path(out, "THIRD_PARTY_NOTICES.txt").read_text()

    def test_permissive_and_unmodified_uniffi_pass(self):
        code, text = self.run_notices([("serde", "1.0.0", "MIT OR Apache-2.0"), ("uniffi", "0.31.0", "MPL-2.0")])
        self.assertEqual(code, 0)
        self.assertIn("MPL-2.0 text for uniffi", text)

    def test_copyleft_or_unknown_stops_the_build(self):
        self.assertEqual(self.run_notices([("evil", "1.0.0", "GPL-3.0")])[0], 1)
        self.assertEqual(self.run_notices([("other", "1.0.0", "MPL-2.0")])[0], 1)


class EmbedTests(unittest.TestCase):
    def run_embed(self, configuration, with_helper):
        with tempfile.TemporaryDirectory() as build:
            contents = Path(build, "Nollie.app/Contents")
            (contents / "Helpers").mkdir(parents=True)
            if with_helper:
                (contents / "Helpers/Nollie Computer").write_text("x")
            env = {"PATH": "/usr/bin:/bin", "CONFIGURATION": configuration, "TARGET_BUILD_DIR": build,
                   "CONTENTS_FOLDER_PATH": "Nollie.app/Contents", "SRCROOT": str(ROOT),
                   "NOLLIE_COMPUTER_CACHE": os.path.join(build, "no-cache")}
            return subprocess.run(["/bin/sh", str(HERE / "embed-computer-helper.sh")], env=env,
                                  capture_output=True, text=True)

    def test_the_client_edition_never_carries_the_helper(self):
        self.assertEqual(self.run_embed("Release", with_helper=False).returncode, 0)
        refused = self.run_embed("Debug", with_helper=True)
        self.assertEqual(refused.returncode, 1)
        self.assertIn("client edition", refused.stderr)

    def test_a_release_build_needs_the_pinned_helper(self):
        self.assertEqual(self.run_embed("DirectRelease", with_helper=False).returncode, 1)
        warned = self.run_embed("DirectDebug", with_helper=True)
        self.assertEqual(warned.returncode, 0)
        self.assertIn("can't use the Mac", warned.stdout)


if __name__ == "__main__":
    unittest.main()
