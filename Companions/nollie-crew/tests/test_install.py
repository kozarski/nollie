import importlib.util
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("crew_installer", Path(__file__).resolve().parents[1] / "install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def run(home, *argv, which="/fixed/hermes", result=None):
    calls = []

    def fake_run(command, **kwargs):
        calls.append((command, kwargs))
        return result or SimpleNamespace(returncode=0, stdout="", stderr="")

    with patch.object(Path, "home", return_value=home), patch("sys.argv", ["install.py", *argv]), \
            patch.object(installer.shutil, "which", return_value=which), \
            patch.object(installer.subprocess, "run", side_effect=fake_run), patch("builtins.print"):
        installer.main()
    return calls


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)

    def test_plan_writes_nothing_and_runs_nothing(self):
        calls = run(self.home, "--enable", "--local-model", "llamacpp:fixture-small")
        self.assertEqual(calls, [])
        self.assertFalse((self.home / ".hermes").exists())

    def test_apply_backs_up_installs_and_enables_for_nollie_only(self):
        root = self.home / ".hermes"
        target = root / "plugins/nollie-crew"
        target.mkdir(parents=True)
        (target / "previous.txt").write_text("old")
        (root / "config.yaml").write_text("fixture: true\n")
        calls = run(self.home, "--apply", "--enable", "--local-model", "llamacpp:fixture-small")
        self.assertEqual([c[0] for c in calls], [["/fixed/hermes", "--profile", "default", "plugins", "enable", "nollie-crew"]])
        self.assertTrue(calls[0][1]["capture_output"])
        backup = next(root.glob("config.yaml.bak-nollie-crew-*"))
        self.assertEqual(backup.read_text(), "fixture: true\n")
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        self.assertEqual((root / "config.yaml").read_text(), "fixture: true\n")
        self.assertEqual(len(list((root / "plugin-backups").glob("nollie-crew-*/previous.txt"))), 1)
        for name in installer.FILES + ("dashboard/plugin_api.py", "dashboard/manifest.json"):
            self.assertTrue((target / name).exists(), name)
        self.assertFalse((target / "tests").exists())
        self.assertFalse((target / "install.py").exists())
        settings = json.loads((root / "nollie-crew/settings.json").read_text())
        self.assertEqual(settings, {"local_model": {"provider": "llamacpp", "default": "fixture-small"}})
        self.assertFalse(list(root.glob("profiles/*")))

    def test_files_only_leaves_hermes_config_alone(self):
        root = self.home / ".hermes"
        root.mkdir()
        (root / "config.yaml").write_text("fixture: true\n")
        self.assertEqual(run(self.home, "--apply"), [])
        self.assertFalse(list(root.glob("config.yaml.bak-*")))
        self.assertTrue((root / "plugins/nollie-crew/plugin.yaml").exists())

    def test_settings_update_keeps_other_values_and_a_backup(self):
        settings = self.home / ".hermes/nollie-crew/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text('{"keep": 1}')
        run(self.home, "--apply", "--local-model", "llamacpp:fixture-two")
        self.assertEqual(json.loads(settings.read_text())["keep"], 1)
        self.assertEqual(len(list(settings.parent.glob("settings.json.bak-*"))), 1)

    def test_bad_local_model_is_refused(self):
        with self.assertRaises(SystemExit):
            with patch("sys.stderr"):
                run(self.home, "--local-model", "no-colon")

    def test_linked_destination_is_refused(self):
        root = self.home / ".hermes/plugins"
        root.mkdir(parents=True)
        (root / "nollie-crew").symlink_to(self.home)
        with self.assertRaises(SystemExit):
            run(self.home, "--apply")


if __name__ == "__main__":
    unittest.main()
