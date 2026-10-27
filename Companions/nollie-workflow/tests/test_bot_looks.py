import importlib.util
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest

ROOT = Path(__file__).resolve().parents[1]
NAME = "bot_looks_test_package"
spec = importlib.util.spec_from_file_location(NAME, ROOT / "__init__.py", submodule_search_locations=[str(ROOT)])
package = importlib.util.module_from_spec(spec)
sys.modules[NAME] = package
spec.loader.exec_module(package)
from bot_looks_test_package import bot_looks


class BotLooksTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.path = self.home / "nollie-bot-looks.json"

    def test_nothing_is_saved_until_a_look_is_chosen(self):
        self.assertEqual(bot_looks.read(self.home), ({}, False))
        self.assertFalse(self.path.exists())

    def test_one_bot_changes_without_touching_the_others(self):
        bot_looks.save(self.home, "Planner", {"look": "duo", "colour": "#aa3311"})
        bot_looks.save(self.home, "shopper", {"look": "swell"})
        self.assertEqual(bot_looks.read(self.home), ({"planner": {"look": "duo", "colour": "#AA3311"},
                                                      "shopper": {"look": "swell"}}, True))
        self.assertEqual(bot_looks.save(self.home, "planner", {"colour": "#00FF00"}),
                         {"planner": {"colour": "#00FF00"}, "shopper": {"look": "swell"}})
        self.assertEqual(bot_looks.save(self.home, "shopper", None), {"planner": {"colour": "#00FF00"}})
        self.assertEqual(bot_looks.save(self.home, "planner", {"look": None, "colour": None}), {})
        self.assertEqual(json.loads(self.path.read_text()), {"version": 1, "bots": {}})
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_names_looks_and_colours_are_checked(self):
        for profile, value in (("../x", {"look": "duo"}), ("two words", {"look": "duo"}), ("", {"look": "duo"}),
                               ("x", {"look": "Duo!"}), ("x", {"look": 3}), ("x", {"colour": "red"}),
                               ("x", {"colour": "#12345"}), ("x", {"look": "duo", "photo": "a.jpg"}), ("x", "duo")):
            with self.assertRaises(ValueError, msg=(profile, value)):
                bot_looks.save(self.home, profile, value)
        self.assertFalse(self.path.exists())
        for i in range(64):
            bot_looks.save(self.home, f"bot{i}", {"look": "kick"})
        with self.assertRaises(ValueError):
            bot_looks.save(self.home, "one-more", {"look": "kick"})

    def test_private_bots_are_left_out(self):
        bots = {"moss": {"look": "nite"}, "scout": {"look": "kick"}, "planner": {"look": "duo"}}
        self.assertEqual(bot_looks.visible(bots, frozenset({"scout"})), {"planner": {"look": "duo"}})

    def test_a_damaged_or_linked_file_is_refused(self):
        for text in ("{", '{"version": 2, "bots": {}}', '{"version": 1, "bots": []}',
                     '{"version": 1, "bots": {"Moss": {"look": "duo"}}}', '{"version": 1, "bots": {"x": {"look": "?"}}}'):
            self.path.write_text(text)
            with self.assertRaises(ValueError, msg=text):
                bot_looks.read(self.home)
        self.path.unlink()
        real = self.home / "elsewhere.json"
        real.write_text(json.dumps({"version": 1, "bots": {}}))
        self.path.symlink_to(real)
        with self.assertRaises(ValueError):
            bot_looks.read(self.home)


if __name__ == "__main__":
    unittest.main()
