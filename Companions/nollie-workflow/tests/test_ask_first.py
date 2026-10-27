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



class Files:
    """Stands in for the files checker: paths that are there already, and folders."""

    def __init__(self, existing=(), folders=(), unreadable=False):
        self.existing, self.folders, self.unreadable = set(existing), set(folders), unreadable

    def replaces(self, path, cwd=None):
        return None if self.unreadable else str(path).rstrip("/") in self.existing

    def folder(self, path, cwd=None):
        return str(path).rstrip("/") in self.folders


def described(description="", **properties):
    return lambda tool: {"description": description, "parameters": {"properties": properties}}


class OtherServerTests(unittest.TestCase):
    """MCP and connector tools: a plainly reading name passes, and everything else asks."""

    def kind(self, tool, args=None, describe=None):
        found = ask_first.classify(tool, args or {}, describe=describe)
        return found.kind if found else None

    def test_a_neutral_name_asks(self):
        for tool in ("mcp__acme__sync_items", "mcp__acme__process", "connectors__crm__update_record",
                     "mcp__notion__API-patch-page", "mcp__acme__get_and_archive", "mcp__acme__search_replace",
                     "mcp__acme__run", "mcp__filesystem__move_file", "mcp__acme__handle_request"):
            with self.subTest(tool):
                self.assertEqual(self.kind(tool, {"id": "1"}), "unsure")
        found = ask_first.classify("mcp__acme__sync_items", {"id": "1"})
        self.assertIn("Nollie can't tell from its name that it only looks things up", found.description())

    def test_what_a_tool_said_at_registration_names_the_kind(self):
        self.assertEqual(self.kind("mcp__acme__sync_items", {}, described("Sends every pending item to your team.")),
                         "send")
        self.assertEqual(self.kind("mcp__acme__tidy", {}, described("Deletes old records.")), "delete")
        self.assertEqual(self.kind("mcp__acme__go", {}, described("Post a message to a channel.")), "post")
        self.assertEqual(self.kind("mcp__acme__go", {}, described("Create an order for the basket.")), "buy")
        self.assertEqual(self.kind("mcp__acme__sync", {}, described("Keeps things tidy.", to={}, body={})), "send")
        # A description only ever adds a reason to ask: a reading name with a risky description asks.
        self.assertEqual(self.kind("mcp__acme__get_items", {}, described("Gets items, then emails Sam a summary and "
                                                                          "sends it.")), "send")

    def test_plainly_reading_names_pass(self):
        for tool in ("mcp__gmail__search_emails", "mcp__gmail__messages_list", "mcp__shop__get_order",
                     "mcp__forum__search_posts", "mcp__notion__API-post-search", "mcp__notion__API-get-block-children",
                     "mcp__stripe__retrieve_refund", "mcp__context7__resolve-library-id",
                     "mcp__chrome-devtools__new_page", "mcp__chrome-devtools__close_page",
                     "mcp__chrome-devtools__take_screenshot", "mcp__github__get_workflow_run",
                     "connectors__drive__list_files", "mcp__weather__forecast_status"):
            with self.subTest(tool):
                self.assertIsNone(self.kind(tool, {"id": "1"}, described("Look things up.")))

    def test_drafts_and_plain_page_requests_pass(self):
        self.assertIsNone(self.kind("mcp__gmail__create_draft", {"to": "a@b.c", "body": "hi"},
                                    described("Creates a draft", to={}, body={})))
        self.assertIsNone(self.kind("mcp__fetch__http_request", {"url": "https://example.com"}))
        self.assertEqual(self.kind("mcp__fetch__http_request", {"url": "https://example.com", "body": "x"}), "unsure")

    def test_a_broken_description_still_asks(self):
        def broken(tool):
            raise RuntimeError("registry moved")
        self.assertEqual(self.kind("mcp__acme__sync_items", {}, broken), "unsure")
        self.assertIsNone(self.kind("mcp__acme__list_items", {}, broken))

    def test_own_servers_keep_their_own_rules(self):
        self.assertIsNone(self.kind("mcp__nollie_mac__mac_click", {"element": "e3"}))
        self.assertIsNone(self.kind("mcp__cua__space_list", {}))


class FileTests(unittest.TestCase):
    """Replacing or removing a file that was there before this turn asks; the bot's own new files don't."""

    def test_write_file_over_an_existing_file_asks(self):
        found = ask_first.classify("write_file", {"path": "/Users/sam/notes.txt", "content": "x"},
                                   files=Files({"/Users/sam/notes.txt"}))
        self.assertEqual(found.kind, "delete")
        self.assertIn("Replace /Users/sam/notes.txt, which was already there.", found.description())
        self.assertIn("What it held before will be gone.", found.description())
        self.assertIsNone(ask_first.classify("write_file", {"path": "/Users/sam/new.txt", "content": "x"},
                                             files=Files({"/Users/sam/notes.txt"})))
        self.assertEqual(ask_first.classify("write_file", {"path": "a.txt", "content": "x"},
                                            files=Files(unreadable=True)).kind, "unsure")

    def test_other_servers_file_writers_ask_before_replacing(self):
        found = ask_first.classify("mcp__filesystem__write_file", {"path": "/Users/sam/notes.txt", "content": "x"},
                                   files=Files({"/Users/sam/notes.txt"}))
        self.assertEqual(found.kind, "delete")

    def test_patches_that_replace_a_file_ask(self):
        existing = Files({"notes.txt", "old.txt"})
        for patch in ("*** Begin Patch\n*** Add File: notes.txt\n+hello\n*** End Patch",
                      "*** Begin Patch\n*** Update File: draft.txt\n*** Move to: old.txt\n*** End Patch"):
            with self.subTest(patch):
                self.assertEqual(ask_first.classify("patch", {"mode": "patch", "patch": patch}, files=existing).kind,
                                 "delete")
        self.assertIsNone(ask_first.classify("patch", {"mode": "patch", "patch": "*** Add File: fresh.txt\n+a"},
                                             files=existing))

    def test_shell_writes_over_files(self):
        existing = Files({"notes.txt", "/Users/sam/Documents/Trips/itinerary.pdf"},
                         folders={"/Users/sam/Documents/Trips"})
        for command, kind in (("echo hi > notes.txt", "delete"), ("echo hi >notes.txt", "delete"),
                              ("echo hi >| notes.txt", "delete"), ("date | tee notes.txt", "delete"),
                              ("cp draft.txt notes.txt", "delete"), ("mv draft.txt notes.txt", "delete"),
                              ("cp ~/Downloads/itinerary.pdf /Users/sam/Documents/Trips/", "delete"),
                              ("cat > notes.txt <<'EOF'\nhello\nEOF", "delete"),
                              ("echo hi >> notes.txt", None), ("date | tee -a notes.txt", None),
                              ("cp -n draft.txt notes.txt", None), ("echo hi > fresh.txt", None),
                              ("ls 2>/dev/null", None), ("make 2>&1 | tail", "unsure"),
                              ("cat > fresh.md <<'EOF'\nhello\nEOF", None), ("echo x > $OUT", "unsure")):
            with self.subTest(command):
                found = ask_first.classify("terminal", {"command": command}, files=existing,
                                           read_file=lambda path, cwd: None)
                self.assertEqual(found.kind if found else None, kind)

    def test_the_real_checker(self):
        with TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            scratch = root / "home" / "cache" / "scratch"
            scratch.mkdir(parents=True)
            (scratch / "chart.py").write_text("x")
            (root / "notes.txt").write_text("x")
            (root / "link.txt").symlink_to(root / "notes.txt")
            files = ask_first.Files(scratch=lambda: [scratch], temporary=False)
            bound = files.bind("t", "s")
            self.assertTrue(bound.replaces(str(root / "notes.txt")))
            self.assertTrue(bound.replaces("link.txt", str(root)))
            self.assertFalse(bound.replaces(str(scratch / "chart.py")))
            self.assertFalse(bound.replaces(str(root / "new.txt")))
            self.assertFalse(bound.replaces(str(root)))
            self.assertIsNone(bound.replaces(""))
            self.assertIsNone(bound.replaces(None))
            # Temporary folders are scratch too.
            self.assertFalse(ask_first.Files().replaces(str(root / "notes.txt")))
            # A file the bot made this turn is its own until the next turn starts.
            bound.commit()
            (root / "new.txt").write_text("made by the bot")
            self.assertFalse(files.bind("t", "s").replaces(str(root / "new.txt")))
            self.assertTrue(files.bind("t", "other chat").replaces(str(root / "new.txt")))
            files.new_turn(session_id="s")
            self.assertTrue(files.bind("t", "s").replaces(str(root / "new.txt")))
            broken = ask_first.Files(resolve=lambda *a: None)
            self.assertIsNone(broken.replaces("anything"))

    def test_only_a_call_that_goes_ahead_makes_a_file_its_own(self):
        with TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            files = ask_first.Files(temporary=False)
            hook = ask_first.AskFirst(unattended=lambda: False, bypassed=lambda *_: False, files=files)
            target = str(root / "plan.md")
            self.assertIsNone(hook.hook(tool_name="write_file", args={"path": target, "content": "a"},
                                        session_id="s"))
            Path(target).write_text("a")
            self.assertIsNone(hook.hook(tool_name="write_file", args={"path": target, "content": "b"},
                                        session_id="s"))
            files.new_turn(session_id="s")
            answer = hook.hook(tool_name="write_file", args={"path": target, "content": "c"}, session_id="s")
            self.assertEqual(answer["action"], "approve")
            self.assertRegex(answer["rule_key"], r"^nollie-ask-first:delete:")
            # A command held for a yes makes nothing its own, even though it would have made a new file.
            other = str(root / "other.md")
            held = hook.hook(tool_name="terminal", args={"command": f"rm old.txt; echo x > {other}"}, session_id="t")
            self.assertEqual(held["action"], "approve")
            Path(other).write_text("x")
            self.assertEqual(hook.hook(tool_name="write_file", args={"path": other, "content": "y"},
                                       session_id="t")["action"], "approve")


class RunnerTests(unittest.TestCase):
    """Programs that run other code: what they run is read, and what can't be read asks."""

    def kind(self, command, scripts=None, cwd=None):
        scripts = scripts or {}
        found = ask_first.classify("terminal", {"command": command, **({"workdir": cwd} if cwd else {})},
                                   read_file=lambda path, cwd: scripts.get(Path(path).name), files=Files())
        return found.kind if found else None

    def test_compiled_programs_and_scripts_by_path(self):
        self.assertEqual(self.kind("./backup-tool --all", {"backup-tool": "\x7fELF\x00\x00\x01binary"}), "unsure")
        self.assertEqual(self.kind("/Users/sam/bin/mailer", {"mailer": "#!/bin/sh\nsendmail sam@example.com < m"}),
                         "send")
        self.assertEqual(self.kind("./notify", {"notify": "#!/usr/bin/env python3\nimport smtplib\n"}), "send")
        self.assertEqual(self.kind("./weird", {"weird": "#!/usr/bin/env ruby-custom\nputs 1"}), "unsure")
        self.assertEqual(self.kind("/Applications/Tool.app/Contents/MacOS/Tool"), "unsure")
        self.assertIsNone(self.kind("/usr/bin/grep -r tax ~/Documents"))

    def test_package_scripts_are_read(self):
        package = {"package.json": json.dumps({"scripts": {
            "deploy": "npm run build && wrangler deploy", "build": "vite build", "test": "jest",
            "predeploy": "echo ready", "clean": "rimraf dist", "sync": "node sync.js"}}),
            "sync.js": "fetch('https://api.example.com/messages', {method: 'POST'})"}
        for command, kind in (("npm run deploy", "post"), ("npm test", None), ("yarn build", None),
                              ("pnpm run clean", "delete"), ("npm run sync", "send"), ("npm run missing", "unsure"),
                              ("npm run", None), ("bun run build", None)):
            with self.subTest(command):
                self.assertEqual(self.kind(command, package), kind)
        self.assertEqual(self.kind("npm run build"), "unsure")  # No package.json to read.

    def test_makefiles_are_read(self):
        makefile = ("SITE = sam@example.com:/var/www\nOUT := dist\n\n.PHONY: all deploy clean test\n"
                    "all: build\n\nbuild:\n\t@echo building\n\tpandoc notes.md -o $(OUT)/notes.html\n\n"
                    "deploy: build\n\trsync -a $(OUT)/ $(SITE)\n\nclean:\n\trm -rf $(OUT)\n\n"
                    "test:\n\tpytest -q\n\nodd:\n\t$(shell cat cmd.txt)\n")
        for command, kind in (("make", None), ("make test", None), ("make deploy", "send"), ("make clean", "delete"),
                              ("make odd", "unsure"), ("make nothing-here", "unsure"),
                              ("make -C site deploy", "send")):
            with self.subTest(command):
                self.assertEqual(self.kind(command, {"Makefile": makefile}), kind)
        self.assertEqual(self.kind("make"), "unsure")

    def test_justfiles_are_read(self):
        justfile = "default: test\n\ntest:\n    pytest -q\n\npublish: test\n    cargo publish\n"
        self.assertIsNone(self.kind("just", {"justfile": justfile}))
        self.assertEqual(self.kind("just publish", {"justfile": justfile}), "post")
        self.assertEqual(self.kind("just publish"), "unsure")

    def test_installers_and_runners_ask(self):
        for command in ("pip install requests", "brew install ffmpeg", "npm install", "npx some-tool --go",
                        "uvx some-tool", "cargo run", "go run .", "swift run", "rake db:seed", "gem install x",
                        "docker run alpine echo hi", "pipx run some-tool"):
            with self.subTest(command):
                self.assertEqual(self.kind(command), "unsure")
        for command in ("pip list", "pip3 show pandas", "brew info ffmpeg", "brew list --versions", "npx prettier --check .",
                        "cargo build", "cargo test", "go test ./...", "docker ps", "kubectl get pods",
                        "xcodebuild -list", "swift build", "uvx ruff check ."):
            with self.subTest(command):
                self.assertIsNone(self.kind(command))

    def test_unknown_programs_ask_unless_they_only_look(self):
        self.assertEqual(self.kind("acme-sync --all"), "unsure")
        self.assertEqual(self.kind("acme-sync"), "unsure")
        self.assertIsNone(self.kind("acme-sync list"))
        self.assertIsNone(self.kind("acme-sync --help"))
        self.assertIsNone(self.kind("ffmpeg -i a.mov b.mp4"))
        self.assertEqual(self.kind("ffmpeg -re -i talk.mp4 -f flv rtmp://live.example.com/app/key"), "post")
        self.assertIsNone(self.kind("for f in *.heic; do sips -s format png \"$f\" --out x.png; done"))
        self.assertEqual(self.kind("for f in *.tmp; do rm \"$f\"; done"), "delete")
        self.assertIsNone(self.kind("if grep -q tax notes.txt; then echo found; fi"))
        self.assertIsNone(self.kind("(cd ~/Documents && ls) && [[ -f notes.txt ]] && (( n = 1 + 2 ))"))
        self.assertIsNone(self.kind("networksetup -listallhardwareports"))
        self.assertIsNone(self.kind("command -v remindctl && remindctl today --json"))
        self.assertIsNone(self.kind("box files:get 123 --json"))
        self.assertEqual(self.kind("box files:upload ./report.pdf --parent-id 0"), "unsure")
        self.assertEqual(self.kind("remindctl add 'Buy milk'"), "unsure")
        self.assertEqual(self.kind("networksetup -setairportpower en0 off"), "unsure")
        # A function's body runs, so it is read.
        self.assertEqual(self.kind("tidy() { rm -rf ~/old; }; tidy"), "delete")
        self.assertEqual(self.kind("function tidy { rm -rf ~/old; }; tidy"), "delete")

    def test_ssh_reads_the_remote_command(self):
        self.assertEqual(self.kind("ssh -p 2222 sam@nas 'rm -rf ~/old'"), "delete")
        self.assertIsNone(self.kind("ssh sam@nas ls -la"))
        self.assertIsNone(self.kind("ssh sam@nas"))

    def test_code_that_runs_programs(self):
        def kind(code):
            found = ask_first.classify("execute_code", {"code": code}, files=Files())
            return found.kind if found else None
        self.assertEqual(kind("import subprocess\nsubprocess.run(cmd, shell=True)"), "unsure")
        self.assertEqual(kind("import os\nos.system(command)"), "unsure")
        self.assertEqual(kind("import subprocess\nsubprocess.run(['acme-sync', '--all'])"), "unsure")
        self.assertIsNone(kind("import subprocess\nsubprocess.run(['ffmpeg', '-i', src, dst])"))
        self.assertIsNone(kind("const m = /a(b)/.exec('abc'); console.log(m)"))
        self.assertIsNone(kind("subprocess.run([sys.executable, '-m', 'pytest'])"))


class Around(Screen):
    def around(self, tool, args):
        return ask_first.UNREADABLE if self.seen in ("unreadable", None) else self.seen.get("around",
                                                                                          ask_first.UNREADABLE)

    def page(self, tool, args):
        return None if self.seen in ("unreadable", None) else self.seen.get("page")


class NeutralButtonTests(unittest.TestCase):
    """OK, Continue and Done: what they press is read from the window, sheet or page around them."""

    def press(self, tool, label, around=None, page=None, args=None):
        seen = {"label": label, "text": around or ""}
        if around is not ask_first.UNREADABLE:
            seen["around"] = around
        if page is not None:
            seen["page"] = page
        return ask_first.classify(tool, args or {"ref": "@e3", "x": 4, "y": 5, "action": "click", "element": 3},
                                  screen=Around(seen))

    def test_risky_words_around_make_it_ask(self):
        for tool, label, around, kind in (
                ("browser_click", "OK", "Delete 3 photos?\nThis can't be undone.", "delete"),
                ("mcp__cua__computer_click", "Continue", "Pay £24.00 now with Visa ending 4242", "buy"),
                ("computer_use", "Done", "Send this message to Priya?", "send"),
                ("browser_click", "Yes, I'm sure", "Close your account", "delete"),
                ("browser_click", "Got it", "Your post will be published to everyone", "post")):
            with self.subTest(label=label, around=around):
                found = self.press(tool, label, around)
                self.assertEqual(found.kind, kind)
                self.assertEqual(found.button, label)
                self.assertTrue(found.description().endswith(f"You're about to press “{label}”."))
                self.assertIn("Next to it:", found.description())

    def test_unreadable_surroundings_ask(self):
        found = self.press("computer_use", "OK", ask_first.UNREADABLE)
        self.assertEqual(found.kind, "unsure")
        self.assertIn("Nollie couldn't read what it's for, so it asks first.", found.description())

    def test_calm_surroundings_pass(self):
        for around in ("Your changes were saved.", "We use cookies and share data with our partners.",
                       "Choose your region"):
            with self.subTest(around):
                self.assertIsNone(self.press("browser_click", "OK", around))
        # A button that names its own harmless action is not judged by its neighbours.
        self.assertIsNone(self.press("browser_click", "Show more", "Delete account"))

    def test_the_page_decides_over_the_label(self):
        checkout = {"url": "https://shop.example/basket", "forms": [
            {"action": "https://shop.example/checkout/complete", "method": "post"}]}
        found = self.press("browser_click", "View details", "Your basket", checkout)
        self.assertEqual(found.kind, "buy")
        self.assertIn("The page sends it to https://shop.example/checkout/complete.", found.description())
        for form, kind in (({"action": "https://forum.example/comments", "method": "post"}, "post"),
                           ({"action": "https://mail.example/send", "method": "POST"}, "send"),
                           ({"action": "https://x.example/account/delete", "method": "post"}, "delete"),
                           ({"action": "https://x.example/items", "method": "get", "formaction": "https://x.example/remove",
                             "formmethod": "post"}, "delete"),
                           ({"action": "https://x.example/login", "method": "post"}, None),
                           ({"action": "https://x.example/search", "method": "get"}, None),
                           ({"action": "https://x.example/orders", "method": "get"}, None)):
            with self.subTest(form=form):
                found = self.press("browser_click", "Next", "Step 2 of 3", {"url": "https://x.example/", "forms": [form]})
                self.assertEqual(found.kind if found else None, kind)
        found = self.press("browser_click", "Continue", "Step 2 of 3", {"url": "https://shop.example/checkout", "forms": []})
        self.assertEqual(found.kind, "buy")
        self.assertIsNone(self.press("browser_click", "Continue", "Step 2 of 3",
                                     {"url": "https://shop.example/help", "forms": []}))


class SwitchTests(unittest.TestCase):
    """The per-bot switch covers only the calls Nollie can't read. Sending, buying, posting and deleting ask."""

    def hook(self, on):
        return ask_first.AskFirst(unattended=lambda: False, bypassed=lambda *_: False, unsure=lambda: on,
                                  files=Files())

    def test_off_still_asks_for_the_four(self):
        hook = self.hook(False)
        for tool, args in (("terminal", {"command": "rm old.txt"}), ("mcp__gmail__send_email", {"to": "a@b.c"}),
                           ("terminal", {"command": "git push"}), ("mcp__shop__checkout", {})):
            with self.subTest(tool=tool):
                self.assertEqual(hook.hook(tool_name=tool, args=args)["action"], "approve")
        self.assertIsNone(hook.hook(tool_name="mcp__acme__sync_items", args={}))
        self.assertIsNone(hook.hook(tool_name="terminal", args={"command": "acme-sync --all"}))
        self.assertEqual(self.hook(True).hook(tool_name="mcp__acme__sync_items", args={})["action"], "approve")

    def test_a_rule_that_chokes_asks_even_when_off(self):
        hook = self.hook(False)
        original = ask_first.classify

        def boom(*_, **__):
            raise RuntimeError("bug")
        ask_first.classify = boom
        try:
            self.assertEqual(hook.hook(tool_name="anything", args={})["action"], "approve")
        finally:
            ask_first.classify = original

    def test_a_broken_switch_reads_as_on(self):
        def broken():
            raise OSError("gone")
        hook = ask_first.AskFirst(unattended=lambda: False, bypassed=lambda *_: False, unsure=broken)
        self.assertEqual(hook.hook(tool_name="mcp__acme__sync_items", args={})["action"], "approve")

    def test_the_switch_file(self):
        with TemporaryDirectory() as folder:
            home = Path(folder)
            switch = ask_first.Switch(home)
            self.assertTrue(switch())
            (home / "nollie-workflow").mkdir()
            path = home / "nollie-workflow" / ask_first.SWITCH_FILE
            path.write_text(json.dumps({"version": 1, "enabled": False}))
            self.assertFalse(switch())
            for text in ('{"version": 1, "enabled": true}', '{"version": 2, "enabled": false}', "{",
                         '{"version": 1, "enabled": "no"}', "[]"):
                path.write_text(text)
                self.assertTrue(ask_first.Switch(home)(), text)
            path.unlink()
            elsewhere = home / "off.json"
            elsewhere.write_text(json.dumps({"version": 1, "enabled": False}))
            path.symlink_to(elsewhere)
            self.assertTrue(ask_first.Switch(home)())


if __name__ == "__main__":
    unittest.main()
