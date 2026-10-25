"""Offline checks for Tools/pins.json, the Hermes overlay and the Setup Kit. No network."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pinslib = load("pinslib", "pinslib.py")
check = load("check_latest", "check-latest.py")
kit = load("setup_kit", "setup-kit.py")
overlay = load("hermes_overlay", "hermes-overlay.py")
HERMES = Path(os.environ.get("NOLLIE_HERMES_SOURCE", pinslib.ROOT.parent / "hermes-v0.22.2"))


class PinsTests(unittest.TestCase):
    def test_every_place_agrees_with_pins_json(self):
        self.assertEqual(check.local_problems(), [])

    def test_every_download_is_pinned_by_checksum_from_an_allowed_host(self):
        for item in pinslib.load()["components"]:
            artifact = item.get("artifact")
            if not artifact:
                continue
            with self.subTest(item["id"]):
                self.assertRegex(artifact["sha256"], r"^[0-9a-f]{64}$")
                self.assertTrue(artifact["url"].startswith("https://"))
                self.assertIn(pinslib.urllib.parse.urlsplit(artifact["url"]).hostname, pinslib.HOSTS)
                self.assertNotIn("latest", artifact["url"])

    def test_a_drifted_swift_pin_is_reported(self):
        pins = json.loads(pinslib.PINS.read_text())
        pinslib.component(pins, "uv")["version"] = "0.0.1"
        problems = check.local_problems(pins)
        self.assertTrue(any("uv artifact" in problem for problem in problems))

    def test_fetch_refuses_hosts_outside_the_list(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):
                pinslib.fetch({"url": "https://example.com/x.tar.gz", "sha256": "0" * 64}, Path(folder) / "x")

    def test_fetch_keeps_nothing_that_fails_its_checksum(self):
        class Response(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *args):
                self.close()

        class Opener:
            def open(self, url, timeout):
                return Response(b"not the pinned bytes")

        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / "uv.tar.gz"
            artifact = {"url": "https://github.com/astral-sh/uv/x.tar.gz", "sha256": "0" * 64, "bytes": 20}
            with self.assertRaises(ValueError):
                pinslib.fetch(artifact, target, opener=Opener())
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_safe_extract_refuses_links_and_escapes(self):
        for name, kind in (("top/../evil", tarfile.REGTYPE), ("/absolute", tarfile.REGTYPE), ("top/link", tarfile.SYMTYPE)):
            with self.subTest(name), tempfile.TemporaryDirectory() as folder:
                archive = Path(folder) / "a.tar.gz"
                with tarfile.open(archive, "w:gz") as tar:
                    info = tarfile.TarInfo(name)
                    info.type = kind
                    info.linkname = "/etc/passwd" if kind == tarfile.SYMTYPE else ""
                    tar.addfile(info, io.BytesIO(b"") if kind == tarfile.REGTYPE else None)
                with self.assertRaises(ValueError):
                    pinslib.safe_extract(archive, Path(folder) / "out")


class OverlayTests(unittest.TestCase):
    def test_overlay_lists_each_file_with_its_checksums(self):
        manifest = pinslib.overlay_manifest()
        self.assertEqual(manifest["schema"], 1)
        self.assertEqual(manifest["hermes"]["version"], pinslib.component(pinslib.load(), "hermes")["version"])
        files = {entry["path"] for entry in manifest["files"]}
        self.assertIn("cron/scheduler.py", files)
        self.assertFalse(any(path.startswith("hermes_cli/") for path in files))
        self.assertEqual(set(manifest["exceptions"]), set(manifest["patches"]))
        self.assertFalse(any(path.startswith("tests/") for path in files))
        for entry in manifest["files"]:
            data = (pinslib.OVERLAY / "files" / entry["path"]).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), entry["after"])
            self.assertEqual(len(data), entry["bytes"])
        self.assertTrue((pinslib.OVERLAY / "LICENSE-hermes-agent.txt").read_text().startswith("MIT License"))

    def test_local_pinned_source_rebuild_matches_without_writing_source(self):
        before = {name: (HERMES / name).read_bytes() for name in overlay.patch_paths() if (HERMES / name).exists()}
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / "overlay"
            overlay.build(destination, HERMES)
            self.assertTrue(overlay.same_tree(destination, pinslib.OVERLAY))
        self.assertEqual(before, {name: (HERMES / name).read_bytes() for name in before})

    def test_modified_source_is_refused_before_overlay_is_written(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "source"
            source.mkdir()
            # Read the real pinned Git objects without changing that checkout.
            git_dir = subprocess.run(["git", "-C", str(HERMES), "rev-parse", "--absolute-git-dir"],
                                     check=True, capture_output=True, text=True).stdout.strip()
            (source / ".git").write_text("gitdir: " + git_dir + "\n")
            for name in overlay.patch_paths() | {"LICENSE"}:
                original = HERMES / name
                if original.is_file():
                    target = source / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(original, target)
            scheduler = source / "cron/scheduler.py"
            scheduler.write_bytes(scheduler.read_bytes() + b"\n# changed fixture\n")
            destination = Path(folder) / "overlay"
            with self.assertRaisesRegex(ValueError, "Pinned Hermes source changed: cron/scheduler.py"):
                overlay.build(destination, source)
            self.assertFalse(destination.exists())


class SetupKitTests(unittest.TestCase):
    def test_kit_carries_the_managed_add_ons_and_no_tests(self):
        with tempfile.TemporaryDirectory() as folder:
            built = kit.build(Path(folder) / "Setup Kit")
            names = [item["name"] for item in built["items"]]
            self.assertEqual(names, ["nollie-workflow", "nollie-crew", "nollie-reader", "nollie-computer"])
            crew = next(item for item in built["items"] if item["name"] == "nollie-crew")
            self.assertIn("nollie-crew/workflow.py", [entry["path"] for entry in crew["files"]])
            for item in built["items"]:
                for entry in item["files"]:
                    self.assertTrue(entry["path"].startswith(item["name"] + "/"))
                    self.assertNotIn("/tests/", entry["path"])
                    self.assertNotIn("__pycache__", entry["path"])
                    data = (Path(folder) / "Setup Kit/add-ons" / entry["path"]).read_bytes()
                    self.assertEqual(hashlib.sha256(data).hexdigest(), entry["sha256"])
            self.assertTrue((Path(folder) / "Setup Kit/hermes-overlay/overlay.json").is_file())
            self.assertEqual(built["readerLock"]["path"], "nollie-reader/requirements.txt")
            workflow = next(item for item in built["items"] if item["name"] == "nollie-workflow")
            carried = {item["path"] for item in workflow["files"]}
            self.assertIn("nollie-workflow/hermes_support/nollie_board_observer.py", carried)
            self.assertIn("nollie-workflow/hermes_support/ollie_cron_followups.py", carried)

    def test_add_ons_left_out_of_a_managed_setup_say_why(self):
        for item in json.loads(pinslib.PINS.read_text())["addons"]["items"]:
            self.assertTrue(item["why"])
        self.assertNotIn("nollie-mac", kit.managed_names())
        self.assertNotIn("nollie-pairing", kit.managed_names())


if __name__ == "__main__":
    unittest.main()
