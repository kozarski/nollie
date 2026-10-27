"""Managed profile creation stays hidden until Ask first is ready. No Hermes service runs."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
from types import SimpleNamespace
import unittest

ENTRY = Path(__file__).resolve().parents[2] / "Services/Runtime/runtime_entry.py"
spec = importlib.util.spec_from_file_location("nollie_profile_workflow_fixture", ENTRY)
entry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(entry)


class ProfileWorkflowTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="nollie-profile-workflow-")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name) / "home"
        (self.home / "profiles").mkdir(parents=True)
        self.events = []
        self.private = {"private", "moss", "personal"}
        self.fail = False
        self.clone_plugins = ["existing-addon"]

        def finish(path, **kwargs):
            self.events.append("layout")

        def create(name, clone_from=None, clone_all=False, clone_config=False, *rest, **kwargs):
            self.events.append("create")
            canon = name.lower()
            destination = self.home / "profiles" / canon
            staging = destination.with_name(f".{canon}.staging-{os.getpid()}")
            staging.mkdir()
            try:
                config = {"model": "fixture-model", "plugins": {"enabled": list(self.clone_plugins)}}
                (staging / "config.yaml").write_text(json.dumps(config))
                self.profiles._finish_profile_layout(staging)
                staging.rename(destination)
                self.events.append("published")
                return destination
            except BaseException:
                shutil.rmtree(staging)
                raise

        def ensure(home, name, path):
            self.assertEqual(home, self.home)
            self.assertFalse((self.home / "profiles" / name).exists())
            self.events.append("ask-first")
            if self.fail:
                raise ValueError("fixture setup failed")
            config = json.loads((path / "config.yaml").read_text())
            config["plugins"]["enabled"].append("nollie-workflow")
            (path / "config.yaml").write_text(json.dumps(config))

        self.profiles = SimpleNamespace(create_profile=create, _finish_profile_layout=finish,
                                        _canon_valid=str.lower, get_active_profile_name=lambda: "default")
        policy = SimpleNamespace(excluded=lambda name, private: name in private)
        self.addons = SimpleNamespace(WORKFLOW="nollie-workflow", ensure_profile_workflow=ensure,
                                      workflow_privacy=lambda *_: (policy, self.private))
        self.cloned = []

        def clone_keys(path, source, keep_channels):
            self.assertTrue(Path(path).name.startswith(".") and "staging" in Path(path).name)
            self.events.append("keys")
            self.cloned.append((source, keep_channels))

        entry._scope_profile_workflow(self.profiles, self.addons, self.home, clone_keys)

    def test_new_and_cloned_bots_get_rules_before_publication(self):
        for name, options, events in (("fresh", {}, ["create", "layout", "ask-first", "published"]),
                                      ("clone", {"clone_from": "default"}, ["create", "layout", "ask-first", "keys", "published"])):
            with self.subTest(name=name):
                self.events.clear()
                path = self.profiles.create_profile(name, **options)
                config = json.loads((path / "config.yaml").read_text())
                self.assertEqual(config["plugins"]["enabled"], ["existing-addon", "nollie-workflow"])
                self.assertEqual(config["model"], "fixture-model")
                self.assertEqual(self.events, events)

    def test_copies_note_their_source_for_keys_before_publication(self):
        self.profiles.create_profile("first", "Scout")
        self.profiles.create_profile("second", clone_config=True)
        self.profiles.create_profile("third", clone_from="scout", clone_channels=True)
        self.profiles.create_profile("fourth", None, False, True, False, False, None, True)
        self.profiles.create_profile("fresh")
        self.assertEqual(self.cloned, [("scout", False), ("default", False), ("scout", True), ("default", True)])

    def test_safety_failure_aborts_before_publication(self):
        self.fail = True
        with self.assertRaises(ValueError):
            self.profiles.create_profile("fresh")
        self.assertEqual(list((self.home / "profiles").iterdir()), [])
        self.assertNotIn("published", self.events)
        self.fail = False
        self.profiles.create_profile("retry")
        self.assertEqual(self.events[-1], "published")

    def test_private_target_and_clone_source_are_never_read_or_created(self):
        for name, options in (("personal", {}), ("fresh", {"clone_from": "personal"}),
                              ("moss", {}), ("fresh", {"clone_from": "MoSs"})):
            with self.subTest(name=name, options=options):
                with self.assertRaises(ValueError):
                    self.profiles.create_profile(name, **options)
                self.assertEqual(self.events, [])
                self.assertEqual(list((self.home / "profiles").iterdir()), [])

    def test_implicit_clone_from_private_active_bot_is_refused(self):
        self.profiles.get_active_profile_name = lambda: "personal"
        with self.assertRaises(ValueError):
            self.profiles.create_profile("fresh", clone_all=True)
        with self.assertRaises(ValueError):
            self.profiles.create_profile("fresh", None, False, True)
        self.assertEqual(self.events, [])

    def test_layout_outside_creation_cannot_enable_an_existing_bot(self):
        with self.assertRaises(ValueError):
            self.profiles._finish_profile_layout(self.home / "profiles" / "existing")
        self.assertEqual(self.events, [])


if __name__ == "__main__":
    unittest.main()
