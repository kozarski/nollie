from concurrent.futures import ThreadPoolExecutor
import importlib
from pathlib import Path
import shutil
import sys
import threading
import types
import unittest
from unittest.mock import patch

from support import Home, PACKAGE, policy, store

hermes_profiles = importlib.import_module(PACKAGE + ".hermes_profiles")


class ProfileSafetyTests(unittest.TestCase):
    def setUp(self):
        self.home = Home()
        self.addCleanup(self.home.cleanup)

    def test_undo_old_update_keeps_ask_first_and_backs_up_config(self):
        args = {"name": "Rover", "role": "check new roles", "come_to_me_for": "New roles.", "asked_by_person": True}
        self.home.call("crew_add", args)
        path = self.home.root / "profiles/rover/config.yaml"
        (path.parent / "nollie-workflow/ask-first-initialized").unlink()
        old = store.read_yaml(path)
        old["plugins"]["enabled"].remove("nollie-workflow")
        old["plugins"]["disabled"].append("user/nollie-workflow")
        store.write_yaml(path, old)
        before = path.read_bytes()
        shutil.rmtree(path.parent / "plugins/nollie-workflow")
        changed = self.home.call("crew_update", {"name": "Rover", "role": "look for new roles"})
        self.assertEqual(changed["status"], "updated", changed)
        self.assertEqual(next(path.parent.glob("config.yaml.bak-nollie-crew-*")).read_bytes(), before)
        self.assertEqual(self.home.call("crew_undo", {"token": changed["undo"]})["status"], "restored")
        self.assertIn("nollie-workflow", store.read_yaml(path)["plugins"]["enabled"])
        self.assertNotIn("user/nollie-workflow", store.read_yaml(path)["plugins"]["disabled"])
        self.assertTrue((path.parent / "plugins/nollie-workflow/ask_first.py").is_file())

    def test_restore_older_member_has_rules_before_publication(self):
        args = {"name": "Rover", "role": "check new roles", "come_to_me_for": "New roles.", "asked_by_person": True}
        self.home.call("crew_add", args)
        path = self.home.root / "profiles/rover/config.yaml"
        (path.parent / "nollie-workflow/ask-first-initialized").unlink()
        old = store.read_yaml(path)
        old["plugins"]["enabled"].remove("nollie-workflow")
        store.write_yaml(path, old)
        shutil.rmtree(path.parent / "plugins/nollie-workflow")
        retired = self.home.call("crew_retire", {"name": "Rover", "confirm": True})
        publish = self.home.profiles._restore_home
        seen = []

        def observe(staged, profile_id):
            self.assertFalse(path.parent.exists())
            self.assertTrue((staged / "plugins/nollie-workflow/ask_first.py").is_file())
            self.assertIn("nollie-workflow", store.read_yaml(staged / "config.yaml")["plugins"]["enabled"])
            seen.append(profile_id)
            publish(staged, profile_id)

        with patch.object(self.home.profiles, "_restore_home", side_effect=observe):
            result = self.home.call("crew_undo", {"token": retired["undo"]})
        self.assertEqual(result["status"], "active", result)
        self.assertEqual(seen, ["rover"])

    def test_member_updates_and_undo_keep_the_persons_ask_first_choice(self):
        args = {"name": "Rover", "role": "check new roles", "come_to_me_for": "New roles.", "asked_by_person": True}
        self.home.call("crew_add", args)
        path = self.home.root / "profiles/rover/config.yaml"
        for disabled in (True, False):
            with self.subTest(disabled=disabled):
                config = store.read_yaml(path)
                config["plugins"]["enabled"] = ["nollie-guard"]
                config["plugins"]["disabled"] = ["nollie-crew"] + (["user/nollie-workflow"] if disabled else [])
                store.write_yaml(path, config)
                expected = config["plugins"]
                changed = self.home.call("crew_update", {"name": "Rover", "toolsets": ["web"]})
                self.assertEqual(changed["status"], "updated", changed)
                self.assertEqual(store.read_yaml(path)["plugins"], expected)
                self.assertEqual(self.home.call("crew_undo", {"token": changed["undo"]})["status"], "restored")
                self.assertEqual(store.read_yaml(path)["plugins"], expected)

    def test_restore_initialized_member_keeps_ask_first_off(self):
        args = {"name": "Rover", "role": "check new roles", "come_to_me_for": "New roles.", "asked_by_person": True}
        self.home.call("crew_add", args)
        path = self.home.root / "profiles/rover/config.yaml"
        config = store.read_yaml(path)
        config["plugins"]["disabled"].append("nollie-workflow")
        store.write_yaml(path, config)
        retired = self.home.call("crew_retire", {"name": "Rover", "confirm": True})
        result = self.home.call("crew_undo", {"token": retired["undo"]})
        self.assertEqual(result["status"], "active", result)
        self.assertEqual(store.read_yaml(path)["plugins"], config["plugins"])
        self.assertEqual((path.parent / "nollie-workflow/ask-first-initialized").read_text(), "1\n")

    def fake_hermes(self):
        profiles = types.ModuleType("hermes_cli.profiles")
        profiles.get_profile_dir = lambda name: self.home.root if name == "default" else self.home.root / "profiles" / name
        profiles.validate_profile_name = lambda name: None
        profiles._finish_profile_layout = lambda path, **kwargs: None
        profiles.write_profile_meta = lambda path, **kwargs: store.write_yaml(Path(path) / "profile.yaml", kwargs)
        parent = types.ModuleType("hermes_cli")
        parent.profiles = profiles
        return profiles, {"hermes_cli": parent, "hermes_cli.profiles": profiles}

    def test_overlapping_hermes_creates_keep_rules_scoped_before_publication(self):
        profiles, modules = self.fake_hermes()
        barrier = threading.Barrier(3)
        seen = {}

        def create(name, **kwargs):
            staging = self.home.root / "profiles" / f".{name}.staging-fixture"
            staging.mkdir()
            store.write_yaml(staging / "config.yaml", {"unbounded": True})
            barrier.wait(timeout=10)
            profiles._finish_profile_layout(staging, description=kwargs.get("description"))
            seen[name] = store.read_yaml(staging / "config.yaml")
            if name != "ordinary":
                self.assertTrue((staging / "plugins/nollie-workflow/ask_first.py").is_file())
                self.assertIn("nollie-workflow", seen[name]["plugins"]["enabled"])
                self.assertEqual((staging / "nollie-workflow/ask-first-initialized").read_text(), "1\n")
                self.assertFalse((self.home.root / "profiles" / name).exists())
            staging.rename(self.home.root / "profiles" / name)

        profiles.create_profile = create
        nollie = self.home.profiles.read_config("default")

        def member(name, tools):
            backend = hermes_profiles.HermesProfiles(self.home.root)
            config = policy.member_config(nollie, policy.resolve_reach(nollie, tools), {})
            backend.create(name, config=config, soul=name, display_name=name, description="A helper.",
                           marker={"id": name})

        with patch.dict(sys.modules, modules):
            with ThreadPoolExecutor(max_workers=3) as pool:
                futures = [pool.submit(member, "rover", ["web"]), pool.submit(member, "ivy", ["file"]),
                           pool.submit(create, "ordinary")]
                for future in futures:
                    future.result(timeout=15)
        self.assertEqual(seen["ordinary"], {"unbounded": True})
        self.assertEqual(seen["rover"]["platform_toolsets"]["cli"], ["web"])
        self.assertEqual(seen["ivy"]["platform_toolsets"]["cli"], ["file"])

    def test_private_hermes_restore_never_clears_a_tombstone(self):
        profiles, modules = self.fake_hermes()
        constants = types.ModuleType("hermes_constants")
        constants.clear_named_profile_deleted = lambda path: self.fail("private tombstone touched")
        modules["hermes_constants"] = constants
        store.write_json(self.home.root / "nollie-private-bots.json", {"version": 1, "profiles": ["rover"]})
        with patch.dict(sys.modules, modules):
            backend = hermes_profiles.HermesProfiles(self.home.root)
            with self.assertRaisesRegex(policy.CrewError, "private"):
                backend.restore("unused.tar.gz", "rover")

    def test_wrong_or_linked_profile_folder_is_refused(self):
        folder = self.home.root / "profiles"
        before = list((folder / "private").iterdir())
        with self.assertRaises(policy.CrewError):
            self.home.profiles.workflow.copy_into("rover", folder / "private")
        (folder / "rover").symlink_to(folder / "private", target_is_directory=True)
        with self.assertRaises(policy.CrewError):
            self.home.profiles.workflow.copy_into("rover", folder / "rover")
        self.assertEqual(list((folder / "private").iterdir()), before)

    def test_unexpected_hermes_staging_name_is_refused(self):
        profiles, modules = self.fake_hermes()

        def create(name, **kwargs):
            staging = self.home.root / "profiles" / "unexpected"
            staging.mkdir()
            profiles._finish_profile_layout(staging)
            self.fail("unexpected staging folder published")

        profiles.create_profile = create
        nollie = self.home.profiles.read_config("default")
        config = policy.member_config(nollie, policy.resolve_reach(nollie), {})
        with patch.dict(sys.modules, modules):
            backend = hermes_profiles.HermesProfiles(self.home.root)
            with self.assertRaisesRegex(policy.CrewError, "Hermes needs updating"):
                backend.create("rover", config=config, soul="Rover", display_name="Rover", description="A helper.",
                               marker={"id": "rover"})
        self.assertFalse((self.home.root / "profiles/rover").exists())


if __name__ == "__main__":
    unittest.main()
