import importlib.util
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("install_companion", Path(__file__).resolve().parents[1] / "install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallTests(unittest.TestCase):
    def test_files_only_keeps_config_and_preserves_backed_up_ownership(self):
        with TemporaryDirectory() as directory:
            home = Path(directory)
            owned = home / ".hermes/nollie-computer/owned-spaces.json"
            owned.parent.mkdir(parents=True)
            original = {"version": 1, "profiles": {"forager": "local:worker"}}
            owned.write_text(json.dumps(original))
            config = home / ".hermes/config.yaml"
            config.write_text("unchanged fixture\n")
            with patch.object(Path, "home", return_value=home), patch.object(installer.shutil, "which", return_value="/fixed/hermes"), \
                 patch.object(installer.subprocess, "run") as run, patch("builtins.print"), \
                 patch("sys.argv", ["install.py", "--apply", "--files-only", "--owned-space", "default=local:owned"]):
                installer.main()
            run.assert_not_called()
            self.assertEqual(config.read_text(), "unchanged fixture\n")
            self.assertEqual(json.loads(owned.read_text())["profiles"], {"default": "local:owned", "forager": "local:worker"})
            backup, = owned.parent.glob("owned-spaces.json.bak-*")
            self.assertEqual(json.loads(backup.read_text()), original)
            self.assertEqual(owned.stat().st_mode & 0o777, 0o600)

    def test_config_and_previous_plugin_are_backed_up_before_enable(self):
        with TemporaryDirectory() as directory:
            home = Path(directory)
            root = home / ".hermes"
            old_plugin = root / "plugins/nollie-computer"
            old_plugin.mkdir(parents=True)
            (old_plugin / "previous.txt").write_text("previous version")
            config = root / "config.yaml"
            config.write_text("plugins: {}\n")

            def enable(argv, **kwargs):
                backups = list(root.glob("config.yaml.bak-nollie-computer-*"))
                self.assertEqual(len(backups), 1)
                self.assertEqual(backups[0].read_bytes(), config.read_bytes())
                self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)
                self.assertEqual(len(list((root / "plugin-backups").glob("*/previous.txt"))), 1)
                self.assertTrue((old_plugin / "dashboard/plugin_api.py").exists())
                self.assertEqual(argv, ["/fixed/hermes", "--profile", "default", "plugins", "enable", "nollie-computer"])
                self.assertTrue(kwargs["capture_output"])
                return SimpleNamespace(returncode=0, stdout="Gateway reloaded plugins", stderr="")

            with patch.object(Path, "home", return_value=home), patch.object(installer.shutil, "which", return_value="/fixed/hermes"), \
                 patch.object(installer.subprocess, "run", side_effect=enable) as run, \
                 patch("sys.argv", ["install.py", "--apply"]), patch("builtins.print"):
                installer.main()
                run.assert_called_once()

    def test_owned_space_refuses_private_profiles_from_the_list(self):
        def install(home, *entries):
            argv = ["install.py", "--apply", "--files-only"]
            for entry in entries:
                argv += ["--owned-space", entry]
            with patch.object(Path, "home", return_value=home), patch.object(installer.shutil, "which", return_value="/fixed/hermes"), \
                 patch.object(installer.subprocess, "run"), patch("builtins.print"), patch("sys.argv", argv), \
                 patch("sys.stderr"):
                installer.main()
        with TemporaryDirectory() as directory:
            home = Path(directory)
            (home / ".hermes").mkdir()
            for refused in ("moss=local:a", "private=local:a", "Scout=local:a", "../x=local:a"):
                with self.assertRaises(SystemExit):
                    install(home, refused)
            self.assertFalse((home / ".hermes/plugins").exists())
            install(home, "scout=local:scout")
            owned = home / ".hermes/nollie-computer/owned-spaces.json"
            self.assertEqual(json.loads(owned.read_text())["profiles"], {"scout": "local:scout"})
            self.assertTrue((home / ".hermes/plugins/nollie-computer/dashboard/private_bots.py").is_file())
            (home / ".hermes/nollie-private-bots.json").write_text(json.dumps({"version": 1, "profiles": ["scout"]}))
            with self.assertRaises(SystemExit):
                install(home, "scout=local:scout")
            install(home, "moss=local:moss")
            self.assertEqual(json.loads(owned.read_text())["profiles"], {"scout": "local:scout", "moss": "local:moss"})
            (home / ".hermes/nollie-private-bots.json").write_text("{")
            with self.assertRaises(SystemExit):
                install(home, "default=local:a")

    def test_dry_run_never_writes_or_enables(self):
        with TemporaryDirectory() as directory:
            home = Path(directory)
            with patch.object(Path, "home", return_value=home), patch.object(installer.subprocess, "run") as run, \
                 patch("sys.argv", ["install.py"]), patch("builtins.print"):
                installer.main()
                self.assertFalse((home / ".hermes").exists())
                run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
