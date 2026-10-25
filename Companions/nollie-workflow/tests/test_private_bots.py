import importlib.util
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest

ROOT = Path(__file__).resolve().parents[1]
NAME = "private_bots_test_package"
spec = importlib.util.spec_from_file_location(NAME, ROOT / "__init__.py", submodule_search_locations=[str(ROOT)])
package = importlib.util.module_from_spec(spec)
sys.modules[NAME] = package
spec.loader.exec_module(package)
from private_bots_test_package import private_bots


class PrivateListTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.path = self.home / "nollie-private-bots.json"

    def test_carry_over_counts_only_until_a_list_is_saved(self):
        self.assertEqual(private_bots.read(self.home), (frozenset({"private", "moss"}), False))
        self.assertFalse(self.path.exists())
        self.assertEqual(private_bots.save(self.home, []), [])
        self.assertEqual(private_bots.read(self.home), (frozenset(), True))

    def test_saved_list_is_lowercased_sorted_unique_and_private_to_the_user(self):
        self.assertEqual(private_bots.save(self.home, ["Scout", " moss ", "scout", "work_2"]),
                         ["moss", "scout", "work_2"])
        self.assertEqual(json.loads(self.path.read_text()), {"version": 1, "profiles": ["moss", "scout", "work_2"]})
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(private_bots.names(self.home), frozenset({"moss", "scout", "work_2"}))
        self.assertTrue((self.home / "nollie-private-bots.lock").exists())
        self.assertEqual(sorted(p.name for p in self.home.iterdir()),
                         ["nollie-private-bots.json", "nollie-private-bots.lock"])

    def test_names_must_be_hermes_profile_names_and_at_most_64(self):
        for bad in (["../moss"], ["-moss"], [""], ["a" * 65], ["two words"], [3], "moss", None, {"moss": 1}):
            with self.assertRaises(ValueError):
                private_bots.save(self.home, bad)
        with self.assertRaises(ValueError):
            private_bots.save(self.home, [f"bot{i}" for i in range(65)])
        self.assertEqual(len(private_bots.save(self.home, [f"bot{i}" for i in range(64)])), 64)
        self.assertEqual(private_bots.save(self.home, ["default", "0"]), ["0", "default"])

    def test_damaged_list_fails_closed_instead_of_falling_back(self):
        for text in ("{", '{"version": 2, "profiles": []}', '{"version": 1, "profiles": "moss"}',
                     '{"version": 1, "profiles": ["Moss"]}', '{"version": 1}', "[]"):
            self.path.write_text(text)
            with self.assertRaises(ValueError):
                private_bots.read(self.home)
        self.path.write_bytes(b"\xff\xfe")
        with self.assertRaises(ValueError):
            private_bots.read(self.home)
        self.path.write_text(json.dumps({"version": 1, "profiles": ["x" * 60] * 300}))
        with self.assertRaises(ValueError):
            private_bots.read(self.home)

    def test_linked_list_is_refused(self):
        real = self.home / "elsewhere.json"
        real.write_text(json.dumps({"version": 1, "profiles": []}))
        self.path.symlink_to(real)
        with self.assertRaises(ValueError):
            private_bots.read(self.home)


if __name__ == "__main__":
    unittest.main()
