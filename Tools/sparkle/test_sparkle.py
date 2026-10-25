"""Offline checks for the Direct Mac edition's updater: its settings, the release guard, and the promise
that the Mac App Store edition (scheme NollieMac) carries no Sparkle. No network, no keychain."""
import base64
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest

import sparkle_config as config

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PROJECT = (ROOT / "Nollie.xcodeproj/project.pbxproj").read_text()
GOOD_KEY = base64.b64encode(bytes(range(32))).decode()
MAC_TARGET_CONFIGS = "AA00000000000000000280"      # NollieMac: both editions, told apart by configuration
STORE_CONFIGS = ("Debug", "Release")
DIRECT_CONFIGS = ("DirectDebug", "DirectRelease")


def configuration_settings(list_id):
    """{configuration name: its build settings text} for one target's configuration list."""
    listing = re.search(r"%s /\* Build configuration list[^*]*\*/ = \{.*?buildConfigurations = \((.*?)\);" % list_id,
                        PROJECT, re.S).group(1)
    found = {}
    for config_id in re.findall(r"([0-9A-F]+) /\*", listing):
        block = re.search(r"\t\t%s /\* \w+ \*/ = \{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = \{\n(.*?)\n\t\t\t\};\n\t\t\tname = (\w+);"
                          % config_id, PROJECT, re.S)
        found[block.group(2)] = block.group(1)
    return found


class SettingsTests(unittest.TestCase):
    def test_the_shipped_settings_still_hold_the_placeholder_and_are_refused(self):
        env = config.read_env()
        self.assertEqual(env["SPARKLE_FEED_URL"], config.EXPECTED_FEED)
        if env["SPARKLE_PUBLIC_ED_KEY"] == config.PLACEHOLDER:
            self.assertTrue(config.release_problems(env))

    def test_only_a_real_key_is_fit_to_ship(self):
        feed = {"SPARKLE_FEED_URL": config.EXPECTED_FEED}
        self.assertEqual(config.release_problems({**feed, "SPARKLE_PUBLIC_ED_KEY": GOOD_KEY}), [])
        for bad in (config.PLACEHOLDER, "", "not base64!", base64.b64encode(b"short").decode(),
                    base64.b64encode(bytes(64)).decode()):
            with self.subTest(bad):
                self.assertTrue(config.release_problems({**feed, "SPARKLE_PUBLIC_ED_KEY": bad}))
        self.assertTrue(config.release_problems({"SPARKLE_FEED_URL": "http://example.com/appcast.xml",
                                                 "SPARKLE_PUBLIC_ED_KEY": GOOD_KEY}))

    def test_a_built_app_must_carry_the_same_key_and_feed_and_ask_before_installing(self):
        env = {"SPARKLE_FEED_URL": config.EXPECTED_FEED, "SPARKLE_PUBLIC_ED_KEY": GOOD_KEY}
        info = {"SUPublicEDKey": GOOD_KEY, "SUFeedURL": config.EXPECTED_FEED,
                "SUEnableAutomaticChecks": True, "SUAllowsAutomaticUpdates": False}
        self.assertEqual(config.app_problems(info, env), [])
        for change in ({"SUPublicEDKey": base64.b64encode(bytes(32)).decode()}, {"SUFeedURL": "https://example.com/a.xml"},
                       {"SUEnableAutomaticChecks": False}, {"SUAllowsAutomaticUpdates": True}):
            with self.subTest(change):
                self.assertTrue(config.app_problems({**info, **change}, env))

    def test_writing_a_key_fills_the_placeholder_and_will_not_replace_a_real_key_by_accident(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "update-feed.env"
            shutil.copy(config.FEED_ENV, path)
            path.write_text(re.sub(r"^SPARKLE_PUBLIC_ED_KEY=.*$", "SPARKLE_PUBLIC_ED_KEY=" + config.PLACEHOLDER,
                                   path.read_text(), flags=re.M))
            config.write_key(GOOD_KEY, path=path)
            self.assertEqual(config.read_env(path)["SPARKLE_PUBLIC_ED_KEY"], GOOD_KEY)
            config.write_key(GOOD_KEY, path=path)  # the same key again is fine
            other = base64.b64encode(bytes(reversed(range(32)))).decode()
            with self.assertRaises(ValueError):
                config.write_key(other, path=path)
            config.write_key(other, replace=True, path=path)
            self.assertEqual(config.read_env(path)["SPARKLE_PUBLIC_ED_KEY"], other)
            with self.assertRaises(ValueError):
                config.write_key("nonsense", path=path)

    def test_the_release_script_refuses_to_start_with_the_placeholder(self):
        if config.read_env()["SPARKLE_PUBLIC_ED_KEY"] != config.PLACEHOLDER:
            self.skipTest("the real key is in place")
        out = Path(tempfile.mkdtemp()) / "release"
        try:
            run = subprocess.run([str(ROOT / "Tools/release/direct-release.sh"), str(out)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 1)
            self.assertIn("placeholder", run.stderr)
            self.assertFalse(out.exists(), "nothing may be built before the guard speaks")
        finally:
            shutil.rmtree(out.parent, ignore_errors=True)

    def test_the_pin_file_matches_the_download_it_names(self):
        pin = dict(line.split("=", 1) for line in (HERE / "pin.env").read_text().splitlines() if re.match(r"^[A-Z0-9_]+=", line))
        self.assertIn(pin["SPARKLE_VERSION"], pin["SPARKLE_URL"])
        self.assertTrue(pin["SPARKLE_URL"].startswith("https://github.com/sparkle-project/Sparkle/releases/download/"))
        self.assertRegex(pin["SPARKLE_SHA256"], r"^[0-9a-f]{64}$")


class StoreEditionTests(unittest.TestCase):
    """The App Store edition is the same target built as Debug or Release. None of it may touch Sparkle."""

    def test_the_store_configurations_have_no_sparkle_settings_and_the_direct_ones_do(self):
        settings = configuration_settings(MAC_TARGET_CONFIGS)
        self.assertEqual(set(settings), set(STORE_CONFIGS + DIRECT_CONFIGS))
        for name in STORE_CONFIGS:
            self.assertNotIn("Sparkle", settings[name], name)
            self.assertNotIn("NOLLIE_DIRECT", settings[name], name)
        for name in DIRECT_CONFIGS:
            self.assertIn("-framework", settings[name], name)
            self.assertIn("Sparkle,", settings[name], name)
            self.assertIn("NOLLIE_DIRECT", settings[name], name)

    def test_the_store_test_bundle_has_no_sparkle_settings_either(self):
        settings = configuration_settings("AA00000000000000000583")
        for name in STORE_CONFIGS:
            self.assertNotIn("Sparkle", settings[name], name)

    def test_no_target_links_sparkle_as_a_package_or_in_a_frameworks_phase(self):
        self.assertNotRegex(PROJECT, r"productName = Sparkle;")
        self.assertNotRegex(PROJECT, r"sparkle-project")
        self.assertNotRegex(PROJECT, r"Sparkle\.framework in Frameworks")
        for phase in re.findall(r"/\* Frameworks \*/ = \{.*?\n\t\t\};", PROJECT, re.S):
            self.assertNotIn("Sparkle", phase)

    def test_only_compiled_out_files_in_the_mac_updater_folder_know_sparkle(self):
        files = [path for folder in ("Apps", "Shared", "Extensions", "Services", "Packages", "Companions")
                 for path in (ROOT / folder).rglob("*.swift") if "/.build/" not in str(path)]
        importers = [path for path in files if re.search(r"^\s*(@preconcurrency\s+)?import\s+Sparkle\b", path.read_text(), re.M)]
        self.assertTrue(importers, "the updater has to import Sparkle somewhere")
        for path in importers:
            text = path.read_text()
            with self.subTest(str(path.relative_to(ROOT))):
                self.assertEqual(path.parent, ROOT / "Apps/Mac/Update")
                self.assertTrue(text.startswith("#if NOLLIE_DIRECT\n"), "the whole file is compiled out of the store edition")
                self.assertTrue(text.rstrip().endswith("#endif"))
                self.assertEqual(text.count("#if "), text.count("#endif"))

    def test_everything_in_the_updater_folder_is_compiled_out_of_the_store_edition(self):
        for path in (ROOT / "Apps/Mac/Update").glob("*.swift"):
            with self.subTest(path.name):
                self.assertTrue(path.read_text().startswith("#if NOLLIE_DIRECT\n"))

    def test_shared_files_reach_the_updater_only_behind_the_direct_flag(self):
        for relative, needle in (("Apps/Nollie/Settings/AboutView.swift", "UpdateSettingsSection"),
                                 ("Apps/Mac/NollieMacApp.swift", "MacUpdateCommands")):
            text = (ROOT / relative).read_text()
            at = text.index(needle)
            self.assertIn("NOLLIE_DIRECT", text[max(0, at - 120):at], relative)

    def test_the_info_plist_has_no_update_keys_for_the_store_edition(self):
        info = plistlib.loads((ROOT / "Apps/Mac/Info.plist").read_bytes())
        self.assertFalse([key for key in info if key.startswith("SU")])

    def test_the_embed_step_adds_nothing_to_a_store_build_and_refuses_leftovers(self):
        with tempfile.TemporaryDirectory() as folder:
            build = Path(folder) / "Products"
            contents = build / "Nollie.app/Contents"
            (contents / "Frameworks").mkdir(parents=True)
            info = contents / "Info.plist"
            info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "x"}))
            before = info.read_bytes()
            environment = {**os.environ, "CONFIGURATION": "Release", "TARGET_BUILD_DIR": str(build),
                           "CONTENTS_FOLDER_PATH": "Nollie.app/Contents", "FRAMEWORKS_FOLDER_PATH": "Nollie.app/Contents/Frameworks",
                           "INFOPLIST_PATH": "Nollie.app/Contents/Info.plist", "SRCROOT": str(ROOT)}
            for configuration in STORE_CONFIGS:
                clean = subprocess.run(["/bin/sh", str(HERE / "embed-sparkle.sh")], env={**environment, "CONFIGURATION": configuration},
                                       capture_output=True, text=True)
                self.assertEqual(clean.returncode, 0, clean.stderr)
                self.assertEqual(list((contents / "Frameworks").iterdir()), [])
                self.assertEqual(info.read_bytes(), before)
            (contents / "Frameworks/Sparkle.framework").mkdir()
            leftover = subprocess.run(["/bin/sh", str(HERE / "embed-sparkle.sh")], env=environment, capture_output=True, text=True)
            self.assertEqual(leftover.returncode, 1)
            self.assertIn("client edition", leftover.stderr)
            (contents / "Frameworks/Sparkle.framework").rmdir()
            info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "x", "SUFeedURL": "https://example.com"}))
            keys = subprocess.run(["/bin/sh", str(HERE / "embed-sparkle.sh")], env=environment, capture_output=True, text=True)
            self.assertEqual(keys.returncode, 1)

    @unittest.skipUnless(os.environ.get("NOLLIE_STORE_APP"), "set NOLLIE_STORE_APP to a built NollieMac (store) Nollie.app")
    def test_a_built_store_app_has_no_sparkle(self):
        app = Path(os.environ["NOLLIE_STORE_APP"])
        self.assertFalse((app / "Contents/Frameworks/Sparkle.framework").exists())
        self.assertFalse((app / "Contents/Resources/Notices/Sparkle").exists())
        linked = subprocess.run(["otool", "-L", str(app / "Contents/MacOS/Nollie")], capture_output=True, text=True).stdout
        self.assertNotIn("Sparkle", linked)
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        self.assertFalse([key for key in info if key.startswith("SU")])
        strings = subprocess.run(["strings", "-a", str(app / "Contents/MacOS/Nollie")], capture_output=True, text=True).stdout
        self.assertNotIn("SPUUpdater", strings)
        self.assertNotIn("SUFeedURL", strings)


if __name__ == "__main__":
    unittest.main()
