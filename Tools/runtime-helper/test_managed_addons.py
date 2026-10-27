"""The managed setup's add-on installer, against temporary homes only. No network, no Hermes."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("nollie_managed_addons", ROOT / "Services/Runtime/managed_addons.py")
addons = importlib.util.module_from_spec(spec)
spec.loader.exec_module(addons)


def digest(data):
    return hashlib.sha256(data).hexdigest()


class ManagedAddOnsTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name)
        self.kit = self.root / "kit"
        self.installation = self.root / "setup"
        self.home = self.installation / "home"
        self.home.mkdir(parents=True)
        self.addCleanup(setattr, addons, "TRUSTED", addons.TRUSTED)
        addons.TRUSTED = self.installation
        self.addCleanup(setattr, sys, "dont_write_bytecode", sys.dont_write_bytecode)
        sys.dont_write_bytecode = True
        (self.home / "config.yaml").write_text(json.dumps({"approvals": {"mode": "manual"}}, indent=2))
        self.write_kit({"nollie-crew/plugin.yaml": b"name: nollie-crew\n", "nollie-crew/crew.py": b"VERSION = 1\n",
                        "nollie-reader/plugin.yaml": b"name: nollie-reader\n",
                        "nollie-reader/requirements.txt": b"trafilatura==2.3.1 \\\n    --hash=sha256:abc\n"})

    def tearDown(self):
        self.folder.cleanup()

    def write_kit(self, files):
        items = {}
        for path, data in files.items():
            target = self.kit / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            items.setdefault(path.split("/")[0], []).append({"path": path, "bytes": len(data), "sha256": digest(data)})
        lock = self.kit / "nollie-reader/requirements.txt"
        kit = {"schema": 1, "installer": {"path": "managed_addons.py", "bytes": 0, "sha256": "0" * 64},
               "readerLock": {"path": "nollie-reader/requirements.txt", "bytes": lock.stat().st_size,
                              "sha256": digest(lock.read_bytes())},
               "items": [{"name": name, "version": "0.1.0", "files": entries} for name, entries in items.items()]}
        (self.kit / "kit.json").write_text(json.dumps(kit))

    def fake_run(self, calls):
        def run(command, **_):
            calls.append(command)
            if command[1:3] == ["--no-config", "venv"]:
                (Path(command[-1]) / "bin").mkdir(parents=True)
            return subprocess.CompletedProcess(command, 0, "", None)
        return run

    def install(self, calls=None):
        calls = [] if calls is None else calls
        with mock.patch.dict(os.environ, {"HERMES_HOME": str(self.home)}), \
                mock.patch.object(addons.subprocess, "run", self.fake_run(calls)):
            return addons.main(["--kit", str(self.kit), "--installation", str(self.installation),
                                "--uv", "/fixture/uv", "--python", "/fixture/python3.14"])

    def config(self):
        return json.loads((self.home / "config.yaml").read_text())

    def workflow_files(self):
        source = ROOT / "Companions/nollie-workflow"
        return {f"nollie-workflow/{name}": (source / name).read_bytes()
                for name in ("__init__.py", "workflow_core.py", "private_bots.py", "plugin.yaml")}

    def seed_workflow(self):
        for relative, data in self.workflow_files().items():
            target = self.home / "plugins" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)

    def bot(self, name, config=None):
        home = self.home / "profiles" / name
        home.mkdir(parents=True)
        (home / "config.yaml").write_text(json.dumps(config or {"approvals": {"mode": "manual"}}))
        return home

    def private(self, *names):
        (self.home / "nollie-private-bots.json").write_text(json.dumps({"version": 1, "profiles": list(names)}))

    def snapshot(self, home):
        return {str(path.relative_to(home)): path.read_bytes() for path in home.rglob("*") if path.is_file()}

    def test_first_install_copies_lists_and_keeps_a_config_backup(self):
        calls = []
        self.assertEqual(self.install(calls), 0)
        self.assertEqual((self.home / "plugins/nollie-crew/crew.py").read_bytes(), b"VERSION = 1\n")
        self.assertEqual(self.config()["plugins"]["enabled"], ["nollie-crew", "nollie-reader"])
        self.assertEqual(self.config()["approvals"], {"mode": "manual"})
        backups = list(self.home.glob("config.yaml.bak-nollie-addons-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(json.loads(backups[0].read_text()), {"approvals": {"mode": "manual"}})
        self.assertEqual(oct(backups[0].stat().st_mode & 0o777), "0o600")
        install = next(command for command in calls if "install" in command)
        self.assertIn("--require-hashes", install)
        self.assertIn("--no-build", install)
        marker = self.home / "nollie-reader/venv/nollie-lock.sha256"
        self.assertEqual(marker.read_text(), digest((self.kit / "nollie-reader/requirements.txt").read_bytes()) + "\n")

    def test_a_second_run_changes_nothing(self):
        self.assertEqual(self.install(), 0)
        before = (self.home / "config.yaml").read_bytes()
        calls = []
        self.assertEqual(self.install(calls), 0)
        self.assertEqual(calls, [])
        self.assertEqual((self.home / "config.yaml").read_bytes(), before)
        self.assertEqual(len(list(self.home.glob("config.yaml.bak-*"))), 1)
        self.assertFalse((self.home / "plugin-backups").exists())

    def test_real_workflow_kit_keeps_helpers_inside_the_addon(self):
        spec = importlib.util.spec_from_file_location("setup_kit_fixture", ROOT / "Tools/dev/setup-kit.py")
        kit = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(kit)
        destination = self.root / "Setup Kit"
        kit.build(destination)
        self.kit = destination / "add-ons"
        source = self.installation / "hermes/hermes_cli"
        source.mkdir(parents=True)
        sentinel = source / "nollie_board_observer.py"
        sentinel.write_text("existing source\n")
        self.assertEqual(self.install(), 0)
        installed = self.home / "plugins/nollie-workflow/hermes_support"
        for name in ("nollie_board_observer.py", "ollie_cron_followups.py"):
            self.assertEqual((installed / name).read_bytes(),
                             (ROOT / "Companions/nollie-workflow/hermes_support" / name).read_bytes())
        self.assertEqual(list(source.iterdir()), [sentinel])
        self.assertEqual(sentinel.read_text(), "existing source\n")

    def test_a_newer_add_on_replaces_the_old_copy_and_keeps_it(self):
        self.assertEqual(self.install(), 0)
        (self.home / "plugins/nollie-crew/leftover.py").write_text("old\n")
        self.write_kit({"nollie-crew/plugin.yaml": b"name: nollie-crew\n", "nollie-crew/crew.py": b"VERSION = 2\n",
                        "nollie-reader/plugin.yaml": b"name: nollie-reader\n",
                        "nollie-reader/requirements.txt": b"trafilatura==2.3.1 \\\n    --hash=sha256:abc\n"})
        self.assertEqual(self.install(), 0)
        self.assertEqual((self.home / "plugins/nollie-crew/crew.py").read_bytes(), b"VERSION = 2\n")
        self.assertFalse((self.home / "plugins/nollie-crew/leftover.py").exists())
        (backup,) = (self.home / "plugin-backups").iterdir()
        self.assertEqual((backup / "crew.py").read_bytes(), b"VERSION = 1\n")

    def test_a_disabled_add_on_stays_disabled_and_other_plugins_stay(self):
        (self.home / "config.yaml").write_text(json.dumps({"plugins": {"enabled": ["someone-else"],
                                                                       "disabled": ["nollie-reader"]}}))
        self.assertEqual(self.install(), 0)
        self.assertEqual(self.config()["plugins"]["enabled"], ["someone-else", "nollie-crew"])
        self.assertEqual(self.config()["plugins"]["disabled"], ["nollie-reader"])

    def test_install_covers_existing_bots_and_keeps_other_addons(self):
        files = {path.relative_to(self.kit).as_posix(): path.read_bytes()
                 for path in self.kit.rglob("*") if path.is_file() and path.name != "kit.json"}
        self.write_kit({**files, **self.workflow_files()})
        scout = self.bot("scout", {"plugins": {"enabled": ["custom"], "disabled": ["nollie-reader"]}})
        hidden = self.bot("personal")
        (hidden / "sessions").mkdir()
        (hidden / "sessions/chat.json").write_text("{}")
        moss = self.bot("moss")
        self.private("personal")
        before, untouched = self.snapshot(hidden), self.snapshot(moss)
        self.assertEqual(self.install(), 0)
        self.assertIn("nollie-workflow", self.config()["plugins"]["enabled"])
        self.assertEqual(json.loads((scout / "config.yaml").read_text())["plugins"],
                         {"enabled": ["custom", "nollie-workflow"], "disabled": ["nollie-reader"]})
        self.assertTrue((scout / "plugins/nollie-workflow/recorder-only").is_file())
        # A Private bot gets Ask first and the lease, and nothing else of it changes.
        self.assert_only_safety_added(hidden, before)
        self.assertEqual(self.snapshot(moss), untouched)
        current = self.snapshot(self.home)
        self.assertEqual(self.install(), 0)
        self.assertEqual(self.snapshot(self.home), current)

    def test_startup_turns_on_every_non_private_bot_once_with_verified_backups(self):
        self.seed_workflow()
        scout = self.bot("scout", {"plugins": {"enabled": ["custom"],
                                               "disabled": ["user/nollie-workflow", "nollie-workflow", "nollie-reader"]},
                                   "approvals": {"mode": "manual"}})
        mason = self.bot("mason", {"plugins": {"enabled": ["nollie-workflow"],
                                               "disabled": ["nollie-workflow"]}})
        originals = {path: (path / "config.yaml").read_bytes() for path in (self.home, scout, mason)}
        self.assertEqual(addons.ensure_workflow(self.home, "first"), ["default", "mason", "scout"])
        for path, original in originals.items():
            backup = path / "config.yaml.bak-nollie-addons-first"
            self.assertEqual(backup.read_bytes(), original)
            self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
            config = json.loads((path / "config.yaml").read_text())
            self.assertIn("nollie-workflow", config["plugins"]["enabled"])
            self.assertNotIn("nollie-workflow", config["plugins"].get("disabled", []))
            marker = path / "nollie-workflow/ask-first-initialized"
            self.assertEqual(marker.read_text(), "1\n")
            self.assertEqual(marker.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads((scout / "config.yaml").read_text())["plugins"],
                         {"enabled": ["custom", "nollie-workflow"], "disabled": ["nollie-reader"]})
        before = self.snapshot(self.home)
        self.assertEqual(addons.ensure_workflow(self.home, "second"), [])
        self.assertEqual(self.snapshot(self.home), before)

    def test_an_add_on_switched_off_comes_back_on_with_the_switch_off(self):
        self.seed_workflow()
        scout = self.bot("scout")
        mason = self.bot("mason")
        juniper = self.bot("juniper")
        addons.ensure_workflow(self.home, "first")
        for home, plugins in ((self.home, {"enabled": [], "disabled": ["nollie-workflow"]}),
                              (scout, {"enabled": ["nollie-workflow"], "disabled": ["user/nollie-workflow"]}),
                              (mason, {"enabled": ["custom"]})):
            (home / "config.yaml").write_text(json.dumps({"plugins": plugins}))
        (juniper / "nollie-workflow" / "ask-first.json").write_text(json.dumps({"version": 1, "enabled": True}))
        self.assertEqual(addons.ensure_workflow(self.home, "second"), ["default", "mason", "scout"])
        for home in (self.home, scout, mason):
            plugins = json.loads((home / "config.yaml").read_text())["plugins"]
            self.assertIn("nollie-workflow", plugins["enabled"])
            self.assertFalse([name for name in plugins.get("disabled", []) if name.endswith("nollie-workflow")])
            switch = home / "nollie-workflow" / "ask-first.json"
            self.assertEqual(json.loads(switch.read_text()), {"version": 1, "enabled": False})
            self.assertEqual(switch.stat().st_mode & 0o777, 0o600)
            self.assertTrue(list(home.glob("config.yaml.bak-nollie-addons-second")))
        # A bot whose add-on stayed on keeps its switch as it was.
        self.assertEqual(json.loads((juniper / "nollie-workflow" / "ask-first.json").read_text())["enabled"], True)
        before = self.snapshot(self.home)
        self.assertEqual(addons.ensure_workflow(self.home, "third"), [])
        self.assertEqual(self.snapshot(self.home), before)

    def test_an_unreadable_config_after_setup_is_left_as_hermes_finds_it(self):
        self.seed_workflow()
        scout = self.bot("scout")
        addons.ensure_workflow(self.home, "first")
        (scout / "config.yaml").write_bytes(b"not a readable config\xff")
        before = self.snapshot(scout)
        self.assertEqual(addons.ensure_workflow(self.home, "second"), [])
        self.assertEqual(self.snapshot(scout), before)

    def test_every_bot_starts_with_this_mac_off(self):
        self.seed_workflow()
        scout = self.bot("scout")
        mason = self.bot("mason")
        lease = mason / "bot-desktop" / "lease.json"
        lease.parent.mkdir()
        lease.write_text(json.dumps({"holder": "agent", "epoch": 4}))
        addons.ensure_workflow(self.home, "first")
        for home in (self.home, scout):
            written = home / "bot-desktop" / "lease.json"
            body = json.loads(written.read_text())
            self.assertEqual((body["holder"], body["epoch"], body["viewer_id"]), ("human", 1, "nollie-app"))
            self.assertEqual(written.stat().st_mode & 0o777, 0o600)
            self.assertEqual(written.parent.stat().st_mode & 0o777, 0o700)
        # The person's own choice stays: This Mac was turned on for Mason.
        self.assertEqual(json.loads(lease.read_text()), {"holder": "agent", "epoch": 4})
        # A linked lease is never written through.
        juniper = self.bot("juniper")
        outside = self.root / "outside-lease"
        (juniper / "bot-desktop").mkdir()
        (juniper / "bot-desktop" / "lease.json").symlink_to(outside)
        addons.ensure_workflow(self.home, "second")
        self.assertFalse(outside.exists())

    def test_install_update_keeps_ask_first_off_as_its_own_switch(self):
        files = {path.relative_to(self.kit).as_posix(): path.read_bytes()
                 for path in self.kit.rglob("*") if path.is_file() and path.name != "kit.json"}
        self.write_kit({**files, **self.workflow_files()})
        scout = self.bot("scout")
        self.assertEqual(self.install(), 0)
        for home, plugins in ((self.home, {"enabled": ["nollie-crew", "nollie-reader"]}),
                              (scout, {"enabled": ["nollie-workflow"], "disabled": ["nollie-workflow"]})):
            (home / "config.yaml").write_text(json.dumps({"plugins": plugins}))
        before = {home: (home / "config.yaml").read_bytes() for home in (self.home, scout)}
        self.write_kit({**files, **self.workflow_files(), "nollie-workflow/plugin.yaml": b"name: nollie-workflow\n# newer\n"})
        self.assertEqual(self.install(), 0)
        # Off by either list: the add-on is back on in both, and the choice is the switch's.
        for home, enabled in ((self.home, ["nollie-crew", "nollie-reader", "nollie-workflow"]),
                              (scout, ["nollie-workflow"])):
            plugins = json.loads((home / "config.yaml").read_text())["plugins"]
            self.assertEqual((plugins["enabled"], plugins.get("disabled", [])), (enabled, []))
            self.assertFalse(json.loads((home / "nollie-workflow/ask-first.json").read_text())["enabled"])
            self.assertTrue(list(home.glob("config.yaml.bak-nollie-addons-*")))

    def test_new_staged_bot_is_covered_before_it_is_published(self):
        self.seed_workflow()
        staged = self.bot(f".juniper.staging-{os.getpid()}")
        self.assertEqual(addons.ensure_profile_workflow(self.home, "juniper", staged), ["juniper"])
        self.assertEqual(json.loads((staged / "config.yaml").read_text())["plugins"]["enabled"],
                         ["nollie-workflow"])
        self.assertTrue((staged / "plugins/nollie-workflow/recorder-only").is_file())
        self.assertEqual((staged / "nollie-workflow/ask-first-initialized").read_text(), "1\n")
        self.assertFalse((self.home / "profiles/juniper").exists())

    def test_new_staged_bot_without_a_model_gets_its_first_config(self):
        self.seed_workflow()
        staged = self.bot(f".juniper.staging-{os.getpid()}")
        (staged / "config.yaml").unlink()
        self.assertEqual(addons.ensure_profile_workflow(self.home, "juniper", staged), ["juniper"])
        self.assertEqual(json.loads((staged / "config.yaml").read_text()),
                         {"plugins": {"enabled": ["nollie-workflow"]}})
        self.assertEqual(list(staged.glob("config.yaml.bak-*")), [])

    def test_new_clone_gets_ask_first_even_if_the_source_was_initialized_and_off(self):
        self.seed_workflow()
        staged = self.bot(f".juniper.staging-{os.getpid()}", {"plugins": {"enabled": [], "disabled": ["nollie-workflow"]}})
        addons.mark_workflow_initialized(staged)
        self.assertEqual(addons.ensure_profile_workflow(self.home, "juniper", staged), ["juniper"])
        self.assertEqual(json.loads((staged / "config.yaml").read_text())["plugins"],
                         {"enabled": ["nollie-workflow"], "disabled": []})

    def test_startup_covers_an_existing_bot_without_a_config(self):
        self.seed_workflow()
        juniper = self.bot("juniper")
        (juniper / "config.yaml").unlink()
        (juniper / "profile.yaml").write_text('display_name: Juniper\n')
        (self.home / "profiles/empty").mkdir()
        self.assertEqual(addons.ensure_workflow(self.home), ["default", "juniper"])
        self.assertEqual(json.loads((juniper / "config.yaml").read_text()),
                         {"plugins": {"enabled": ["nollie-workflow"]}})
        self.assertEqual((juniper / "profile.yaml").read_text(), 'display_name: Juniper\n')
        self.assertFalse((self.home / "profiles/empty/config.yaml").exists())

    def test_a_public_name_cannot_select_another_bots_folder(self):
        self.seed_workflow()
        moss = self.bot("moss")
        before = self.snapshot(moss)
        with self.assertRaises(addons.Refused):
            addons.ensure_profile_workflow(self.home, "juniper", moss)
        self.assertEqual(self.snapshot(moss), before)

    def assert_only_safety_added(self, home, before):
        """Only Ask first's pieces and the lease were added: the add-on, its record, the config and its backup."""
        after = self.snapshot(home)
        safety = ("plugins/", "nollie-workflow/", "bot-desktop/lease.json", "config.yaml")
        self.assertEqual({k: v for k, v in after.items() if not k.startswith(safety)},
                         {k: v for k, v in before.items() if not k.startswith(safety)})
        self.assertIn("nollie-workflow", json.loads((home / "config.yaml").read_text())["plugins"]["enabled"])
        self.assertEqual(json.loads((home / "bot-desktop/lease.json").read_text())["holder"], "human")

    def test_the_always_private_bots_are_never_read_or_given_addons(self):
        self.seed_workflow()
        homes = [self.bot(name) for name in ("private", "moss", "private-notes", "moss_diary")]
        for path in homes:
            (path / "config.yaml").write_bytes(b"not a readable config\xff")
        before = {path: self.snapshot(path) for path in homes}
        read_bytes = Path.read_bytes
        def read(path):
            if any(home == path or home in path.parents for home in homes):
                self.fail("an always-private bot was read")
            return read_bytes(path)
        with mock.patch.object(Path, "read_bytes", read):
            self.assertEqual(addons.ensure_workflow(self.home), ["default"])
            for path in homes:
                self.assertEqual(addons.ensure_profile_workflow(self.home, path.name, path), [])
        self.assertEqual({path: self.snapshot(path) for path in homes}, before)

    def test_private_bots_get_ask_first_and_this_mac_off_and_nothing_else(self):
        self.seed_workflow()
        self.private("personal", "default")
        personal = self.bot("personal")
        (personal / "SOUL.md").write_text("Keep my diary.")
        (personal / "memories").mkdir()
        (personal / "memories/notes.md").write_text("private")
        before, main = self.snapshot(personal), self.snapshot(self.home)
        self.assertEqual(addons.ensure_workflow(self.home, "first"), ["default", "personal"])
        self.assert_only_safety_added(personal, before)
        self.assertTrue((personal / "plugins/nollie-workflow/recorder-only").is_file())
        self.assertEqual(json.loads((self.home / "config.yaml").read_text())["plugins"]["enabled"], ["nollie-workflow"])
        self.assertEqual(json.loads((self.home / "bot-desktop/lease.json").read_text())["holder"], "human")
        # Creating a bot under a Private name is still refused before it is covered.
        staged = self.bot(f".personal.staging-{os.getpid()}")
        self.assertEqual(addons.ensure_profile_workflow(self.home, "personal", staged), [])
        self.assertFalse((staged / "plugins").exists())

    def test_installer_refuses_a_private_main_before_installing(self):
        files = {path.relative_to(self.kit).as_posix(): path.read_bytes()
                 for path in self.kit.rglob("*") if path.is_file() and path.name != "kit.json"}
        self.write_kit({**files, **self.workflow_files()})
        self.private("default")
        before = self.snapshot(self.home)
        self.assertEqual(self.install(), 1)
        self.assertEqual(self.snapshot(self.home), before)

    def test_damaged_private_list_stops_startup_before_any_bot_changes(self):
        self.seed_workflow()
        self.bot("scout")
        (self.home / "nollie-private-bots.json").write_text("{")
        before = self.snapshot(self.home)
        with self.assertRaises(ValueError):
            addons.ensure_workflow(self.home)
        self.assertEqual(self.snapshot(self.home), before)

    def test_profile_copy_updates_keep_papertrail_choice_and_old_copy(self):
        self.seed_workflow()
        scout = self.bot("scout")
        addons.ensure_workflow(self.home, "first")
        target = scout / "plugins/nollie-workflow"
        (target / "recorder-only").unlink()
        original = (target / "plugin.yaml").read_bytes()
        (self.home / "plugins/nollie-workflow/plugin.yaml").write_bytes(original + b"\n# newer\n")
        addons.ensure_workflow(self.home, "second")
        self.assertFalse((target / "recorder-only").exists())
        self.assertEqual((scout / "plugin-backups/nollie-workflow-second/plugin.yaml").read_bytes(), original)
        self.assertEqual(len(list(scout.glob("config.yaml.bak-*"))), 1)

    def test_linked_profiles_and_configs_are_refused_without_changing_target(self):
        self.seed_workflow()
        outside = self.root / "outside"
        outside.mkdir()
        config = outside / "config.yaml"
        config.write_text("{}")
        profiles = self.home / "profiles"
        profiles.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(addons.Refused):
            addons.ensure_workflow(self.home)
        profiles.unlink()
        profiles.mkdir()
        (profiles / "scout").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(addons.Refused):
            addons.ensure_workflow(self.home)
        (profiles / "scout").unlink()
        scout = self.bot("scout")
        (scout / "config.yaml").unlink()
        (scout / "config.yaml").symlink_to(config)
        with self.assertRaises(addons.Refused):
            addons.ensure_workflow(self.home)
        self.assertEqual(config.read_text(), "{}")

    def test_backup_failure_keeps_config_unchanged(self):
        self.seed_workflow()
        original = (self.home / "config.yaml").read_bytes()
        (self.home / "config.yaml.bak-nollie-addons-first").write_text("existing")
        with self.assertRaises(FileExistsError):
            addons.ensure_workflow(self.home, "first")
        self.assertEqual((self.home / "config.yaml").read_bytes(), original)
        self.assertFalse((self.home / "nollie-workflow/ask-first-initialized").exists())

    def test_linked_or_damaged_setup_marker_is_refused_before_config_changes(self):
        self.seed_workflow()
        state = self.home / "nollie-workflow"
        state.mkdir()
        marker = state / "ask-first-initialized"
        outside = self.root / "outside"
        outside.write_text("1\n")
        original = (self.home / "config.yaml").read_bytes()
        marker.symlink_to(outside)
        with self.assertRaises(addons.Refused):
            addons.ensure_workflow(self.home)
        marker.unlink()
        marker.write_text("broken")
        with self.assertRaises(addons.Refused):
            addons.ensure_workflow(self.home)
        self.assertEqual((self.home / "config.yaml").read_bytes(), original)
        self.assertEqual(outside.read_text(), "1\n")

    def test_broken_plugin_lists_are_not_silently_replaced(self):
        self.seed_workflow()
        for plugins in ({"enabled": "custom"}, {"disabled": "custom"}, {"enabled": [1]}):
            config = self.home / "config.yaml"
            config.write_text(json.dumps({"plugins": plugins}))
            original = config.read_bytes()
            with self.assertRaises(addons.Refused):
                addons.ensure_workflow(self.home)
            self.assertEqual(config.read_bytes(), original)

    def test_unreadable_yaml_is_refused_without_showing_its_contents(self):
        config = self.home / "config.yaml"
        config.write_text("not json")
        parser = mock.Mock()
        parser.load.side_effect = ValueError("fixture parser context")
        yaml = mock.Mock(YAML=mock.Mock(return_value=parser))
        with mock.patch.dict(sys.modules, {"ruamel": mock.Mock(), "ruamel.yaml": yaml}):
            with self.assertRaises(addons.Refused) as failure:
                addons.enable(self.home, ["nollie-workflow"], "first")
        self.assertNotIn("fixture parser context", str(failure.exception))
        self.assertEqual(config.read_text(), "not json")
        self.assertEqual(list(self.home.glob("config.yaml.bak-*")), [])

    def test_a_changed_kit_file_stops_before_anything_is_written(self):
        (self.kit / "nollie-crew/crew.py").write_bytes(b"VERSION = 666\n")
        self.assertEqual(self.install(), 1)
        self.assertFalse((self.home / "plugins").exists())
        self.assertNotIn("plugins", self.config())

    def test_refuses_a_linked_plugins_folder(self):
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        (self.home / "plugins").symlink_to(elsewhere)
        self.assertEqual(self.install(), 1)
        self.assertEqual(list(elsewhere.iterdir()), [])

    def test_runs_only_inside_the_setup_it_was_given(self):
        with mock.patch.dict(os.environ, {"HERMES_HOME": str(self.root / "another")}):
            code = addons.main(["--kit", str(self.kit), "--installation", str(self.installation),
                                "--uv", "/fixture/uv", "--python", "/fixture/python3.14"])
        self.assertEqual(code, 2)
        self.assertFalse((self.home / "plugins").exists())

    def test_a_failed_reader_build_leaves_no_half_environment(self):
        def failing(command, **_):
            if command[1:3] == ["--no-config", "venv"]:
                (Path(command[-1]) / "bin").mkdir(parents=True)
                return subprocess.CompletedProcess(command, 0, "", None)
            return subprocess.CompletedProcess(command, 1, "no network", None)
        with mock.patch.dict(os.environ, {"HERMES_HOME": str(self.home)}), \
                mock.patch.object(addons.subprocess, "run", failing):
            code = addons.main(["--kit", str(self.kit), "--installation", str(self.installation),
                                "--uv", "/fixture/uv", "--python", "/fixture/python3.14"])
        self.assertEqual(code, 1)
        self.assertEqual([p.name for p in (self.home / "nollie-reader").iterdir()], [])
        self.assertNotIn("plugins", self.config())


if __name__ == "__main__":
    unittest.main()
