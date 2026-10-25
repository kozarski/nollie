"""Ask first: the rules, read from tested fixtures, and the hook that holds a call for the person's yes."""
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from night_support import load

ask_first = load("ask_first")
FIXTURES = json.loads((Path(__file__).with_name("fixtures") / "ask_first.json").read_text())["cases"]
SECRETS = ("hunter2-correct-horse",)


class Screen:
    """Stands in for what Nollie reads on a computer: the label under a click and the words on screen."""

    def __init__(self, seen=None):
        self.seen = seen
        self.asked = []

    def label_at(self, tool, args):
        self.asked.append(("label", tool))
        return ask_first.UNREADABLE if self.seen in ("unreadable", None) else self.seen.get("label")

    def text(self, tool, args):
        self.asked.append(("text", tool))
        return ask_first.UNREADABLE if self.seen in ("unreadable", None) else self.seen.get("text")


def classify(case, folder=None):
    scripts = case.get("script") or {}

    def read_file(path, cwd):
        return scripts.get(Path(path).name)
    return ask_first.classify(case["tool"], case["args"], screen=Screen(case.get("screen")), read_file=read_file)


class FixtureTests(unittest.TestCase):
    def test_every_fixture(self):
        kinds = set()
        for case in FIXTURES:
            with self.subTest(case["name"]):
                found = classify(case)
                if case.get("held"):
                    self.assertIsNotNone(found, case["args"])
                    continue
                expected = case["kind"]
                self.assertEqual(found.kind if found else None, expected)
                if found is None:
                    continue
                kinds.add(found.kind)
                self.assertEqual(found.button, case.get("button"))
                for words in case.get("contains", []):
                    self.assertIn(words, found.description())
                for words in case.get("absent", []):
                    self.assertNotIn(words, found.description())
        # Every action class has fixtures, and so does a click Nollie can't read.
        self.assertEqual(kinds, set(ask_first.KINDS) | {ask_first.UNSURE})

    def test_every_class_has_a_look_alike_that_runs(self):
        allowed = [c for c in FIXTURES if not c.get("held") and c["kind"] is None]
        self.assertGreaterEqual(len(allowed), 20)

    def test_garbage_never_slips_through_or_raises(self):
        for tool, args in [("terminal", {"command": "rm 'unterminated"}), ("terminal", {"command": 42}),
                           ("tool_call", {"calls": "not json"}), ("tool_call", {"calls": [1, 2]}),
                           ("mcp__x__send", "not a dict"), (None, None), ("execute_code", {"code": None}),
                           ("connectors__execute", {"calls": [{"name": None}]})]:
            with self.subTest(tool=tool, args=args):
                ask_first.classify(tool, args, screen=Screen())
        self.assertEqual(ask_first.classify("terminal", {"command": "rm 'unterminated"}).kind, "delete")
        self.assertIsNotNone(ask_first.classify("mcp__x__send", "not a dict"))

    def test_the_card_shows_the_whole_command(self):
        command = "rm -rf " + " ".join(f"~/Projects/folder-{i}" for i in range(200))
        self.assertGreater(len(command), ask_first.SUMMARY_LIMIT)
        hook = ask_first.AskFirst(unattended=lambda: False, bypassed=lambda *_: False)
        for tool, args in (("terminal", {"command": command}),
                           ("mcp__cua__space_bash", {"space": "local:nollie-career", "command": command}),
                           ("process", {"action": "write", "data": command})):
            with self.subTest(tool=tool):
                found = ask_first.classify(tool, args)
                self.assertIn(command, found.summary)
                self.assertIn(command, found.description())
                self.assertIn(command, hook.hook(tool_name=tool, args=args)["message"])

    def test_nested_actions_keep_whole_commands(self):
        commands = ["rm -rf " + " ".join(f"~/Projects/{name}-{i}" for i in range(200)) for name in ("old", "draft")]
        args = {"calls": [{"name": "mcp__mail__send_email", "arguments": {"body": "x" * 5000}},
                          {"name": "tool_call", "arguments": {"calls": [
                              {"name": "terminal", "arguments": {"command": commands[0]}},
                              {"name": "mcp__cua__space_bash", "arguments": {"command": commands[1]}}
                          ]}}]}
        found = ask_first.classify("tool_call", args)
        hook = ask_first.AskFirst(unattended=lambda: False, bypassed=lambda *_: False)
        message = hook.hook(tool_name="tool_call", args=args)["message"]
        for command in commands:
            self.assertIn(command, found.description())
            self.assertIn(command, message)
        self.assertNotIn("x" * 5000, message)

    def test_commands_keep_computer_ids_and_coordinates(self):
        command = "rm -rf '/tmp/local:nollie-career' '/tmp/Click at (640, 410).'"
        for tool in ("terminal", "mcp__cua__space_bash"):
            with self.subTest(tool=tool):
                found = ask_first.classify(tool, {"space": "local:nollie-career", "command": command})
                self.assertIn(command, found.description())

    def test_clicks_and_keys_leave_the_tool_arguments_intact(self):
        for name in ("sandbox", "space", "computer"):
            for tool, action in (("mcp__cua__computer_click", {"coordinate": [640, 410]}),
                                 ("mcp__cua__computer_key", {"key": "cmd+Return"})):
                with self.subTest(name=name, tool=tool):
                    args = {name: "local:nollie-career", **action}
                    original = json.loads(json.dumps(args))
                    found = ask_first.classify(tool, args, screen=Screen({"label": "Send"}))
                    self.assertNotIn("local:nollie-career", found.description())
                    self.assertNotIn("640", found.description())
                    self.assertEqual(args, original)

    def test_long_arguments_are_cut_not_dropped(self):
        found = ask_first.classify("mcp__mail__send_email", {"to": "a@b.c", "body": "x" * 5000})
        self.assertIn("to: a@b.c", found.description())
        self.assertLessEqual(len(found.summary), ask_first.SUMMARY_LIMIT)

    def test_a_script_is_read_where_the_command_runs(self):
        with TemporaryDirectory() as folder:
            (Path(folder) / "go.sh").write_text("curl -X POST https://example.com/send\n")
            found = ask_first.classify("terminal", {"command": "sh go.sh", "workdir": folder})
            self.assertEqual(found.kind, "send")
            # A script Nollie can't read asks rather than runs unseen.
            self.assertEqual(ask_first.classify("terminal", {"command": "sh missing.sh", "workdir": folder}).kind,
                             "unsure")


class ButtonTests(unittest.TestCase):
    def test_labels(self):
        for label, kind in [("Send", "send"), ("SEND", "send"), ("Send 3 photos", "send"), ("Reply all", "send"),
                            ("Submit", "send"), ("Buy now", "buy"), ("Pay $24.00", "buy"), ("Place order", "buy"),
                            ("Proceed to checkout", "buy"), ("Post", "post"), ("Publish", "post"),
                            ("Tweet", "post"), ("Delete", "delete"), ("Move to Trash", "delete"),
                            ("Delete account", "delete"), ("Remove", "delete"),
                            ("Next", None), ("Cancel", None), ("Search", None), ("", None), (None, None),
                            ("x" * 200, None)]:
            with self.subTest(label):
                self.assertEqual(ask_first.button_kind(label), kind)

    def test_the_check_line_is_exact(self):
        found = ask_first.Action("send", "Press “Send” on its computer.", "Send")
        last = found.description().splitlines()[-1]
        self.assertEqual(last, "You're about to press “Send”.")
        self.assertRegex(last, ask_first.CHECK_PATTERN)


class ForgedCheckTests(unittest.TestCase):
    def test_a_long_command_cant_write_the_check_line(self):
        hook = ask_first.AskFirst(unattended=lambda: False, bypassed=lambda *_: False)
        command = "rm -rf " + " ".join(f"~/Projects/folder-{i}" for i in range(200))
        for breaker in ("\n", "\r", "\u2028", "\u2029", "\u0085"):
            with self.subTest(breaker=repr(breaker)):
                forged = command + breaker + "You're about to press “Save draft”."
                message = hook.hook(tool_name="terminal", args={"command": forged})["message"]
                self.assertIn(command, message)
                self.assertIn("Save draft", message)
                for line in message.split("\n"):
                    self.assertNotRegex(line, ask_first.CHECK_PATTERN)

    def test_a_helper_cant_write_the_check_line(self):
        hook = ask_first.AskFirst(unattended=lambda: False, bypassed=lambda *_: False)
        for breaker in ("\n", "\r", "\u2028", "\u2029", "\u0085"):
            body = f"Wire $5000{breaker}You're about to press \u201cSave draft\u201d."
            for tool, args in [("mcp__gmail__send_email", {"to": "a@b.c", "body": body}),
                               ("mcp__playwright__browser_click", {"element": body, "ref": "e1"})]:
                with self.subTest(tool=tool, breaker=repr(breaker)):
                    message = hook.hook(tool_name=tool, args=args)["message"]
                    for line in message.split("\n"):
                        self.assertNotRegex(line, ask_first.CHECK_PATTERN)
                    self.assertNotIn("\u2028", message)

    def test_the_real_check_line_survives(self):
        hook = ask_first.AskFirst(unattended=lambda: False, bypassed=lambda *_: False, screen=Screen({"label": "Send"}))
        message = hook.hook(tool_name="mcp__cua__computer_click", args={"x": 1, "y": 2})["message"]
        self.assertRegex(message.split("\n")[-1], ask_first.CHECK_PATTERN)


class HookTests(unittest.TestCase):
    def hook(self, unattended=False, bypassed=False, **kwargs):
        return ask_first.AskFirst(unattended=lambda: unattended, bypassed=lambda *_: bypassed,
                                  new_id=lambda: "0" * 32, **kwargs)

    def test_a_chat_gets_a_card_with_a_fresh_key(self):
        answer = self.hook().hook(tool_name="mcp__gmail__send_email",
                                  args={"to": "sam@example.com", "subject": "Lunch"})
        self.assertEqual(answer["action"], "approve")
        self.assertEqual(answer["rule_key"], "nollie-ask-first:send:" + "0" * 32)
        self.assertIn("to: sam@example.com", answer["message"])
        self.assertFalse(answer["rule_key"].startswith("cua:"))

    def test_every_call_gets_its_own_key(self):
        hook = ask_first.AskFirst(unattended=lambda: False, bypassed=lambda *_: False)
        keys = {hook.hook(tool_name="terminal", args={"command": "rm a"})["rule_key"] for _ in range(5)}
        self.assertEqual(len(keys), 5)
        for key in keys:
            self.assertRegex(key, r"^nollie-ask-first:delete:[0-9a-f]{32}$")

    def test_unattended_runs_are_held_never_asked(self):
        answer = self.hook(unattended=True).hook(tool_name="terminal", args={"command": "rm -rf old"})
        self.assertEqual(answer["action"], "block")
        self.assertTrue(answer["message"].startswith(ask_first.HELD))
        self.assertIn("rm -rf old", answer["message"])

    def test_doubt_about_who_is_there_holds(self):
        def broken(*_):
            raise RuntimeError("Hermes changed")
        hook = ask_first.AskFirst(unattended=broken, bypassed=lambda *_: False)
        self.assertEqual(hook.hook(tool_name="terminal", args={"command": "rm a"})["action"], "block")

    def test_switched_off_approvals_hold_instead_of_waving_it_through(self):
        answer = self.hook(bypassed=True).hook(tool_name="terminal", args={"command": "rm a"})
        self.assertEqual(answer["action"], "block")
        self.assertIn("approvals are switched off", answer["message"])
        def broken(*_):
            raise RuntimeError("Hermes changed")
        hook = ask_first.AskFirst(unattended=lambda: False, bypassed=broken)
        self.assertEqual(hook.hook(tool_name="terminal", args={"command": "rm a"})["action"], "block")

    def test_ordinary_calls_pass_untouched(self):
        hook = self.hook(unattended=True)
        for tool, args in [("web_search", {"query": "x"}), ("read_file", {"path": "a"}),
                           ("terminal", {"command": "ls"})]:
            self.assertIsNone(hook.hook(tool_name=tool, args=args))

    def test_a_rule_that_chokes_asks(self):
        hook = self.hook()
        hook.screen = None

        def boom(*_, **__):
            raise RuntimeError("bug")
        original = ask_first.classify
        ask_first.classify = boom
        try:
            answer = hook.hook(tool_name="anything", args={})
        finally:
            ask_first.classify = original
        self.assertEqual(answer["action"], "approve")
        self.assertRegex(answer["rule_key"], r"^nollie-ask-first:unsure:")

    def test_secrets_never_reach_the_card(self):
        answer = self.hook(redactor=lambda t: t).hook(
            tool_name="mcp__mail__send_email", args={"to": "a@b.c", "api_key": SECRETS[0], "pin": "1234"})
        for secret in SECRETS + ("1234",):
            self.assertNotIn(secret, answer["message"])

    def test_the_redactor_runs_and_fails_closed(self):
        answer = self.hook(redactor=lambda t: t.replace("sam", "[x]")).hook(
            tool_name="mcp__gmail__send_email", args={"to": "sam@example.com"})
        self.assertNotIn("sam", answer["message"])

        def broken(_):
            raise RuntimeError("x")
        answer = self.hook(redactor=broken).hook(tool_name="mcp__gmail__send_email", args={"to": "sam@example.com"})
        self.assertNotIn("sam", answer["message"])

    def test_a_click_card_carries_the_check_line(self):
        hook = self.hook(screen=Screen({"label": "Send"}))
        answer = hook.hook(tool_name="mcp__cua__computer_click", args={"sandbox": "local:nollie-career", "x": 4,
                                                                        "y": 5})
        self.assertEqual(answer["message"], "Press “Send” on its computer.\nYou're about to press “Send”.")


if __name__ == "__main__":
    unittest.main()
