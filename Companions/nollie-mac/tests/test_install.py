import importlib.util
import io
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("nollie_mac_install", Path(__file__).resolve().parents[1] / "install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallTests(unittest.TestCase):
    def run_installer(self, argv, home, runs):
        def run(command, **_):
            runs.append(command)
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        with patch("sys.stdout", io.StringIO()) as out:
            code = installer.main(argv, home=home, run=run, which=lambda _: "/fixed/hermes")
        return code, out.getvalue()

    def test_plan_only_changes_nothing(self):
        with TemporaryDirectory() as home:
            runs = []
            code, out = self.run_installer(["--profile", "career"], home, runs)
            self.assertEqual(code, 0)
            self.assertIn("Plan only", out)
            self.assertIn("hermes --profile career mcp add nollie-mac", out)
            self.assertEqual(runs, [])
            self.assertFalse((Path(home) / ".hermes").exists())

    def test_apply_copies_backs_up_and_enables_for_that_bot_only(self):
        with TemporaryDirectory() as home:
            bot = Path(home) / ".hermes/profiles/career"
            old = bot / "plugins/nollie-mac"
            old.mkdir(parents=True)
            (old / "server.py").write_text("old")
            runs = []
            code, _ = self.run_installer(["--profile", "career", "--apply"], home, runs)
            self.assertEqual(code, 0)
            self.assertEqual(sorted(p.name for p in old.iterdir()), ["__init__.py", "plugin.yaml", "server.py"])
            backup, = (bot / "plugin-backups").iterdir()
            self.assertEqual((backup / "server.py").read_text(), "old")
            self.assertEqual(runs, [["/fixed/hermes", "--profile", "career", "plugins", "enable", "nollie-mac"]])
            self.assertFalse((Path(home) / ".hermes/plugins").exists())

    def test_refuses_odd_profile_names_and_missing_homes(self):
        with TemporaryDirectory() as home:
            with self.assertRaises(SystemExit), patch("sys.stderr", io.StringIO()):
                self.run_installer(["--profile", "../x"], home, [])
            runs = []
            with patch("sys.stderr", io.StringIO()):
                code, _ = self.run_installer(["--profile", "nobody", "--apply"], home, runs)
            self.assertEqual(code, 1)
            self.assertEqual(runs, [])


if __name__ == "__main__":
    unittest.main()
