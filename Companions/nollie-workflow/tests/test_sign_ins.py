"""Saved sign-ins: the request_sign_in tool, its request files and history, and the routes the Mac uses."""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import stat
import sys
from tempfile import TemporaryDirectory
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
NAME = "sign_ins_test_package"
spec = importlib.util.spec_from_file_location(NAME, ROOT / "__init__.py", submodule_search_locations=[str(ROOT)])
package = importlib.util.module_from_spec(spec)
sys.modules[NAME] = package
spec.loader.exec_module(package)
from sign_ins_test_package import private_bots, sign_ins  # noqa: E402

try:
    import fastapi
except ImportError:
    fastapi = None

# What a helper may ever see in a tool result: these keys, and none of the person's sign-in.
RESULT_KEYS = {"status", "message"}
SECRETS = ("hunter2-correct-horse", "sam@example.com", "Text code to my phone")


class Clock:
    def __init__(self):
        self.now = 1_800_000_000.0

    def __call__(self):
        return self.now


class Harness:
    """The tool with Hermes's pieces replaced: an approval that answers as told, a Mac that acts
    on the request file the way the app does, and a clock that moves only when the tool sleeps."""

    def __init__(self, home, *, private=False, unattended=False, approve=True, mac=None, decision=None):
        self.home = home
        self.clock = Clock()
        self.store = sign_ins.Store(home, clock=self.clock)
        self.private, self.unattended, self.approve = private, unattended, approve
        self.decision = decision
        self.mac = mac
        self.asked = []

    def ask(self, description, rule):
        self.asked.append((description, rule))
        request_id = rule.removeprefix(sign_ins.RULE_PREFIX)
        if self.approve and self.mac and self.mac.get("claim"):
            self.store.claim(request_id, self.mac["claim"])
        if self.decision is not None:
            return self.decision
        return {"approved": True, "message": None} if self.approve else {"approved": False, "outcome": "denied"}

    def sleep(self, seconds):
        self.clock.now += seconds
        if not self.mac:
            return
        for record in self.store.open_requests():
            if record["state"] == "approved" and self.mac.get("start", True):
                self.store.start(record["id"])
                if self.mac.get("hang"):
                    continue
                self.store.report(record["id"], self.mac.get("outcome", "signed_in"), self.mac.get("reason"),
                                  self.mac.get("code_note", False))

    def call(self, args):
        text = sign_ins.handle(args, store=self.store, bot="career", is_private=lambda: self.private,
                               unattended=lambda: self.unattended, ask=self.ask, clock=self.clock, sleep=self.sleep)
        reply = json.loads(text)
        assert set(reply) <= RESULT_KEYS, reply
        for secret in SECRETS:
            assert secret not in text
        return reply


class SitesTests(unittest.TestCase):
    def test_addresses_become_plain_hosts(self):
        cases = {
            "example.com": "example.com",
            "  Example.COM.  ": "example.com",
            "https://www.example.com/login?next=/": "www.example.com",
            "http://login.example.com:8443/": "login.example.com",
            "bücher.de": "xn--bcher-kva.de",
        }
        for raw, host in cases.items():
            self.assertEqual(sign_ins.normalize_site(raw), host, raw)
        for raw in ("", "localhost", "192.168.1.1", "https://user@example.com/", "exa mple.com",
                    "-bad.com", "a..b", None, 7, "x" * 400, "javascript:alert(1)"):
            self.assertIsNone(sign_ins.normalize_site(raw), raw)

    def test_a_saved_site_covers_its_subdomains_only(self):
        self.assertTrue(sign_ins.matches("example.com", "example.com"))
        self.assertTrue(sign_ins.matches("example.com", "login.example.com"))
        for other in ("example.com.evil.net", "myexample.com", "examp1e.com", "com"):
            self.assertFalse(sign_ins.matches("example.com", other), other)

    def test_the_site_list_holds_hosts_only_and_is_private_to_the_user(self):
        with TemporaryDirectory() as temp:
            store = sign_ins.Store(temp)
            self.assertEqual(store.sites(), [])
            self.assertEqual(store.save_sites(["https://Example.com/x", "example.com", "news.site.org"]),
                             ["example.com", "news.site.org"])
            path = Path(temp) / "nollie-workflow" / "sign-ins" / "sites.json"
            self.assertEqual(json.loads(path.read_text()), {"version": 1, "sites": ["example.com", "news.site.org"]})
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
            for bad in (["not a site"], "example.com", [f"s{i}.com" for i in range(501)], [3]):
                with self.assertRaises(ValueError):
                    store.save_sites(bad)
            self.assertEqual(store.sites(), ["example.com", "news.site.org"])

    def test_a_damaged_site_list_is_not_taken_for_empty(self):
        with TemporaryDirectory() as temp:
            store = sign_ins.Store(temp)
            store.root.mkdir(parents=True)
            (store.root / "sites.json").write_text('{"version": 1, "sites": ["not a site"]}')
            with self.assertRaises(ValueError):
                store.sites()


class ToolTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        sign_ins.Store(self.home).save_sites(["example.com"])

    def history(self, harness):
        return harness.store.history(30)

    def test_signed_in_after_a_yes_and_the_mac_typing(self):
        h = Harness(self.home, mac={"claim": "mac"})
        reply = h.call({"site": "https://login.example.com/", "computer": "local:dev"})
        self.assertEqual(reply["status"], "signed_in")
        self.assertIn("login.example.com", reply["message"])
        self.assertEqual(h.asked[0][0], "Sign in to login.example.com")
        self.assertTrue(h.asked[0][1].startswith("nollie-sign-in:"))
        [entry] = self.history(h)
        self.assertEqual(entry, {"at": int(h.clock.now), "bot": "career", "site": "login.example.com",
                                 "outcome": "signed_in", "approver": "mac", "computer": "space"})
        self.assertEqual(h.store.open_requests(), [])

    def test_a_code_note_says_a_code_may_come_without_saying_what_it_is(self):
        h = Harness(self.home, mac={"claim": "iphone", "code_note": True})
        reply = h.call({"site": "example.com", "computer": "local:dev"})
        self.assertIn("one-time code", reply["message"])
        self.assertEqual(self.history(h)[0]["approver"], "iphone")

    def test_unknown_site_is_not_saved_yet_and_nobody_is_asked(self):
        h = Harness(self.home, mac={"claim": "mac"})
        reply = h.call({"site": "other.org", "computer": "local:dev"})
        self.assertEqual(reply["status"], "not_saved")
        self.assertIn("Settings, Sign-ins", reply["message"])
        self.assertEqual(h.asked, [])
        self.assertEqual(self.history(h)[0]["outcome"], "not_saved")

    def test_lookalike_site_is_not_saved(self):
        h = Harness(self.home)
        for site in ("example.com.evil.net", "examp1e.com", "myexample.com"):
            self.assertEqual(h.call({"site": site, "computer": "local:dev"})["status"], "not_saved")
        self.assertEqual(h.asked, [])

    def test_private_bots_are_refused_before_anything_is_read_or_kept(self):
        h = Harness(self.home, private=True, mac={"claim": "mac"})
        with patch.object(h.store, "saved", side_effect=AssertionError("read for a private bot")):
            reply = h.call({"site": "example.com", "computer": "local:dev"})
        self.assertEqual(reply["status"], "refused")
        self.assertEqual(h.asked, [])
        self.assertEqual(self.history(h), [])

    def test_a_damaged_private_list_refuses_too(self):
        h = Harness(self.home)

        def damaged():
            raise ValueError("the Private list is not valid")
        reply = json.loads(sign_ins.handle({"site": "example.com", "computer": "local:dev"}, store=h.store, bot="career",
                                           is_private=damaged, unattended=lambda: False, ask=h.ask))
        self.assertEqual(reply["status"], "refused")
        self.assertEqual(h.asked, [])

    def test_private_watch_counts_the_carried_over_names(self):
        watch = private_bots.Watch(self.home, "private", "private")
        self.assertTrue(watch())
        self.assertFalse(private_bots.Watch(self.home, "career", "career")())

    def test_schedules_and_board_work_never_sign_in(self):
        h = Harness(self.home, unattended=True, mac={"claim": "mac"})
        reply = h.call({"site": "example.com", "computer": "local:dev"})
        self.assertEqual(reply["status"], "not_signed_in")
        self.assertEqual(h.asked, [])

    def test_a_no_is_declined_and_the_mac_never_starts(self):
        h = Harness(self.home, approve=False, mac={"claim": "mac"})
        reply = h.call({"site": "example.com", "computer": "local:dev"})
        self.assertEqual(reply["status"], "declined")
        self.assertEqual(self.history(h)[0]["outcome"], "declined")
        [record] = [json.loads(p.read_text()) for p in (h.store.root / "requests").glob("*.json")]
        self.assertEqual((record["state"], record["outcome"]), ("done", "declined"))
        with self.assertRaises(sign_ins.Conflict):
            h.store.start(record["id"])

    def test_no_answer_is_not_a_yes(self):
        h = Harness(self.home, decision={"approved": False, "outcome": "timeout"})
        reply = h.call({"site": "example.com", "computer": "local:dev"})
        self.assertEqual(reply["status"], "declined")
        self.assertEqual(self.history(h)[0]["outcome"], "no_answer")

    def test_a_mac_that_never_comes_closes_the_request_so_it_can_never_type_late(self):
        h = Harness(self.home)  # no Mac at all
        reply = h.call({"site": "example.com", "computer": "local:dev"})
        self.assertEqual(reply["status"], "not_signed_in")
        self.assertIn("Nollie on the Mac", reply["message"])
        [record] = [json.loads(p.read_text()) for p in (h.store.root / "requests").glob("*.json")]
        self.assertEqual(record["outcome"], "expired")
        with self.assertRaises(sign_ins.Conflict):
            h.store.start(record["id"])

    def test_typing_already_under_way_gets_extra_time_then_stops_waiting(self):
        h = Harness(self.home, mac={"claim": "mac", "hang": True})
        reply = h.call({"site": "example.com", "computer": "local:dev"})
        self.assertEqual(reply["status"], "not_signed_in")
        self.assertGreaterEqual(h.clock.now - 1_800_000_000.0, sign_ins.FILL_WAIT + sign_ins.FILL_GRACE)

    def test_the_macs_reasons_become_plain_sentences(self):
        for reason in ("fill_unavailable", "computer_unavailable", "fill_failed", "not_saved_here", "touch_id"):
            h = Harness(self.home, mac={"claim": "mac", "outcome": "failed", "reason": reason})
            reply = h.call({"site": "example.com", "computer": "mac"})
            self.assertEqual((reply["status"], reply["message"]), ("not_signed_in", sign_ins.MESSAGES[reason]))
        h = Harness(self.home, mac={"claim": "iphone", "outcome": "cancelled"})
        self.assertEqual(h.call({"site": "example.com", "computer": "local:dev"})["status"], "declined")

    def test_bad_arguments_get_a_sentence_and_no_request(self):
        h = Harness(self.home, mac={"claim": "mac"})
        for args in ({"site": "not a site", "computer": "local:dev"}, {"site": "example.com"},
                     {"site": "example.com", "computer": "../etc"}, None):
            self.assertEqual(h.call(args)["status"], "not_signed_in", args)
        self.assertEqual(h.asked, [])

    def test_the_tool_schema_takes_no_secret(self):
        props = sign_ins.SCHEMA["parameters"]["properties"]
        self.assertEqual(set(props), {"site", "computer", "focus"})
        self.assertIn("never ask the person for a password", sign_ins.DESCRIPTION)

    def test_the_answer_waits_out_the_pause_after_a_fill(self):
        h = Harness(self.home, mac={"claim": "mac"})
        paused = []
        sleep = h.sleep

        def watch(seconds):
            sleep(seconds)
            paused.append((h.clock.now, bool(sign_ins.typing_now(self.home, h.clock))))
        h.sleep = watch
        self.assertEqual(h.call({"site": "example.com", "computer": "local:dev"})["status"], "signed_in")
        [record] = [json.loads(p.read_text()) for p in (h.store.root / "requests").glob("*.json")]
        self.assertEqual(record["state"], "done")
        # The helper hears back only once pictures may resume, and the pause held all the while.
        self.assertGreaterEqual(h.clock.now - record["updated_at"], sign_ins.SETTLE)
        self.assertLess(h.clock.now - record["updated_at"], sign_ins.SETTLE + 2 * sign_ins.POLL)
        self.assertTrue(all(on for at, on in paused if at < record["updated_at"] + sign_ins.SETTLE))
        self.assertGreater(len(paused), sign_ins.SETTLE / sign_ins.POLL)
        self.assertEqual(sign_ins.typing_now(self.home, h.clock), [])

    def test_a_failed_fill_waits_too(self):
        h = Harness(self.home, mac={"claim": "mac", "outcome": "failed", "reason": "fill_failed"})
        h.call({"site": "example.com", "computer": "local:dev"})
        [record] = [json.loads(p.read_text()) for p in (h.store.root / "requests").glob("*.json")]
        self.assertGreaterEqual(h.clock.now - record["updated_at"], sign_ins.SETTLE)

    def test_a_request_nobody_started_does_not_wait(self):
        h = Harness(self.home)  # No Mac: nothing was typed.
        began = h.clock.now
        reply = h.call({"site": "example.com", "computer": "local:dev"})
        self.assertEqual(reply["status"], "not_signed_in")
        self.assertLess(h.clock.now - began, sign_ins.FILL_WAIT + sign_ins.SETTLE)
        h = Harness(self.home, approve=False, mac={"claim": "mac"})
        began = h.clock.now
        h.call({"site": "example.com", "computer": "local:dev"})
        self.assertEqual(h.clock.now, began)

    def test_the_answer_never_carries_the_sign_in_even_if_the_request_file_does(self):
        h = Harness(self.home, mac={"claim": "mac", "code_note": True})
        sleep = h.sleep

        def leaky(seconds):
            sleep(seconds)
            for path in (h.store.root / "requests").glob("*.json"):
                record = json.loads(path.read_text())
                if record["state"] == "done" and "username" not in record:
                    record.update(username=SECRETS[1], password=SECRETS[0], note=SECRETS[2],
                                  reason=None, outcome="signed_in")
                    path.write_text(json.dumps(record))
        h.sleep = leaky
        reply = h.call({"site": "example.com", "computer": "local:dev"})  # call() checks every secret
        self.assertEqual(reply["status"], "signed_in")
        self.assertNotIn(SECRETS[0], json.dumps(h.store.history(30)))


class TypingNowTests(unittest.TestCase):
    """Whether a password may be on screen anywhere, read from the request files on every call."""

    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.folder = self.home / "nollie-workflow" / "sign-ins" / "requests"
        self.clock = Clock()
        self.clock.now = float(int(time.time()))

    def request(self, state, created_ago=5, updated_ago=1, **fields):
        record = {"version": 1, "id": secrets.token_hex(16), "bot": "career", "site": "example.com",
                  "computer": "local:dev", "state": state, "created_at": int(self.clock.now - created_ago),
                  "updated_at": int(self.clock.now - updated_ago), **fields}
        self.folder.mkdir(parents=True, exist_ok=True)
        (self.folder / (record["id"] + ".json")).write_text(json.dumps(record))
        return record

    def typing(self):
        return sign_ins.typing_now(self.home, self.clock)

    def test_no_folder_means_no_pause(self):
        self.assertEqual(self.typing(), [])
        self.folder.mkdir(parents=True)
        self.assertEqual(self.typing(), [])

    def test_asking_is_not_typing(self):
        self.request("asking")
        self.assertEqual(self.typing(), [])

    def test_approved_and_filling_are_typing(self):
        for state in ("approved", "filling"):
            with self.subTest(state):
                record = self.request(state)
                self.assertEqual(self.typing(), [{"bot": "career", "computer": "local:dev", "until": None}])
                (self.folder / (record["id"] + ".json")).unlink()

    def test_done_pauses_for_settle_then_resumes(self):
        quiet = self.clock.now - 3 + sign_ins.SETTLE
        self.request("done", updated_ago=3, quiet_until=quiet)
        self.assertEqual(self.typing(), [{"bot": "career", "computer": "local:dev", "until": quiet}])
        self.assertEqual(sign_ins.seconds_left(self.typing(), self.clock), int(sign_ins.SETTLE) - 3)
        self.clock.now = quiet
        self.assertEqual(self.typing(), [])

    def test_an_older_record_without_quiet_until_gets_one_more_second(self):
        record = self.request("done", updated_ago=3)
        # A quiet_until that isn't a number is read as missing.
        self.request("done", updated_ago=3, quiet_until=True)
        until = record["updated_at"] + sign_ins.SETTLE + 1
        self.assertEqual(self.typing(), [{"bot": "career", "computer": "local:dev", "until": until}] * 2)
        self.clock.now = until - 0.5
        self.assertEqual(len(self.typing()), 2)
        self.clock.now = until
        self.assertEqual(self.typing(), [])

    def test_a_report_at_a_fractional_second_pauses_a_full_settle(self):
        store = sign_ins.Store(self.home, clock=self.clock)
        self.clock.now += 0.9
        record = store.create("career", "example.com", "local:dev", "username")
        store.approve(record["id"])
        store.start(record["id"])
        reported_at = self.clock.now
        store.report(record["id"], "signed_in")
        # updated_at is whole seconds, so it alone would end the pause 0.9 seconds early.
        self.assertEqual(store.get(record["id"])["quiet_until"], reported_at + sign_ins.SETTLE)
        self.clock.now = reported_at + sign_ins.SETTLE - 0.05
        self.assertTrue(self.typing())
        self.clock.now = reported_at + sign_ins.SETTLE
        self.assertEqual(self.typing(), [])

    def test_closing_or_expiring_sets_the_quiet_time(self):
        store = sign_ins.Store(self.home, clock=self.clock)
        asked = store.create("career", "example.com", "local:dev", "username")
        store.close(asked["id"], "declined")
        self.assertEqual(store.get(asked["id"])["quiet_until"], self.clock.now + sign_ins.SETTLE)
        approved = store.create("career", "example.com", "local:dev", "username")
        store.approve(approved["id"])
        self.clock.now += 0.5
        record = store.expire_unless_filling(approved["id"])
        self.assertEqual((record["state"], record["outcome"]), ("done", "expired"))
        self.assertEqual(record["quiet_until"], self.clock.now + sign_ins.SETTLE)
        filling = store.create("career", "example.com", "local:dev", "username")
        store.approve(filling["id"])
        store.start(filling["id"])
        # Still being typed: left alone, and no quiet time yet.
        self.assertNotIn("quiet_until", store.expire_unless_filling(filling["id"]))

    def test_a_request_older_than_its_lifetime_is_not_typing(self):
        self.request("filling", created_ago=sign_ins.REQUEST_LIFETIME + 1)
        self.request("approved", created_ago=sign_ins.REQUEST_LIFETIME + 60)
        self.assertEqual(self.typing(), [])

    def test_a_damaged_recent_file_counts_and_an_old_one_is_ignored(self):
        self.folder.mkdir(parents=True)
        for name, text in (("a", "{"), ("b", json.dumps({"state": "filling"})), ("c", json.dumps([1])),
                           ("d", json.dumps({"state": "typing", "created_at": 1, "updated_at": 1}))):
            path = self.folder / (name + ".json")
            path.write_text(text)
            with self.subTest(name):
                self.assertEqual(self.typing(), [{"bot": None, "computer": None, "until": None}])
                old = self.clock.now - sign_ins.REQUEST_LIFETIME - 5
                os.utime(path, (old, old))
                self.assertEqual(self.typing(), [])
                path.unlink()

    def test_linked_folders_count_as_typing(self):
        elsewhere = self.home / "elsewhere"
        elsewhere.mkdir()
        self.folder.parent.mkdir(parents=True)
        self.folder.symlink_to(elsewhere)
        self.assertEqual(self.typing(), [{"bot": None, "computer": None, "until": None}])
        self.folder.unlink()
        self.folder.parent.rmdir()
        self.folder.parent.symlink_to(elsewhere)
        self.assertEqual(self.typing(), [{"bot": None, "computer": None, "until": None}])

    def test_stopping_mid_fill_keeps_pictures_paused_for_the_whole_fill(self):
        sign_ins.Store(self.home).save_sites(["example.com"])
        h = Harness(self.home, mac={"claim": "mac", "hang": True})
        h.clock.now = self.clock.now
        stopped = []

        def interrupted():
            # The person presses Stop once the Mac has begun typing.
            filling = [r for r in h.store.open_requests() if r["state"] == "filling"]
            stopped.extend(r["id"] for r in filling)
            return bool(filling)
        text = sign_ins.handle({"site": "example.com", "computer": "local:dev"}, store=h.store, bot="career",
                               is_private=lambda: False, unattended=lambda: False, ask=h.ask,
                               interrupted=interrupted, clock=h.clock, sleep=h.sleep, recording=lambda: False)
        self.assertEqual(json.loads(text), {"status": "not_signed_in", "message": sign_ins.MESSAGES["interrupted"]})
        record = h.store.get(stopped[0])
        self.assertEqual((record["state"], record["outcome"]), ("done", "interrupted"))
        closed_at = record["quiet_until"] - sign_ins.FILL_TAIL
        self.assertEqual(sign_ins.FILL_TAIL, 35.0)
        # The tool waited out SETTLE, but the Mac may still be typing: pictures stay paused well past it.
        self.assertGreaterEqual(h.clock.now - closed_at, sign_ins.SETTLE)
        h.clock.now = closed_at + sign_ins.SETTLE + 1
        self.assertTrue(sign_ins.typing_now(self.home, h.clock))
        h.clock.now = closed_at + sign_ins.FILL_TAIL - 0.1
        self.assertTrue(sign_ins.typing_now(self.home, h.clock))
        h.clock.now = closed_at + sign_ins.FILL_TAIL
        self.assertEqual(sign_ins.typing_now(self.home, h.clock), [])

    def test_seconds_left_gives_a_fill_in_progress_the_full_wait(self):
        self.assertEqual(sign_ins.seconds_left([{"until": None}], self.clock), int(sign_ins.SETTLE) + 5)
        self.assertEqual(sign_ins.seconds_left([{"until": self.clock.now + 0.2}], self.clock), 1)


class ShowsAComputerTests(unittest.TestCase):
    def test_pictures_of_and_actions_on_a_computer(self):
        for tool, args in (("mcp__cua__computer_screenshot", {}), ("mcp__cua__computer_click", {"x": 1, "y": 2}),
                           ("mcp__cua__space_bash", {"command": "ls"}), ("mcp__cua__sandbox_list", {}),
                           ("mcp__cua_recorder__start_recording", {}), ("mcp__nollie_mac__mac_look", {}),
                           ("computer_use", {"action": "capture"}), ("browser_vision", {"question": "what"}),
                           ("take_screenshot", {}), ("my_screenshot_tool", {}),
                           ("terminal", {"command": "screencapture -x a.png"}),
                           ("terminal", {"command": "cua sandbox screenshot local:dev"}),
                           ("execute_code", {"code": "import subprocess; subprocess.run(['screencapture', 'a.png'])"}),
                           ("process_manage", {"action": "submit", "data": "screencapture -x a.png"}),
                           ("process", {"action": "write", "text": "ffmpeg -f avfoundation -i 1 out.mp4"}),
                           ("terminal", {"command": "bash", "input": "peekaboo image"}),
                           ("tool_call", {"name": "mcp__cua__computer_screenshot", "arguments": {}}),
                           ("tool_call", {"calls": [{"name": "web_search", "arguments": {}},
                                                    {"name": "computer_use", "arguments": {"action": "capture"}}]}),
                           ("tool_call", {"calls": json.dumps([{"name": "terminal", "arguments":
                                                                json.dumps({"command": "screencapture"})}])}),
                           ("tool_call", {"calls": "not json"}), ("tool_call", {"calls": [42]}),
                           ("tool_call", {"calls": [{"arguments": {}}]}),
                           ("connectors__execute", {"name": "mcp__cua__computer_click", "arguments": "{}"})):
            self.assertTrue(sign_ins.shows_a_computer(tool, args), (tool, args))

    def test_everything_else_runs(self):
        for tool, args in (("web_search", {"query": "screenshots of cats"}), ("read_file", {"path": "/a"}),
                           ("terminal", {"command": "ls -la"}), ("execute_code", {"code": "print(1)"}),
                           ("process_manage", {"action": "submit", "data": "git status"}),
                           ("process", {"action": "write", "text": "y"}),
                           ("tool_call", {"calls": [{"name": "web_search", "arguments": {"query": "x"}}]}),
                           ("tool_call", {"calls": json.dumps([{"name": "read_file", "arguments": "plain words"}])}),
                           (None, None), ("request_sign_in", {"site": "example.com"})):
            self.assertFalse(sign_ins.shows_a_computer(tool, args), (tool, args))


class PicturePauseTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.clock = Clock()
        self.store = sign_ins.Store(self.home, clock=self.clock)
        self.pause = sign_ins.PicturePause(self.home, clock=self.clock)

    def test_pictures_wait_while_a_sign_in_is_typed_and_just_after(self):
        record = self.store.create("career", "example.com", "local:dev", "username")
        self.assertIsNone(self.pause.hook(tool_name="computer_use", args={"action": "capture"}))
        self.store.approve(record["id"])
        self.store.start(record["id"])
        blocked = self.pause.hook(tool_name="mcp__cua__computer_screenshot", args={})
        message = sign_ins.PAUSED.format(seconds=int(sign_ins.SETTLE) + 5)
        self.assertEqual(blocked, {"action": "block", "message": message})
        self.assertNotIn("{seconds}", blocked["message"])
        # Other tools carry on.
        self.assertIsNone(self.pause.hook(tool_name="web_search", args={"query": "x"}))
        self.store.report(record["id"], "signed_in")
        self.clock.now += 4
        self.assertIn("about 6 seconds", self.pause.hook(tool_name="computer_use", args={"action": "click"})["message"])
        self.clock.now += sign_ins.SETTLE
        self.assertIsNone(self.pause.hook(tool_name="computer_use", args={"action": "capture"}))

    def test_a_check_that_fails_blocks(self):
        with patch.object(sign_ins, "typing_now", side_effect=RuntimeError("disk")):
            self.assertEqual(self.pause.hook(tool_name="computer_use", args={})["action"], "block")
        with patch.object(sign_ins, "shows_a_computer", side_effect=RuntimeError("odd")):
            self.assertEqual(self.pause.hook(tool_name="web_search", args={})["action"], "block")

    def hermes_home(self):
        """A Hermes home with a cache folder, and a picture beside it that is not Hermes's to remove."""
        hermes = self.home / "hermes"
        (hermes / "cache" / "screenshots").mkdir(parents=True)
        constants = patch.dict(sys.modules, {"hermes_constants": type(sys)("hermes_constants")})
        constants.start()
        self.addCleanup(constants.stop)
        sys.modules["hermes_constants"].get_hermes_home = lambda: str(hermes)
        inside = hermes / "cache" / "screenshots" / "shot.png"
        outside = self.home / "shot.png"
        for path in (inside, outside):
            path.write_bytes(b"png")
        return inside, outside

    def fill(self):
        record = self.store.create("career", "example.com", "local:dev", "username")
        self.store.approve(record["id"])
        self.store.start(record["id"])
        return record

    def test_a_picture_that_finishes_during_a_fill_is_thrown_away(self):
        inside, outside = self.hermes_home()
        self.fill()
        for result in (f"Took it. MEDIA:{inside}", json.dumps({"ok": True, "screenshot_path": str(inside)})):
            inside.write_bytes(b"png")
            answer = self.pause.result(tool_name="mcp__cua__computer_screenshot", args={}, result=result)
            self.assertTrue(answer.startswith(sign_ins.PAUSED.format(seconds=int(sign_ins.SETTLE))), answer)
            self.assertNotIn(str(inside), answer)
            self.assertFalse(inside.exists())
        # Pictures outside Hermes's cache are never removed, even when the result names them.
        for result in (f"MEDIA:{outside}", json.dumps({"screenshot_path": str(outside)}),
                       f"MEDIA:{inside.parent}/../../../shot.png"):
            self.assertIsNotNone(self.pause.result(tool_name="computer_use", args={"action": "capture"},
                                                   result=result))
            self.assertTrue(outside.exists(), result)
        # Other tools keep their result.
        self.assertIsNone(self.pause.result(tool_name="web_search", args={"query": "x"}, result=f"MEDIA:{inside}"))

    def test_a_picture_with_no_fill_keeps_its_result(self):
        inside, _ = self.hermes_home()
        for result in (f"MEDIA:{inside}", json.dumps({"screenshot_path": str(inside)})):
            self.assertIsNone(self.pause.result(tool_name="mcp__cua__computer_screenshot", args={}, result=result))
            self.assertTrue(inside.exists())


class RecordingsTests(unittest.TestCase):
    """A recording a bot started through a tool keeps request_sign_in from starting until it is stopped."""

    def test_started_and_stopped_by_tool_name(self):
        recordings = sign_ins.Recordings()
        self.assertFalse(recordings.any())
        for start, stop in (("mcp__cua_recorder__start_recording", "mcp__cua_recorder__stop_recording"),
                            ("mcp__x__begin_screen_record", "mcp__x__end_screen_record"),
                            ("mcp__cua_recorder__record", "mcp__cua_recorder__finish_recording"),
                            ("record_start", "record_cancel")):
            with self.subTest(start):
                recordings.post_tool_call(tool_name=start, session_id="s1", status="ok")
                self.assertTrue(recordings.any())
                recordings.post_tool_call(tool_name=stop, session_id="s1", status="ok")
                self.assertFalse(recordings.any())
        # Tools that don't start or stop one are ignored.
        for tool in ("computer_use", "mcp__cua_recorder__list_recordings", "web_search", None):
            recordings.post_tool_call(tool_name=tool, session_id="s1", status="ok")
        self.assertFalse(recordings.any())

    def test_a_start_that_was_blocked_or_failed_does_not_count(self):
        recordings = sign_ins.Recordings()
        for status in ("blocked", "error"):
            recordings.post_tool_call(tool_name="mcp__cua_recorder__start_recording", session_id="s1", status=status)
        self.assertFalse(recordings.any())
        recordings.post_tool_call(tool_name="mcp__cua_recorder__start_recording", session_id="s1", status="ok")
        # A stop that failed leaves it running.
        recordings.post_tool_call(tool_name="mcp__cua_recorder__stop_recording", session_id="s1", status="error")
        self.assertTrue(recordings.any())

    def test_a_recording_in_any_chat_counts(self):
        recordings = sign_ins.Recordings()
        recordings.post_tool_call(tool_name="mcp__cua_recorder__start_recording", session_id="s1", status="ok")
        recordings.post_tool_call(tool_name="mcp__cua_recorder__stop_recording", session_id="s2", status="ok")
        self.assertTrue(recordings.any())

    def test_no_sign_in_while_a_recording_runs(self):
        with TemporaryDirectory() as temp:
            home = Path(temp)
            sign_ins.Store(home).save_sites(["example.com"])
            h = Harness(home, mac={"claim": "mac"})
            recordings = sign_ins.Recordings()
            call = lambda: json.loads(sign_ins.handle(
                {"site": "example.com", "computer": "local:dev"}, store=h.store, bot="career",
                is_private=lambda: False, unattended=lambda: False, ask=h.ask, clock=h.clock, sleep=h.sleep,
                recording=recordings.any))
            recordings.post_tool_call(tool_name="mcp__cua_recorder__start_recording", session_id="s1", status="ok")
            self.assertEqual(call(), {"status": "not_signed_in", "message": sign_ins.MESSAGES["recording"]})
            # Nobody was asked and no request was made.
            self.assertEqual(h.asked, [])
            self.assertEqual(h.store.open_requests(), [])
            recordings.post_tool_call(tool_name="mcp__cua_recorder__stop_recording", session_id="s1", status="ok")
            self.assertEqual(call()["status"], "signed_in")


class RequestStateTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.clock = Clock()
        self.store = sign_ins.Store(self.temp.name, clock=self.clock)

    def test_first_device_to_answer_wins(self):
        record = self.store.create("career", "example.com", "local:dev", "username")
        self.store.claim(record["id"], "iphone")
        self.store.claim(record["id"], "iphone")
        with self.assertRaises(sign_ins.Conflict):
            self.store.claim(record["id"], "mac")
        with self.assertRaises(ValueError):
            self.store.claim(record["id"], "watch")

    def test_steps_happen_in_order_and_once(self):
        record = self.store.create("career", "example.com", "local:dev", "username")
        with self.assertRaises(sign_ins.Conflict):
            self.store.start(record["id"])
        self.store.approve(record["id"])
        self.store.start(record["id"])
        with self.assertRaises(sign_ins.Conflict):
            self.store.start(record["id"])
        self.assertEqual(self.store.expire_unless_filling(record["id"])["state"], "filling")
        with self.assertRaises(ValueError):
            self.store.report(record["id"], "signed_in", "the password was hunter2")
        self.store.report(record["id"], "signed_in")
        with self.assertRaises(sign_ins.Conflict):
            self.store.report(record["id"], "failed", "fill_failed")

    def test_old_requests_cannot_be_started(self):
        record = self.store.create("career", "example.com", "local:dev", "username")
        self.store.approve(record["id"])
        self.clock.now += sign_ins.REQUEST_LIFETIME + 1
        with self.assertRaises(sign_ins.Conflict):
            self.store.start(record["id"])

    def test_request_ids_are_checked_before_any_path_is_built(self):
        for bad in ("../../x", "ABC", "", None):
            with self.assertRaises(LookupError):
                self.store.get(bad)

    def test_request_and_history_files_are_private_to_the_user(self):
        record = self.store.create("career", "example.com", "local:dev", "username")
        self.store.record_use("career", "example.com", "signed_in", "mac", "local:dev")
        for path in (self.store.root / "requests" / (record["id"] + ".json"), self.store.root / "history.jsonl"):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600, path)

    def test_history_keeps_ninety_days_and_hides_private_bots(self):
        self.store.record_use("career", "example.com", "signed_in", "mac", "local:dev")
        self.store.record_use("moss", "example.com", "signed_in", "mac", "local:dev")
        self.clock.now += 91 * 86400
        self.store.record_use("nowhere", "example.com", "declined", None, "mac")
        entries = self.store.history(90, frozenset({"moss"}))
        self.assertEqual([e["bot"] for e in entries], ["nowhere"])
        self.assertEqual(entries[0]["computer"], "mac")
        self.assertEqual(len((self.store.root / "history.jsonl").read_text().splitlines()), 1)

    def test_parallel_claims_have_one_winner(self):
        record = self.store.create("career", "example.com", "local:dev", "username")
        wins = []

        def claim(who):
            with contextlib.suppress(sign_ins.Conflict):
                self.store.claim(record["id"], who)
                wins.append(who)
        threads = [threading.Thread(target=claim, args=(who,)) for who in ("mac", "iphone") * 4]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(len(set(wins)), 1)


@unittest.skipUnless(fastapi, "FastAPI is available in the Hermes runtime")
class RouteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        route_spec = importlib.util.spec_from_file_location("sign_ins_api_test", ROOT / "dashboard/plugin_api.py")
        cls.api = importlib.util.module_from_spec(route_spec)
        route_spec.loader.exec_module(cls.api)

    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        patcher = patch.object(self.api, "home", return_value=self.home)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.store = self.api._sign_ins.Store(self.home)

    def body(self, response):
        self.assertEqual(response.headers["cache-control"], "no-store")
        return json.loads(response.body)

    def status(self, call, *args):
        with self.assertRaises(fastapi.HTTPException) as raised:
            call(*args)
        return raised.exception.status_code

    def test_sites_round_trip_and_bad_sites_are_refused(self):
        self.assertEqual(self.body(self.api.sign_in_sites()), {"sites": []})
        saved = self.api.save_sign_in_sites(self.api.SignInSites(sites=["https://Example.com/", "news.org"]))
        self.assertEqual(self.body(saved), {"sites": ["example.com", "news.org"]})
        self.assertEqual(self.status(self.api.save_sign_in_sites, self.api.SignInSites(sites=["no site"])), 422)
        with self.assertRaises(Exception):
            self.api.SignInSites(sites=["a.com"], passwords=["x"])

    def test_requests_claim_start_and_result(self):
        record = self.store.create("career", "example.com", "local:dev", "username")
        listed = self.body(self.api.sign_in_requests())["requests"]
        self.assertEqual([r["id"] for r in listed], [record["id"]])
        self.assertEqual(set(listed[0]), {"id", "bot", "site", "computer", "focus", "state", "approver", "created_at"})
        claimed = self.body(self.api.claim_sign_in(record["id"], self.api.SignInClaim(approver="iphone")))
        self.assertEqual(claimed["approver"], "iphone")
        self.assertEqual(self.status(self.api.claim_sign_in, record["id"], self.api.SignInClaim(approver="mac")), 409)
        self.assertEqual(self.status(self.api.start_sign_in, record["id"]), 409)
        self.store.approve(record["id"])
        self.assertEqual(self.body(self.api.start_sign_in(record["id"]))["state"], "filling")
        bad = self.api.SignInReport(outcome="failed", reason="the password was wrong: hunter2")
        self.assertEqual(self.status(self.api.report_sign_in, record["id"], bad), 422)
        with self.assertRaises(Exception):
            self.api.SignInReport(outcome="signed_in", password="hunter2")
        done = self.body(self.api.report_sign_in(record["id"], self.api.SignInReport(outcome="signed_in", code_note=True)))
        self.assertEqual(done["state"], "done")
        self.assertEqual(self.body(self.api.sign_in_requests())["requests"], [])
        self.assertEqual(self.status(self.api.get_sign_in_request, "../../etc/passwd"), 404)

    def test_private_bots_requests_are_never_shown(self):
        private_bots.save(self.home, ["career"])
        record = self.store.create("career", "example.com", "local:dev", "username")
        self.assertEqual(self.body(self.api.sign_in_requests())["requests"], [])
        self.assertEqual(self.status(self.api.get_sign_in_request, record["id"]), 404)
        self.assertEqual(self.status(self.api.claim_sign_in, record["id"], self.api.SignInClaim(approver="mac")), 404)

    def test_history_route(self):
        self.store.record_use("career", "example.com", "signed_in", "mac", "local:dev")
        self.store.record_use("moss", "example.com", "signed_in", "mac", "local:dev")
        entries = self.body(self.api.sign_in_history("7"))["entries"]
        self.assertEqual([e["bot"] for e in entries], ["career"])
        self.assertEqual(set(entries[0]), {"at", "bot", "site", "outcome", "approver", "computer"})
        for days in ("0", "91", "x", "7.5"):
            self.assertEqual(self.status(self.api.sign_in_history, days), 422, days)


class RegistrationTests(unittest.TestCase):
    def test_the_tool_has_its_own_toolset(self):
        registered = {}

        class Context:
            def register_tool(self, **kwargs):
                registered.update(kwargs)

            def current_cron_execution(self):
                return None
        with TemporaryDirectory() as temp:
            sign_ins.register(Context(), Path(temp), "career", lambda: False)
        self.assertEqual((registered["name"], registered["toolset"]), ("request_sign_in", "nollie_sign_in"))
        self.assertEqual(registered["schema"], sign_ins.SCHEMA)


if __name__ == "__main__":
    unittest.main()
