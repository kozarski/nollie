import importlib.util
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("workflow_installer", Path(__file__).resolve().parents[1] / "install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

from night_support import load  # noqa: E402

night_shift = load("night_shift")
workflow_core = load("workflow_core")


class InstallTests(unittest.TestCase):
    def test_plan_has_no_writes_or_commands(self):
        with TemporaryDirectory() as temporary:
            home = Path(temporary)
            with patch.object(Path, "home", return_value=home), patch("sys.argv", ["install.py"]), \
                    patch.object(installer.subprocess, "run") as run, patch("builtins.print"):
                installer.main()
            self.assertFalse((home / ".hermes").exists())
            run.assert_not_called()

    def test_apply_backs_up_and_installs_stopped_without_running_agents(self):
        with TemporaryDirectory() as temporary:
            home = Path(temporary)
            root = home / ".hermes"
            source = root / "hermes-agent/hermes_cli"
            source.mkdir(parents=True)
            sentinel = source / "nollie_board_observer.py"
            sentinel.write_text("existing source stays untouched\n")
            target = root / "plugins/nollie-workflow"
            target.mkdir(parents=True)
            (target / "previous").write_text("old plugin")
            config = root / "config.yaml"
            config.write_text("untouched config\n")
            def enabled(argv, **kwargs):
                self.assertEqual(argv, ["/fixed/hermes", "--profile", "default", "plugins", "enable", "nollie-workflow"])
                self.assertFalse(json.loads((root / "nollie-workflow/state.json").read_text())["enabled"])
                self.assertTrue(kwargs["capture_output"])
                return SimpleNamespace(returncode=0)
            with patch.object(Path, "home", return_value=home), patch("sys.argv", ["install.py", "--apply", "--enable"]), \
                    patch.object(installer.shutil, "which", return_value="/fixed/hermes"), \
                    patch.object(installer.subprocess, "run", side_effect=enabled) as run, patch("builtins.print"):
                installer.main()
            self.assertEqual(config.read_text(), "untouched config\n")
            backup = next(root.glob("config.yaml.bak-nollie-workflow-*"))
            self.assertEqual(backup.read_bytes(), config.read_bytes())
            self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
            self.assertEqual(len(list((root / "plugin-backups").glob("*/previous"))), 1)
            self.assertTrue((target / "dashboard/plugin_api.py").exists())
            self.assertTrue((target / "hermes_support/nollie_board_observer.py").is_file())
            self.assertTrue((target / "hermes_support/ollie_cron_followups.py").is_file())
            self.assertEqual(list(source.iterdir()), [sentinel])
            self.assertEqual(sentinel.read_text(), "existing source stays untouched\n")
            run.assert_called_once()
            # A new setup: Night shift starts on, in night shift's own format.
            settings = json.loads((root / "nollie-workflow/night-shift.json").read_text())
            self.assertTrue(settings["night_shift"])
            self.assertEqual(night_shift.parse_settings(settings)["night_shift"], True)

    def test_upgrade_retains_cursor_outbox_and_install_boundary(self):
        with TemporaryDirectory() as temporary:
            home = Path(temporary)
            state_path = home / ".hermes/nollie-workflow/state.json"
            state_path.parent.mkdir(parents=True)
            state = {"version": 1, "enabled": True, "installed_at": 123, "cursors": {"default": {"task": 100}},
                     "outbox": {"receipt": {"status": "accepted"}}}
            state_path.write_text(json.dumps(state))
            with patch.object(Path, "home", return_value=home), patch("sys.argv", ["install.py", "--apply"]), \
                    patch("builtins.print"):
                installer.main()
            result = json.loads(state_path.read_text())
            self.assertEqual(result, state | {"enabled": False})
            self.assertTrue(list(state_path.parent.glob("state.json.bak-install-*")))
            self.assertFalse((home / ".hermes/hermes-agent").exists())
            # A setup made before that never chose keeps Night shift as it was: no file, off.
            self.assertFalse((state_path.parent / "night-shift.json").exists())

    def test_night_shift_starts_on_once_and_never_over_a_choice(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.assertTrue(workflow_core.start_night_shift(root))
            self.assertEqual(oct((root / "night-shift.json").stat().st_mode & 0o777), "0o600")
            night_shift.write_settings(root, night_shift=False)
            self.assertFalse(workflow_core.start_night_shift(root))
            self.assertFalse(night_shift.read_settings(root)["night_shift"])
            (root / "night-shift.json").unlink()
            (root / "night-shift.json").symlink_to(root / "elsewhere.json")
            self.assertFalse(workflow_core.start_night_shift(root))
            self.assertFalse((root / "elsewhere.json").exists())

    def test_private_main_bot_is_left_alone(self):
        with TemporaryDirectory() as temporary:
            home = Path(temporary)
            root = home / ".hermes"
            root.mkdir()
            config = root / "config.yaml"
            config.write_text("plugins: {enabled: [existing]}\n")
            (root / "nollie-private-bots.json").write_text(json.dumps({"version": 1, "profiles": ["default"]}))
            before = {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}
            with patch.object(Path, "home", return_value=home), \
                    patch("sys.argv", ["install.py", "--apply", "--enable", "--recorder"]), \
                    patch.object(installer.subprocess, "run") as run, patch("builtins.print"), \
                    self.assertRaisesRegex(SystemExit, "main bot is Private"):
                installer.main()
            self.assertEqual({path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}, before)
            self.assertFalse((root / "plugins").exists())
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
