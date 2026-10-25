import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("reader_installer", Path(__file__).resolve().parents[1] / "install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def hermes_home(root):
    home = root / ".hermes"
    for name in ("career", "nowhere", "forager", "private"):
        (home / "profiles" / name).mkdir(parents=True)
        (home / "profiles" / name / "config.yaml").write_text(f"{name} config\n")
    (home / "config.yaml").write_text("default config\n")
    return home


class InstallTests(unittest.TestCase):
    def test_plan_writes_nothing(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            home = hermes_home(root)
            before = sorted(p.relative_to(root) for p in root.rglob("*"))
            with patch.object(Path, "home", return_value=root), patch("sys.argv", ["install.py"]), \
                    patch.object(installer.subprocess, "run") as run, patch("builtins.print"):
                installer.main()
            self.assertEqual(sorted(p.relative_to(root) for p in root.rglob("*")), before)
            run.assert_not_called()
            self.assertFalse((home / "nollie-reader").exists())

    def test_apply_installs_for_bots_but_never_the_private_one(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            home = hermes_home(root)
            old = home / "profiles" / "career" / "plugins" / "nollie-reader"
            old.mkdir(parents=True)
            (old / "previous").write_text("old copy")
            calls = []

            def run(argv, **kwargs):
                calls.append(argv)
                return SimpleNamespace(returncode=0)

            with patch.object(Path, "home", return_value=root), \
                    patch("sys.argv", ["install.py", "--apply", "--enable"]), \
                    patch.object(installer.shutil, "which", return_value="/fixed/hermes"), \
                    patch.object(installer.subprocess, "run", side_effect=run), patch("builtins.print"):
                installer.main()
            for profile in (home, *(home / "profiles" / n for n in ("career", "nowhere", "forager"))):
                plugin = profile / "plugins" / "nollie-reader"
                self.assertTrue((plugin / "plugin.yaml").is_file(), profile)
                self.assertTrue((plugin / "skills" / "reference-sources" / "SKILL.md").is_file())
                self.assertFalse((plugin / "tests").exists())
                backup = next(profile.glob("config.yaml.bak-nollie-reader-*"))
                self.assertEqual(backup.read_bytes(), (profile / "config.yaml").read_bytes())
                self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
            private = home / "profiles" / "private"
            self.assertEqual(sorted(p.name for p in private.iterdir()), ["config.yaml"])
            self.assertEqual((private / "config.yaml").read_text(), "private config\n")
            kept = list((home / "profiles" / "career" / "plugin-backups").glob("nollie-reader-*/previous"))
            self.assertEqual(len(kept), 1)
            self.assertEqual(sorted(c[2] for c in calls), ["career", "default", "forager", "nowhere"])
            self.assertTrue(all(c[3:] == ["plugins", "enable", "nollie-reader"] for c in calls))
            self.assertEqual((home / "nollie-reader").stat().st_mode & 0o777, 0o700)
            self.assertEqual((home / "config.yaml").read_text(), "default config\n")

    def test_extractor_environment_is_swapped_in_only_when_it_works(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            home = hermes_home(root)
            state = home / "nollie-reader"
            (state / "venv").mkdir(parents=True)
            (state / "venv" / "marker").write_text("old")

            def run(argv, **kwargs):
                if argv[1:3] == ["-m", "venv"]:
                    Path(argv[3], "bin").mkdir(parents=True)
                return SimpleNamespace(returncode=0)

            with patch.object(Path, "home", return_value=root), \
                    patch("sys.argv", ["install.py", "--apply", "--with-extractors", "--python", "/fixed/python3"]), \
                    patch.object(installer.subprocess, "run", side_effect=run) as fake, patch("builtins.print"):
                installer.main()
            pip = [c.args[0] for c in fake.call_args_list if "pip" in c.args[0]]
            self.assertIn("--only-binary", pip[0])
            self.assertTrue((state / "venv" / "bin").is_dir())
            self.assertEqual(next(state.glob("venv.bak-*")).joinpath("marker").read_text(), "old")

            def broken(argv, **kwargs):
                if argv[1:3] == ["-m", "venv"]:
                    Path(argv[3], "bin").mkdir(parents=True)
                return SimpleNamespace(returncode=1 if "-c" in argv else 0)

            with patch.object(Path, "home", return_value=root), \
                    patch("sys.argv", ["install.py", "--apply", "--with-extractors"]), \
                    patch.object(installer.subprocess, "run", side_effect=broken), patch("builtins.print"):
                with self.assertRaises(SystemExit):
                    installer.main()
            self.assertTrue((state / "venv" / "bin").is_dir())
            self.assertEqual(len(list(state.glob("venv.new-*"))), 0)


if __name__ == "__main__":
    unittest.main()
