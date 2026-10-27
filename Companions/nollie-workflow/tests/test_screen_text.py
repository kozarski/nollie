"""What is under a click, for Ask first: remembered captures and pages, a Cua computer's screen read by the
Mac's own text recognition, and the binding that reads each call's screen at most once."""
import base64
import json
import os
from pathlib import Path
import socket
import subprocess
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from night_support import load

screen_text = load("screen_text")
ask_first = load("ask_first")
UNREADABLE = ask_first.UNREADABLE

SUMMARY = "\n".join([
    "Captured Mail (3 elements):",
    "  #1 AXButton 'Send' @ (100, 200, 60, 24) [Mail]",
    "  #2 AXStatic Text \"Don't send yet\" @ [10, 20, 300, 40] [Mail]",
    "  #3 AXButton 'Say \\'hi\\'' @ bounds-unknown (click by element index)",
    "  #4 AXGroup 'Toolbar' @ (0, 0, 800, 60)",
])
SNAPSHOT = "\n".join([
    '- heading "Checkout" [level=1, ref=e1]',
    '- button "Buy now" [ref=e12]',
    '- button "Say \\"hi\\"" [ref=e3]',
    "- textbox [ref=e5]: Save",
    "- link [ref=e7]",
])


def multimodal(summary=SUMMARY, **meta):
    return {"_multimodal": True, "content": [{"type": "text", "text": summary}], "text_summary": summary,
            "meta": meta}


def text_capture(elements, **extra):
    return json.dumps({"elements": elements, **extra})


def page(snapshot=SNAPSHOT):
    return json.dumps({"snapshot": snapshot, "element_count": 5})


class CaptureElementsTests(unittest.TestCase):
    def test_multimodal_summary_lines(self):
        found = screen_text.capture_elements(multimodal(bounds_scale=2.0))
        self.assertEqual(found["scale"], 2.0)
        elements = found["elements"]
        self.assertEqual(elements[1], {"role": "AXButton", "label": "Send", "bounds": [100, 200, 60, 24]})
        # A role with a space, a label in double quotes holding a single one, and square brackets.
        self.assertEqual(elements[2], {"role": "AXStatic Text", "label": "Don't send yet", "bounds": [10, 20, 300, 40]})
        # Escaped quotes, and no bounds: clicked by index.
        self.assertEqual(elements[3], {"role": "AXButton", "label": "Say 'hi'", "bounds": None})
        self.assertEqual(elements[4]["label"], "Toolbar")
        self.assertEqual(len(elements), 4)

    def test_a_scale_that_is_not_a_number_is_dropped(self):
        self.assertIsNone(screen_text.capture_elements(multimodal(bounds_scale="2"))["scale"])

    def test_json_text_form(self):
        found = screen_text.capture_elements(text_capture(
            [{"index": 1, "role": "AXButton", "label": "Pay", "bounds": [5, 5, 50, 20], "app": "Safari"},
             {"index": "2", "role": "AXButton", "label": "Skipped"}, "junk"], bounds_scale=1.5))
        self.assertEqual(found, {"elements": {1: {"role": "AXButton", "label": "Pay", "bounds": [5, 5, 50, 20]}},
                                 "scale": 1.5})

    def test_capture_after_puts_the_actions_json_first(self):
        action = json.dumps({"ok": True, "action": "click"})
        capture = text_capture([{"index": 7, "role": "AXButton", "label": "Delete", "bounds": None}])
        found = screen_text.capture_elements(action + "\n\n" + capture)
        self.assertEqual(found["elements"][7]["label"], "Delete")

    def test_anything_else_is_not_a_capture(self):
        for value in (None, "", "not json", json.dumps({"ok": True}), json.dumps([1, 2]), "a\n\nb", 42):
            self.assertIsNone(screen_text.capture_elements(value), value)

    def test_a_spill_file_holds_the_whole_list(self):
        with TemporaryDirectory() as temp:
            spill = Path(temp) / "elements.json"
            spill.write_text(json.dumps({"elements": [
                {"index": 1, "role": "AXButton", "label": "Send", "bounds": [100, 200, 60, 24]},
                {"index": 55, "role": "AXButton", "label": "Post", "bounds": [0, 0, 10, 10]}]}))
            found = screen_text.capture_elements(multimodal(elements_file=str(spill)))
            self.assertEqual(sorted(found["elements"]), [1, 55])
            self.assertEqual(found["elements"][55]["label"], "Post")
            found = screen_text.capture_elements(text_capture([], elements_file=str(spill)))
            self.assertEqual(sorted(found["elements"]), [1, 55])
            # A link, a missing file or a damaged one leaves the summary as it was.
            link = Path(temp) / "link.json"
            link.symlink_to(spill)
            for path in (link, Path(temp) / "missing.json"):
                self.assertEqual(len(screen_text.capture_elements(multimodal(elements_file=str(path)))["elements"]), 4)
            spill.write_text("{")
            self.assertEqual(len(screen_text.capture_elements(multimodal(elements_file=str(spill)))["elements"]), 4)


class SnapshotRefsTests(unittest.TestCase):
    def test_names_by_ref(self):
        found = screen_text.snapshot_refs(page())
        self.assertEqual(found["refs"], {"e1": "Checkout", "e12": "Buy now", "e3": 'Say "hi"', "e5": "Save", "e7": ""})
        self.assertEqual(found["text"], SNAPSHOT)
        self.assertEqual(screen_text.snapshot_refs({"snapshot": SNAPSHOT})["refs"]["e12"], "Buy now")

    def test_anything_else_is_not_a_page(self):
        for value in (None, "", "not json", json.dumps({"snapshot": ""}), json.dumps({"other": 1}), json.dumps([1])):
            self.assertIsNone(screen_text.snapshot_refs(value), value)


class MemoryTests(unittest.TestCase):
    def capture(self, memory, session="s1", result=None, **args):
        memory.post_tool_call(tool_name="computer_use", args=dict({"action": "capture"}, **args),
                              result=multimodal() if result is None else result, session_id=session)

    def test_captures_are_kept_per_chat(self):
        memory = screen_text.Memory()
        self.capture(memory)
        self.assertEqual(memory.element("s1", {"element": 1})["label"], "Send")
        self.assertEqual(memory.element("s1", {"element": "3"})["label"], "Say 'hi'")
        self.assertIsNone(memory.element("s2", {"element": 1}))
        self.assertIsNone(memory.element("s1", {"element": 99}))
        self.assertIsNone(memory.element("s1", {"element": "x"}))
        self.assertIsNone(memory.element("s1", {}))
        self.assertIn("Send", memory.capture_text("s1"))
        self.assertIsNone(memory.capture_text("s2"))

    def test_an_action_with_capture_after_replaces_the_capture(self):
        memory = screen_text.Memory()
        self.capture(memory)
        after = json.dumps({"ok": True}) + "\n\n" + text_capture([{"index": 1, "role": "AXButton", "label": "Pay",
                                                                    "bounds": None}])
        memory.post_tool_call(tool_name="computer_use", args={"action": "click", "element": 1, "capture_after": True},
                              result=after, session_id="s1")
        self.assertEqual(memory.element("s1", {"element": 1})["label"], "Pay")
        # A capture_after whose result can't be read leaves nothing to trust: the screen moved on.
        memory.post_tool_call(tool_name="computer_use", args={"action": "click", "element": 1, "capture_after": True},
                              result="{}", session_id="s1")
        self.assertIsNone(memory.element("s1", {"element": 1}))

    def test_an_action_on_the_screen_forgets_the_capture(self):
        memory = screen_text.Memory()
        for action in ("click", "double_click", "type", "key", "scroll", "drag", "move", "something_new"):
            self.capture(memory)
            self.capture(memory, session="s2")
            memory.post_tool_call(tool_name="computer_use", args={"action": action, "element": 1}, result="{}",
                                  session_id="s1")
            # The next click is read afresh or asks.
            self.assertIsNone(memory.element("s1", {"element": 1}), action)
            self.assertIsNone(memory.capture_text("s1"), action)
            # Another chat's capture is its own.
            self.assertEqual(memory.element("s2", {"element": 1})["label"], "Send", action)

    def test_looking_without_acting_keeps_the_capture(self):
        memory = screen_text.Memory()
        self.capture(memory)
        for action in ("list_apps", "list_windows", "wait"):
            memory.post_tool_call(tool_name="computer_use", args={"action": action}, result="{}", session_id="s1")
            self.assertEqual(memory.element("s1", {"element": 1})["label"], "Send", action)
        # Other tools leave it alone too.
        memory.post_tool_call(tool_name="web_search", args={"query": "x"}, result="{}", session_id="s1")
        self.assertEqual(memory.element("s1", {"element": 1})["label"], "Send")

    def test_acting_on_a_page_forgets_its_snapshot(self):
        memory = screen_text.Memory()
        for tool in ("browser_click", "browser_press", "browser_type", "browser_console", "browser_exec",
                     "browser_cdp", "browser_dialog", "browser_back"):
            memory.post_tool_call(tool_name="browser_snapshot", args={}, result=page(), task_id="t1")
            memory.post_tool_call(tool_name="browser_snapshot", args={}, result=page(), task_id="t2")
            memory.post_tool_call(tool_name=tool, args={"ref": "e12"}, result="{}", task_id="t1")
            self.assertIsNone(memory.page("t1"), tool)
            self.assertIsNotNone(memory.page("t2"), tool)
        # Scrolling or looking keeps it.
        memory.post_tool_call(tool_name="browser_snapshot", args={}, result=page(), task_id="t1")
        for tool in ("browser_scroll", "browser_vision", "browser_get_images"):
            memory.post_tool_call(tool_name=tool, args={}, result="{}", task_id="t1")
            self.assertIsNotNone(memory.page("t1"), tool)

    def test_focusing_another_app_forgets_the_capture(self):
        memory = screen_text.Memory()
        for action in ("focus_app", "launch_app"):
            self.capture(memory)
            memory.post_tool_call(tool_name="computer_use", args={"action": action, "app": "Mail"}, result="{}",
                                  session_id="s1")
            self.assertIsNone(memory.element("s1", {"element": 1}), action)

    def test_coordinates_use_the_bounds_scale_and_the_smallest_element(self):
        memory = screen_text.Memory()
        self.capture(memory)
        self.assertEqual(memory.element("s1", {"coordinate": [110, 210]})["label"], "Send")
        self.assertEqual(memory.element("s1", {"coordinate": [500, 30]})["label"], "Toolbar")
        self.assertIsNone(memory.element("s1", {"coordinate": [900, 900]}))
        self.assertIsNone(memory.element("s1", {"coordinate": ["a", 1]}))
        self.assertIsNone(memory.element("s1", {"coordinate": [1]}))
        # Native bounds are twice the screenshot's pixels.
        self.capture(memory, result=multimodal(bounds_scale=2.0))
        self.assertEqual(memory.element("s1", {"coordinate": [55, 105]})["label"], "Send")
        self.assertNotEqual((memory.element("s1", {"coordinate": [110, 210]}) or {}).get("label"), "Send")

    def test_pages_are_kept_per_task(self):
        memory = screen_text.Memory()
        memory.post_tool_call(tool_name="browser_snapshot", args={}, result=page(), task_id="t1")
        self.assertEqual(memory.page("t1")["refs"]["e12"], "Buy now")
        self.assertIsNone(memory.page("t2"))
        memory.post_tool_call(tool_name="browser_snapshot", args={}, result=page(), task_id=None)
        self.assertIsNotNone(memory.page(None))
        self.assertIsNotNone(memory.page("default"))

    def test_navigating_keeps_its_snapshot_and_forgets_without_one(self):
        memory = screen_text.Memory()
        memory.post_tool_call(tool_name="browser_navigate", args={"url": "https://a.example"},
                              result=page('- button "Delete" [ref=e2]'), task_id="t1")
        self.assertEqual(memory.page("t1")["refs"], {"e2": "Delete"})
        memory.post_tool_call(tool_name="browser_navigate", args={"url": "https://b.example"},
                              result=json.dumps({"success": True}), task_id="t1")
        self.assertIsNone(memory.page("t1"))
        memory.post_tool_call(tool_name="browser_snapshot", args={}, result=page(), task_id="t1")
        memory.post_tool_call(tool_name="browser_back", args={}, result="{}", task_id="t1")
        self.assertIsNone(memory.page("t1"))
        # A snapshot that can't be read leaves the last page.
        memory.post_tool_call(tool_name="browser_snapshot", args={}, result=page(), task_id="t1")
        memory.post_tool_call(tool_name="browser_snapshot", args={}, result="garbage", task_id="t1")
        self.assertIsNotNone(memory.page("t1"))

    def test_memory_is_bounded(self):
        memory = screen_text.Memory(limit=2)
        for session in ("a", "b", "c"):
            self.capture(memory, session)
        self.assertIsNone(memory.element("a", {"element": 1}))
        self.assertIsNotNone(memory.element("c", {"element": 1}))
        # Seen again, a chat moves to the back of the line.
        self.capture(memory, "b")
        self.capture(memory, "d")
        self.assertIsNotNone(memory.element("b", {"element": 1}))
        self.assertIsNone(memory.element("c", {"element": 1}))
        for task in ("a", "b", "c"):
            memory.post_tool_call(tool_name="browser_snapshot", args={}, result=page(), task_id=task)
        self.assertEqual(len(memory.pages), 2)

    def test_the_hook_never_raises_and_returns_nothing(self):
        memory = screen_text.Memory()
        for args in (None, "x", {"action": "capture"}):
            self.assertIsNone(memory.post_tool_call(tool_name="computer_use", args=args, result=object()))
        self.assertIsNone(memory.post_tool_call())


class TextAtTests(unittest.TestCase):
    WORDS = [{"text": "Send", "x": 100, "y": 200, "w": 40, "h": 20},
             {"text": "Cancel", "x": 150, "y": 200, "w": 50, "h": 20}]

    def test_inside_and_within_reach(self):
        self.assertEqual(screen_text.text_at(self.WORDS, 120, 210), "Send")
        self.assertEqual(screen_text.text_at(self.WORDS, 100 - screen_text.REACH, 210), "Send")
        self.assertIsNone(screen_text.text_at(self.WORDS, 100 - screen_text.REACH - 1, 210))
        self.assertIsNone(screen_text.text_at(self.WORDS, 120, 300))
        self.assertIsNone(screen_text.text_at([], 1, 1))

    def test_nearest_wins_where_reaches_overlap(self):
        # Between the two words (140 to 150) both reach; the nearer centre wins.
        self.assertEqual(screen_text.text_at(self.WORDS, 141, 210), "Send")
        self.assertEqual(screen_text.text_at(self.WORDS, 149, 210), "Cancel")


class ReadTextTests(unittest.TestCase):
    def read(self, stdout=None, error=None):
        seen = {}

        def run(command, **kwargs):
            path = Path(command[-1])
            seen.update(command=command, kwargs=kwargs, path=path, existed=path.is_file(),
                        mode=path.stat().st_mode & 0o777, data=path.read_bytes())
            if error:
                raise error
            return SimpleNamespace(stdout=stdout, returncode=0)
        return screen_text.read_text(b"png bytes", run=run), seen

    def test_words_with_boxes(self):
        items = [{"text": "Send", "x": 1, "y": 2, "w": 3, "h": 4}, {"text": 7, "x": 1, "y": 2, "w": 3, "h": 4},
                 {"text": "No box", "x": 1}, "junk"]
        words, seen = self.read(json.dumps({"width": 10, "height": 10, "items": items}))
        self.assertEqual(words, [items[0]])
        self.assertEqual(seen["command"][:4], ["/usr/bin/osascript", "-l", "JavaScript", str(screen_text.OCR_SCRIPT)])
        self.assertEqual(seen["kwargs"]["timeout"], screen_text.READ_SECONDS)
        self.assertTrue(seen["existed"])
        self.assertEqual((seen["mode"], seen["data"]), (0o600, b"png bytes"))
        # The picture is gone once it is read.
        self.assertFalse(seen["path"].exists())
        self.assertFalse(seen["path"].parent.exists())

    def test_a_failed_reading_is_none_and_leaves_no_picture(self):
        for stdout, error in ((json.dumps({"items": []}), None), (json.dumps({"error": "recognition failed"}), None),
                              ("garbage", None), (json.dumps([1]), None), (json.dumps({"items": "x"}), None),
                              (None, subprocess.TimeoutExpired("osascript", 8)), (None, OSError("gone"))):
            with self.subTest(stdout=stdout, error=error):
                words, seen = self.read(stdout, error)
                self.assertIsNone(words)
                self.assertFalse(seen["path"].exists())

    def test_nothing_to_read(self):
        def run(*_, **__):
            raise AssertionError("ran without a picture")
        self.assertIsNone(screen_text.read_text(b"", run=run))
        self.assertIsNone(screen_text.read_text(None, run=run))


class FakeCua:
    """Cua's MCP server on stdio: answers initialize and one screenshot call as told."""

    def __init__(self, screenshot):
        self.screenshot = screenshot
        self.commands, self.envs, self.requests = [], [], []
        self.killed = False

    def __call__(self, command, **kwargs):
        self.commands.append(command)
        self.envs.append(kwargs.get("env"))
        replies = []
        fake = self

        class Input:
            def write(self, text):
                message = json.loads(text)
                fake.requests.append(message)
                if message.get("id") == 1:
                    replies.append(json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"capabilities": {}}}) + "\n")
                elif message.get("id") == 2:
                    replies.append("not json\n")
                    replies.append(json.dumps({"jsonrpc": "2.0", "method": "notifications/progress"}) + "\n")
                    replies.append(json.dumps({"jsonrpc": "2.0", "id": 2, "result": fake.screenshot}) + "\n")

            def flush(self):
                pass

        class Output:
            def readline(self):
                return replies.pop(0) if replies else ""

        def kill():
            fake.killed = True
        return SimpleNamespace(stdin=Input(), stdout=Output(), kill=kill, wait=lambda timeout=None: 0)


class CaptureSpaceTests(unittest.TestCase):
    def setUp(self):
        # A short folder: a Unix socket's path has a small limit.
        temp = TemporaryDirectory(prefix="nst", dir="/tmp")
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        (self.home / ".cua").mkdir()
        self.cli = self.home / "Apps" / screen_text.CUA_TOOL
        self.cli.parent.mkdir(parents=True)
        self.cli.write_text("#!/bin/sh\n")
        self.cli.chmod(0o700)
        self.environ = {"NOLLIE_CUA_CLI": str(self.cli), "PATH": "/usr/bin", "HOME": "/elsewhere"}
        patcher = patch.object(screen_text, "account_home", return_value=self.home)
        patcher.start()
        self.addCleanup(patcher.stop)

    def listen(self):
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(self.home / ".cua" / "cua.sock"))
        self.addCleanup(server.close)

    def test_the_picture_from_cuas_screenshot(self):
        self.listen()
        png = b"\x89PNG\r\n\x1a\nframe"
        cua = FakeCua({"content": [{"type": "text", "text": "ok"},
                                   {"type": "image", "mimeType": "image/png", "data": base64.b64encode(png).decode()}]})
        self.assertEqual(screen_text.capture_space("local:dev", environ=self.environ, run=cua), png)
        [command] = cua.commands
        self.assertEqual(command, [str(self.cli), "--daemon", str(self.home / ".cua" / "cua.sock"), "mcp",
                                   "--permissions", "computer:screenshot"])
        # Cua lives in the person's own home, not the private one Hermes runs with.
        self.assertEqual((cua.envs[0]["HOME"], cua.envs[0]["CUA_TELEMETRY"]), (str(self.home), "0"))
        call = cua.requests[-1]
        self.assertEqual((call["method"], call["params"]), ("tools/call", {"name": "computer_screenshot",
                                                                          "arguments": {"sandbox": "local:dev"}}))
        self.assertTrue(cua.killed)

    def test_an_error_or_no_picture_is_none(self):
        self.listen()
        for answer in ({"isError": True, "content": [{"type": "image", "data": "AAAA"}]},
                       {"content": [{"type": "text", "text": "no picture"}]}, None, "x"):
            cua = FakeCua(answer)
            self.assertIsNone(screen_text.capture_space("local:dev", environ=self.environ, run=cua), answer)
            self.assertTrue(cua.killed)

    def test_too_big_a_picture_is_none(self):
        self.listen()
        cua = FakeCua({"content": [{"type": "image", "data": "AAAA"}]})
        with patch.object(screen_text, "MAX_IMAGE", 2):
            self.assertIsNone(screen_text.capture_space("local:dev", environ=self.environ, run=cua))

    def test_no_socket_or_no_cua_never_starts_anything(self):
        def run(*_, **__):
            raise AssertionError("started Cua")
        self.assertIsNone(screen_text.capture_space("local:dev", environ=self.environ, run=run))
        (self.home / ".cua" / "cua.sock").write_text("not a socket")
        self.assertIsNone(screen_text.capture_space("local:dev", environ=self.environ, run=run))
        (self.home / ".cua" / "cua.sock").unlink()
        self.listen()
        with patch.object(screen_text, "find_cua", return_value=None):
            self.assertIsNone(screen_text.capture_space("local:dev", environ=self.environ, run=run))


class FindCuaTests(unittest.TestCase):
    def find(self, executable, environ=None, which=None, home="/Users/someone"):
        executable = {str(p) for p in executable}
        with patch.object(screen_text.os, "access", side_effect=lambda path, mode: str(path) in executable), \
                patch.object(screen_text.shutil, "which", return_value=which):
            return screen_text.find_cua(home, environ or {})

    def test_the_order(self):
        home = Path("/Users/someone")
        apps = "/Applications/" + screen_text.CUA_TOOL
        mine = home / "Applications" / screen_text.CUA_TOOL
        nollie = home / "Library/Application Support/Nollie/Cua" / screen_text.CUA_TOOL
        local = home / ".local/bin/cua"
        order = [apps, mine, nollie, "/found/on/path/cua", local, "/opt/homebrew/bin/cua", "/usr/local/bin/cua"]
        for index, expected in enumerate(order):
            self.assertEqual(self.find(order[index:], which="/found/on/path/cua"), str(expected), expected)
        self.assertIsNone(self.find([]))

    def test_a_named_cli_must_be_cuas_own_app(self):
        good = "/Volumes/Apps/" + screen_text.CUA_TOOL
        apps = "/Applications/" + screen_text.CUA_TOOL
        self.assertEqual(self.find([good, apps], {"NOLLIE_CUA_CLI": good}), good)
        for named in ("/tmp/evil/cua", "Volumes/" + screen_text.CUA_TOOL, "/x/../" + screen_text.CUA_TOOL,
                      "/Volumes/Apps/Cua Spaces.app/Contents/MacOS/cua-other", ""):
            self.assertEqual(self.find([named, apps], {"NOLLIE_CUA_CLI": named}), apps, named)

    def test_a_folder_is_not_a_program(self):
        with TemporaryDirectory() as temp:
            folder = Path(temp) / ".local/bin/cua"
            folder.mkdir(parents=True)
            self.assertIsNone(self.find([folder], home=temp))


class OwnedSpaceTests(unittest.TestCase):
    def test_only_a_qualified_record_for_a_plain_profile(self):
        with TemporaryDirectory() as temp:
            path = Path(temp) / "nollie-computer" / "owned-spaces.json"
            path.parent.mkdir()
            path.write_text(json.dumps({"version": 1, "profiles": {
                "career": "local:scout", "forager": "cloud:worker", "nowhere": "bare", "default": "direct:x"}}))
            self.assertEqual(screen_text.owned_space(temp, "career"), "local:scout")
            self.assertEqual(screen_text.owned_space(temp, "forager"), "cloud:worker")
            for profile in ("nowhere", "default", "unknown", "../career", "Career", None):
                self.assertIsNone(screen_text.owned_space(temp, profile), profile)
            path.write_text(json.dumps({"version": 2, "profiles": {"career": "local:scout"}}))
            self.assertIsNone(screen_text.owned_space(temp, "career"))
            path.write_text("{")
            self.assertIsNone(screen_text.owned_space(temp, "career"))
            path.write_text(json.dumps({"version": 1, "profiles": {"career": "local:scout"}, "pad": "x" * 17000}))
            self.assertIsNone(screen_text.owned_space(temp, "career"))
            real = Path(temp) / "real.json"
            real.write_text(json.dumps({"version": 1, "profiles": {"career": "local:scout"}}))
            path.unlink()
            path.symlink_to(real)
            self.assertIsNone(screen_text.owned_space(temp, "career"))
            self.assertIsNone(screen_text.owned_space(Path(temp) / "missing", "career"))


class HermesScreenTests(unittest.TestCase):
    WORDS = [{"text": "Send", "x": 100, "y": 200, "w": 40, "h": 20},
             {"text": "Inbox", "x": 10, "y": 10, "w": 40, "h": 20}]

    def screen(self, image=b"png", words=None, default=None, memory=None):
        self.captured, self.read = [], []

        def capture(sandbox):
            self.captured.append(sandbox)
            if isinstance(image, Exception):
                raise image
            return image

        def read(picture):
            self.read.append(picture)
            return self.WORDS if words is None else words
        return screen_text.HermesScreen(memory, capture=capture, read=read, default_space=lambda: default)

    def click(self, **args):
        return dict({"sandbox": "local:dev", "x": 110, "y": 210}, **args)

    def test_a_space_click_reads_the_label_under_it(self):
        screen = self.screen()
        self.assertEqual(screen.label_at("mcp__cua__computer_click", self.click()), "Send")
        self.assertEqual(self.captured, ["local:dev"])
        self.assertEqual(self.read, [b"png"])
        self.assertEqual(screen.label_at("mcp__cua__computer_click", self.click(x=500, y=500)), "")
        self.assertEqual(screen.text("mcp__cua__computer_key", {"sandbox": "local:dev"}), "Send Inbox")

    def test_a_screen_that_cant_be_read_is_unreadable(self):
        for image, words in ((None, None), (b"", None), (b"png", []), (RuntimeError("cua"), None)):
            screen = self.screen(image, words)
            self.assertIs(screen.label_at("mcp__cua__computer_click", self.click()), UNREADABLE, image)
            self.assertIs(screen.text("mcp__cua__computer_key", {"sandbox": "local:dev"}), UNREADABLE, image)
        screen = self.screen(words=None)
        screen.read = lambda picture: (_ for _ in ()).throw(ValueError("vision"))
        self.assertIs(screen.label_at("mcp__cua__computer_click", self.click()), UNREADABLE)

    def test_a_click_without_a_point_is_unreadable_and_captures_nothing(self):
        screen = self.screen()
        for args in ({"sandbox": "local:dev"}, self.click(x="110"), self.click(x=True), self.click(y=None)):
            self.assertIs(screen.label_at("mcp__cua__computer_click", args), UNREADABLE, args)
        self.assertEqual(self.captured, [])

    def test_one_call_captures_at_most_once(self):
        screen = self.screen()
        bound = screen.bind("task", "chat")
        self.assertEqual(bound.label_at("mcp__cua__computer_click", self.click()), "Send")
        self.assertEqual(bound.text("mcp__cua__computer_click", self.click()), "Send Inbox")
        self.assertEqual(bound.label_at("mcp__cua__computer_click", self.click()), "Send")
        self.assertEqual(len(self.captured), 1)
        # A failed look is remembered too: no second try within the call.
        screen = self.screen(image=None)
        bound = screen.bind("task", "chat")
        bound.label_at("mcp__cua__computer_click", self.click())
        bound.text("mcp__cua__computer_click", self.click())
        self.assertEqual(len(self.captured), 1)
        # Each call is bound afresh.
        screen = self.screen()
        screen.bind().label_at("mcp__cua__computer_click", self.click())
        screen.bind().label_at("mcp__cua__computer_click", self.click())
        self.assertEqual(len(self.captured), 2)

    def test_a_call_naming_no_computer_uses_the_bots_own(self):
        screen = self.screen(default="local:own")
        for args in ({"x": 110, "y": 210}, self.click(sandbox="../etc"), self.click(sandbox=7)):
            self.assertEqual(screen.label_at("mcp__cua__computer_click", args), "Send")
        self.assertEqual(self.captured, ["local:own"] * 3)
        self.assertEqual(screen.label_at("mcp__cua__computer_click", self.click(sandbox="dev")), "Send")
        self.assertEqual(screen.label_at("mcp__cua__computer_click", {"space": "cloud:w", "x": 110, "y": 210}), "Send")
        self.assertEqual(self.captured[-2:], ["dev", "cloud:w"])
        screen = self.screen(default=None)
        self.assertIs(screen.label_at("mcp__cua__computer_click", {"x": 110, "y": 210}), UNREADABLE)
        self.assertEqual(self.captured, [])

    def test_this_mac_reads_the_chats_latest_capture(self):
        memory = screen_text.Memory()
        memory.post_tool_call(tool_name="computer_use", args={"action": "capture"}, result=multimodal(),
                              session_id="chat")
        screen = self.screen(memory=memory)
        bound = screen.bind("task", "chat")
        self.assertEqual(bound.label_at("computer_use", {"action": "click", "element": 1}), "Send")
        self.assertEqual(bound.label_at("computer_use", {"action": "click", "coordinate": [110, 210]}), "Send")
        self.assertIs(bound.label_at("computer_use", {"action": "click", "element": 42}), UNREADABLE)
        self.assertIn("Toolbar", bound.text("computer_use", {"action": "key", "keys": "return"}))
        other = screen.bind("task", "other-chat")
        self.assertIs(other.label_at("computer_use", {"action": "click", "element": 1}), UNREADABLE)
        self.assertIs(other.text("computer_use", {"action": "key"}), UNREADABLE)
        self.assertEqual(self.captured, [])

    def test_the_browser_reads_the_tasks_latest_page(self):
        memory = screen_text.Memory()
        memory.post_tool_call(tool_name="browser_snapshot", args={}, result=page(), task_id="task")
        screen = self.screen(memory=memory)
        bound = screen.bind("task", "chat")
        self.assertEqual(bound.label_at("browser_click", {"ref": "@e12"}), "Buy now")
        self.assertEqual(bound.label_at("browser_click", {"ref": "e7"}), "")
        for ref in ("e99", "", None, "@e1x"):
            self.assertIs(bound.label_at("browser_click", {"ref": ref}), UNREADABLE, ref)
        self.assertEqual(bound.text("browser_press", {"key": "Enter"}), SNAPSHOT)
        other = screen.bind("other-task", "chat")
        self.assertIs(other.label_at("browser_click", {"ref": "e12"}), UNREADABLE)
        self.assertIs(other.text("browser_press", {"key": "Enter"}), UNREADABLE)

    def test_anything_else_is_unreadable(self):
        screen = self.screen()
        self.assertIs(screen.label_at("terminal", {}), UNREADABLE)
        self.assertIs(screen.text("terminal", {}), UNREADABLE)
        self.assertEqual(self.captured, [])

    def test_ask_first_shows_the_label_it_read(self):
        screen = self.screen()
        rule = ask_first.AskFirst(unattended=lambda: False, bypassed=lambda session=None: False, screen=screen)
        answer = rule.hook(tool_name="mcp__cua__computer_click", args=self.click(), task_id="task", session_id="chat")
        self.assertEqual(answer["action"], "approve")
        self.assertTrue(answer["message"].endswith("You're about to press “Send”."), answer["message"])
        self.assertEqual(len(self.captured), 1)
        # Somewhere plain runs without asking.
        self.assertIsNone(rule.hook(tool_name="mcp__cua__computer_click", args=self.click(x=20, y=20),
                                    task_id="task", session_id="chat"))



DIALOG_PAGE = "\n".join([
    '- heading "Photos" [level=1, ref=e1]',
    '- button "Share" [ref=e2]',
    '- dialog "Are you sure?" [ref=e3]:',
    '  - text: Delete 3 photos? This can\'t be undone.',
    '  - button "Cancel" [ref=e4]',
    '  - button "OK" [ref=e5]',
    '- link "Help" [ref=e6]',
])


class AroundTests(unittest.TestCase):
    """The words around an OK or Continue button, and the page's own forms."""

    def test_a_dialog_holds_the_button(self):
        near = screen_text.snapshot_around(DIALOG_PAGE, "e5")
        self.assertIn("Delete 3 photos?", near)
        self.assertNotIn("Share", near)
        self.assertNotIn("Help", near)
        # Without a dialog or form, the lines next to it.
        lines = "\n".join([f'- text: line {i}' for i in range(40)] + ['- button "OK" [ref=e9]'])
        near = screen_text.snapshot_around(lines, "e9")
        self.assertIn("line 39", near)
        self.assertNotIn("line 10\n", near + "\n")
        self.assertIsNone(screen_text.snapshot_around(lines, "e77"))

    def test_roles_and_the_address_are_remembered(self):
        found = screen_text.snapshot_refs(json.dumps({"snapshot": DIALOG_PAGE, "url": "https://x.example/p"}))
        self.assertEqual(found["roles"]["e5"], "button")
        self.assertEqual(found["url"], "https://x.example/p")
        memory = screen_text.Memory()
        memory.post_tool_call(tool_name="browser_navigate", args={}, task_id="t",
                              result=json.dumps({"snapshot": SNAPSHOT, "url": "https://shop.example/checkout"}))
        memory.post_tool_call(tool_name="browser_snapshot", args={}, task_id="t", result=page(DIALOG_PAGE))
        self.assertEqual(memory.page("t")["url"], "https://shop.example/checkout")

    def test_near_a_click_on_this_mac(self):
        summary = "\n".join([
            "Captured Finder (4 elements):",
            "  #1 AXSheet 'Move to Bin?' @ (300, 200, 400, 160)",
            "  #2 AXStaticText 'The items will be deleted' @ (320, 240, 300, 20)",
            "  #3 AXButton 'OK' @ (600, 320, 60, 24)",
            "  #4 AXStaticText 'Far away' @ (1500, 1200, 80, 20)",
        ])
        memory = screen_text.Memory()
        memory.post_tool_call(tool_name="computer_use", args={"action": "capture"}, result=multimodal(summary),
                              session_id="c")
        near = memory.near("c", {"element": 3})
        self.assertIn("Move to Bin?", near)
        self.assertIn("The items will be deleted", near)
        self.assertNotIn("Far away", near)
        self.assertIs(memory.near("c", {"element": 99}), UNREADABLE)
        self.assertIs(memory.near("other", {"element": 3}), UNREADABLE)

    def test_near_a_click_on_a_cua_computer(self):
        words = [{"text": "Pay £24.00?", "x": 400, "y": 300, "w": 120, "h": 20},
                 {"text": "Continue", "x": 420, "y": 360, "w": 80, "h": 20},
                 {"text": "Delete", "x": 1500, "y": 1000, "w": 60, "h": 20}]
        screen = screen_text.HermesScreen(capture=lambda sandbox: b"png", read=lambda image: words)
        near = screen.around("mcp__cua__computer_click", {"sandbox": "local:dev", "x": 460, "y": 370})
        self.assertIn("Pay £24.00?", near)
        self.assertNotIn("Delete", near)
        rule = ask_first.AskFirst(unattended=lambda: False, bypassed=lambda *_: False, screen=screen)
        answer = rule.hook(tool_name="mcp__cua__computer_click", args={"sandbox": "local:dev", "x": 460, "y": 370})
        self.assertRegex(answer["rule_key"], r"^nollie-ask-first:buy:")
        self.assertTrue(answer["message"].endswith("You're about to press “Continue”."))
        broken = screen_text.HermesScreen(capture=lambda sandbox: None, read=lambda image: words)
        self.assertIs(broken.around("mcp__cua__computer_click", {"sandbox": "local:dev", "x": 1, "y": 2}), UNREADABLE)

    def test_an_ok_in_a_page_dialog_asks(self):
        memory = screen_text.Memory()
        memory.post_tool_call(tool_name="browser_snapshot", args={}, result=page(DIALOG_PAGE), task_id="t")
        asked = []
        screen = screen_text.HermesScreen(memory, page=lambda task, label: asked.append((task, label)) or
                                          {"url": "https://photos.example/", "forms": []})
        rule = ask_first.AskFirst(unattended=lambda: False, bypassed=lambda *_: False, screen=screen)
        answer = rule.hook(tool_name="browser_click", args={"ref": "@e5"}, task_id="t", session_id="c")
        self.assertRegex(answer["rule_key"], r"^nollie-ask-first:delete:")
        self.assertIn("Delete 3 photos?", answer["message"])
        self.assertEqual(asked, [("t", "OK")])
        # A link is not a form's button: the page isn't asked.
        self.assertIsNone(rule.hook(tool_name="browser_click", args={"ref": "@e6"}, task_id="t", session_id="c"))
        self.assertEqual(len(asked), 1)

    def test_the_page_names_the_form(self):
        memory = screen_text.Memory()
        memory.post_tool_call(tool_name="browser_navigate", args={}, task_id="t", result=json.dumps({
            "snapshot": '- button "View details" [ref=e8]', "url": "https://shop.example/basket"}))
        screen = screen_text.HermesScreen(memory, page=lambda task, label: {
            "url": "https://shop.example/basket",
            "forms": [{"action": "https://shop.example/checkout/complete", "method": "post"}]})
        found = ask_first.classify("browser_click", {"ref": "e8"}, screen=screen.bind("t", "c"))
        self.assertEqual(found.kind, "buy")
        unreadable = screen_text.HermesScreen(memory, page=lambda task, label: None)
        self.assertIsNone(ask_first.classify("browser_click", {"ref": "e8"}, screen=unreadable.bind("t", "c")))

    def test_reading_the_forms_from_the_page(self):
        calls = []

        def console(expression=None, task_id=None):
            calls.append((expression, task_id))
            return json.dumps({"success": True, "result": json.dumps({
                "url": "https://shop.example/basket", "matched": 1,
                "forms": [{"inform": True, "action": "https://shop.example/pay", "method": "post"}]})})
        tools = SimpleNamespace(browser_tool=SimpleNamespace(browser_console=console))
        with patch.dict("sys.modules", {"tools": tools, "tools.browser_tool": tools.browser_tool}):
            found = screen_text.read_page_forms("t", 'Pay "now"')
            self.assertEqual(found["forms"][0]["action"], "https://shop.example/pay")
            self.assertIn(json.dumps('Pay "now"'), calls[0][0])
            self.assertEqual(calls[0][1], "t")
            self.assertIsNone(screen_text.read_page_forms("t", ""))
        broken = SimpleNamespace(browser_tool=SimpleNamespace(browser_console=lambda **_: "not json"))
        with patch.dict("sys.modules", {"tools": broken, "tools.browser_tool": broken.browser_tool}):
            self.assertIsNone(screen_text.read_page_forms("t", "OK"))


if __name__ == "__main__":
    unittest.main()
