"""Hermes's own computer_use never runs for a bot that is not private, and nothing it saw reaches the model."""
import importlib.util
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
NAME = "mac_screen_test_package"
spec = importlib.util.spec_from_file_location(NAME, ROOT / "__init__.py", submodule_search_locations=[str(ROOT)])
package = importlib.util.module_from_spec(spec)
sys.modules[NAME] = package
spec.loader.exec_module(package)
from mac_screen_test_package import mac_screen, private_bots


class MacScreenTests(unittest.TestCase):
    def test_computer_use_is_refused_whatever_it_asks(self):
        for args in ({"action": "capture", "mode": "som"}, {"action": "capture", "app": "screen"},
                     {"action": "click", "element": 3}, {"action": "list_apps"}, None):
            decision = mac_screen.refuse(tool_name="computer_use", args=args)
            self.assertEqual(decision, {"action": "block", "message": mac_screen.MESSAGE})
        self.assertIn("mac_do", mac_screen.MESSAGE)

    def test_other_tools_are_left_alone(self):
        for tool in ("mcp__cua__computer_screenshot", "mcp__nollie_mac__mac_do", "browser_navigate", "terminal",
                     "computer_use_extra", "", None):
            self.assertIsNone(mac_screen.refuse(tool_name=tool, args={}))
            self.assertIsNone(mac_screen.scrub(tool_name=tool, result="anything"))

    def test_a_result_that_got_through_is_replaced_and_its_picture_removed(self):
        with TemporaryDirectory() as temp:
            cache = Path(temp) / "cache" / "screenshots"
            cache.mkdir(parents=True)
            picture = cache / "shot.png"
            picture.write_bytes(b"png")
            constants = SimpleNamespace(get_hermes_home=lambda: temp)
            with patch.dict(sys.modules, {"hermes_constants": constants}):
                replaced = mac_screen.scrub(tool_name="computer_use", args={"action": "capture"},
                                            result='{"screenshot_path": "%s", "elements": "[1] Send"}' % picture)
            self.assertEqual(replaced, mac_screen.REPLACED)
            self.assertFalse(picture.exists())
            self.assertNotIn("Send", replaced)


class RegisterTests(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)

    def hooks(self, profile):
        found = []
        ctx = SimpleNamespace(register_hook=lambda name, fn: found.append((name, fn)))
        package._register_mac_screen(ctx, profile, self.home)
        return found

    def test_every_bot_that_is_not_private_gets_the_rule(self):
        for profile in ("default", "career", "nowhere"):
            names = [name for name, _ in self.hooks(profile)]
            self.assertEqual(names, ["pre_tool_call", "transform_tool_result"], profile)

    def test_a_private_bot_gets_nothing(self):
        for profile in ("private", "moss"):
            self.assertEqual(self.hooks(profile), [])
        private_bots.save(self.home, ["career"])
        self.assertEqual(self.hooks("career"), [])
        self.assertEqual(len(self.hooks("scout")), 2)

    def test_a_damaged_private_list_keeps_the_rule_on(self):
        (self.home / "nollie-private-bots.json").write_text("{")
        self.assertEqual(len(self.hooks("career")), 2)
        self.assertEqual(self.hooks("moss"), [])


if __name__ == "__main__":
    unittest.main()
