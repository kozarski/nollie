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


class ScreenCaptureTests(unittest.TestCase):
    """Taking a picture of the screen from a bot's terminal or code is refused, never asked."""

    def refused(self, tool, args):
        decision = mac_screen.refuse(tool_name=tool, args=args)
        return decision == {"action": "block", "message": mac_screen.CAPTURE_MESSAGE}

    def test_screen_pictures_from_a_terminal_are_refused(self):
        for command in ["screencapture -x /tmp/shot.png", "/usr/sbin/screencapture -l 4242 -o w.png && open w.png",
                        "cd /tmp; SCREENCAPTURE -C x.png", "osascript -e 'do shell script \"screencapture -x s.png\"'",
                        "osascript -l JavaScript -e \"ObjC.import('CoreGraphics'); $.CGWindowListCreateImage($.CGRectInfinite, 1, 0, 0)\"",
                        "python3 -c 'import Quartz; Quartz.CGDisplayCreateImage(Quartz.CGMainDisplayID())'",
                        "python3 -c 'from PIL import ImageGrab; ImageGrab.grab().save(\"s.png\")'",
                        "python3 -c 'import pyautogui; pyautogui.screenshot(\"s.png\")'",
                        "swift -e 'import ScreenCaptureKit; SCScreenshotManager.captureImage(contentFilter: f, configuration: c)'",
                        "ffmpeg -f avfoundation -i 1 -frames:v 1 s.png", "peekaboo image --mode screen", "imagesnap shot.jpg",
                        "open -a Screenshot.app", "npx screenshot-desktop s.png"]:
            self.assertTrue(self.refused("terminal", {"command": command}), command)
        self.assertTrue(self.refused("process", {"action": "write", "data": "import mss\nmss.mss().shot()\n"}))

    def test_code_and_scripts_it_runs_are_read_too(self):
        self.assertTrue(self.refused("execute_code", {"code": "from mss import mss\nwith mss() as s: s.shot()"}))
        self.assertTrue(self.refused("execute_code", {"code": "import Quartz\nQuartz.CGWindowListCreateImage(r, 1, 0, 0)",
                                                      "language": "python"}))
        with TemporaryDirectory() as folder:
            script = Path(folder) / "grab.py"
            script.write_text("from PIL import ImageGrab\nImageGrab.grab()\n")
            self.assertTrue(self.refused("terminal", {"command": f"python3 {script}"}))
            self.assertTrue(self.refused("terminal", {"command": "python3 grab.py", "workdir": folder}))
            other = Path(folder) / "tidy.sh"
            other.write_text("ls ~/Downloads\n")
            self.assertFalse(self.refused("terminal", {"command": f"bash {other}"}))
        # Inside a wrapper that runs other tools.
        self.assertTrue(self.refused("tool_call", {"tool": "terminal", "arguments": {"command": "screencapture x.png"}}))

    def test_ordinary_commands_and_the_browsers_own_pictures_are_left_alone(self):
        for command in ["ls -la ~/Desktop", "grep -r screenshot notes.md", "echo screencaptures", "git log --oneline",
                        "python3 -c 'print(1)'", "open ~/Pictures/Screenshot-2026-10-27.png"]:
            self.assertFalse(self.refused("terminal", {"command": command}), command)
        self.assertFalse(self.refused("execute_code", {"code": "await page.screenshot(path='page.png')"}))
        for tool in ("browser_vision", "vision_analyze", "mcp__cua__computer_screenshot", "read_file"):
            self.assertIsNone(mac_screen.refuse(tool_name=tool, args={"command": "screencapture x.png"}))


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
