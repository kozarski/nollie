"""Calendar, Reminders and Contacts: the tools, their request files, the rule that every change waits for the
person's yes, Papertrail's local reads, and the routes the Mac and the iPhone use."""
import importlib.util
import json
from pathlib import Path
import re
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
NAME = "apple_data_test_package"
spec = importlib.util.spec_from_file_location(NAME, ROOT / "__init__.py", submodule_search_locations=[str(ROOT)])
package = importlib.util.module_from_spec(spec)
sys.modules[NAME] = package
spec.loader.exec_module(package)
from apple_data_test_package import apple_data, ask_first, papertrail, private_bots, receipts  # noqa: E402

try:
    import fastapi
except ImportError:
    fastapi = None

KEY = re.compile(r"^nollie-ask-first:(calendar|reminders|contacts):[0-9a-f]{32}$")
CARD = "Add “Dentist” on Tue 4 Nov, 10:00 to Home calendar?"


class Clock:
    def __init__(self):
        self.now = 1_800_000_000.0

    def __call__(self):
        return self.now


class Mac:
    """Nollie on the Mac, as the app acts on a request: answers a read, words a change, and makes a change
    only once it is approved. Steps each time the tool sleeps."""

    def __init__(self, store, *, here=True, card=CARD, refuse=None, apply=True):
        self.store, self.here, self.card, self.refuse, self.apply = store, here, card, refuse, apply
        self.made = []

    def step(self):
        if not self.here:
            return
        for record in self.store.open_requests():
            if record["state"] == "prepared":
                continue  # waiting for the person
            if self.refuse:
                self.store.answer(record["id"], error=self.refuse)
            elif record["state"] == "waiting" and record["write"]:
                self.store.prepare(record["id"], self.card)
            elif record["state"] == "waiting":
                self.store.answer(record["id"], result={"events": [{"id": "e1", "title": "Dentist"}]})
            elif record["state"] == "approved" and self.apply:
                self.made.append((record["tool"], record["args"]))
                self.store.answer(record["id"], result={"message": "Added “Dentist”."})


class Harness:
    def __init__(self, home, *, on=("calendar",), private=False, unattended=False, bypassed=False, answer="once",
                 mac=None):
        self.clock = Clock()
        self.store = apple_data.Store(home, clock=self.clock)
        if on:
            self.store.set_bot("career", list(on))
        self.private, self.unattended, self.bypassed, self.answer = private, unattended, bypassed, answer
        self.mac = Mac(self.store, **(mac or {}))
        self.asked = []

    def ask(self, description, rule):
        self.asked.append((description, rule))
        if self.answer is None:
            return {"approved": False, "outcome": "timeout"}
        return {"approved": self.answer == "once"}

    def sleep(self, seconds):
        self.clock.now += seconds
        self.mac.step()

    def call(self, tool, args):
        return json.loads(apple_data.handle(
            tool, args, store=self.store, bot="career", is_private=lambda: self.private,
            unattended=lambda: self.unattended, bypassed=lambda: self.bypassed, ask=self.ask,
            clock=self.clock, sleep=self.sleep))

    def leftovers(self):
        folder = self.store.root / "requests"
        return sorted(p.name for p in folder.glob("*.json")) if folder.is_dir() else []


class ToolTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)

    def test_a_read_comes_back_from_the_mac_and_leaves_nothing_behind(self):
        h = Harness(self.home)
        reply = h.call("calendar_events", {"start": "2026-11-04", "end": "2026-11-05", "colour": "red"})
        self.assertEqual(reply, {"status": "ok", "events": [{"id": "e1", "title": "Dentist"}]})
        self.assertEqual(h.asked, [])
        self.assertEqual(h.leftovers(), [])

    def test_a_change_waits_for_the_yes_and_shows_the_macs_words(self):
        h = Harness(self.home)
        reply = h.call("calendar_add_event", {"title": "Dentist", "start": "2026-11-04T10:00"})
        self.assertEqual(reply["status"], "done")
        [(description, rule)] = h.asked
        self.assertEqual(description, CARD)
        self.assertRegex(rule, KEY)
        self.assertTrue(rule.startswith("nollie-ask-first:calendar:"))
        self.assertEqual(h.mac.made, [("calendar_add_event", {"title": "Dentist", "start": "2026-11-04T10:00"})])
        self.assertEqual(h.leftovers(), [])

    def test_every_change_asks_with_a_fresh_key(self):
        h = Harness(self.home, on=("calendar", "reminders", "contacts"))
        calls = {"calendar_add_event": {"title": "A", "start": "2026-11-04"},
                 "calendar_change_event": {"event_id": "e1", "title": "B"},
                 "calendar_delete_event": {"event_id": "e1"},
                 "reminder_add": {"title": "Milk"}, "reminder_complete": {"reminder_id": "r1"},
                 "reminder_delete": {"reminder_id": "r1"}, "contact_add": {"given_name": "Sam"},
                 "contact_change": {"contact_id": "c1", "add_phone": "07700 900123"}}
        self.assertEqual(set(calls), set(apple_data.WRITES))
        for tool, args in calls.items():
            self.assertEqual(h.call(tool, args)["status"], "done", tool)
        self.assertEqual(len(h.asked), len(calls))
        self.assertEqual(len({rule for _, rule in h.asked}), len(calls))
        self.assertEqual([rule.split(":")[1] for _, rule in h.asked],
                         [apple_data.WRITES[tool] for tool in calls])

    def test_a_no_or_no_answer_changes_nothing(self):
        for answer, status in (("deny", "declined"), (None, "declined")):
            h = Harness(self.home, answer=answer)
            reply = h.call("calendar_delete_event", {"event_id": "e1"})
            self.assertEqual(reply["status"], status)
            self.assertEqual(h.mac.made, [])
            self.assertEqual(h.leftovers(), [])
        self.assertIn("Nobody answered", reply["message"])

    def test_a_run_nobody_can_answer_is_held_never_done(self):
        h = Harness(self.home, unattended=True)
        reply = h.call("calendar_add_event", {"title": "Dentist", "start": "2026-11-04T10:00"})
        self.assertEqual(reply["status"], "blocked")
        self.assertTrue(reply["message"].startswith(ask_first.HELD))
        self.assertIn(CARD, reply["message"])
        self.assertEqual((h.asked, h.mac.made), ([], []))
        self.assertEqual(receipts.block_detail(json.dumps(reply)), receipts.ASK_FIRST)

    def test_reads_still_work_in_a_schedule(self):
        h = Harness(self.home, unattended=True)
        self.assertEqual(h.call("calendar_events", {})["status"], "ok")

    def test_with_approvals_switched_off_a_change_is_refused(self):
        h = Harness(self.home, bypassed=True)
        reply = h.call("calendar_add_event", {"title": "Dentist", "start": "2026-11-04T10:00"})
        self.assertEqual(reply["status"], "blocked")
        self.assertEqual((h.asked, h.mac.made), ([], []))

    def test_a_check_that_fails_counts_as_nobody_there(self):
        h = Harness(self.home)

        def broken():
            raise RuntimeError("no context")
        reply = json.loads(apple_data.handle(
            "reminder_add", {"title": "Milk"}, store=h.store, bot="career", is_private=lambda: False,
            unattended=broken, bypassed=lambda: False, ask=h.ask, clock=h.clock, sleep=h.sleep))
        self.assertEqual(reply["status"], "off")  # reminders is off for this helper
        h.store.set_bot("career", ["reminders"])
        reply = json.loads(apple_data.handle(
            "reminder_add", {"title": "Milk"}, store=h.store, bot="career", is_private=lambda: False,
            unattended=broken, bypassed=lambda: False, ask=h.ask, clock=h.clock, sleep=h.sleep))
        self.assertEqual(reply["status"], "blocked")
        self.assertEqual(h.asked, [])

    def test_a_switch_that_is_off_asks_the_mac_nothing(self):
        h = Harness(self.home, on=("calendar",))
        reply = h.call("contacts_search", {"name": "Sam"})
        self.assertEqual(reply["status"], "off")
        self.assertIn("Contacts is off", reply["message"])
        self.assertEqual(h.leftovers(), [])

    def test_a_private_bot_gets_nothing(self):
        h = Harness(self.home, private=True)
        self.assertEqual(h.call("calendar_events", {})["status"], "refused")
        self.assertEqual(h.leftovers(), [])

    def test_a_closed_mac_or_its_refusal_is_said_plainly(self):
        h = Harness(self.home, mac={"here": False})
        self.assertIn("didn't answer", h.call("calendar_events", {})["message"])
        h = Harness(self.home, mac={"refuse": "Calendar isn't allowed on the Mac yet."})
        reply = h.call("calendar_add_event", {"title": "Dentist", "start": "2026-11-04"})
        self.assertEqual(reply, {"status": "error", "message": "Calendar isn't allowed on the Mac yet."})
        self.assertEqual(h.asked, [])

    def test_a_change_the_mac_never_confirms_is_reported_as_unsure(self):
        h = Harness(self.home, on=("reminders",), mac={"apply": False})
        reply = h.call("reminder_complete", {"reminder_id": "r1"})
        self.assertEqual(reply["status"], "error")
        self.assertIn("may or may not", reply["message"])

    def test_missing_arguments_and_odd_values(self):
        h = Harness(self.home)
        self.assertEqual(h.call("calendar_add_event", {"title": "Dentist"}),
                         {"status": "error", "message": "Send start."})
        cleaned = apple_data.clean("calendar_add_event", {"title": "  Den\n tist ", "start": "2026-11-04",
                                                          "all_day": "yes", "notes": "a\nb", "x": 1})
        self.assertEqual(cleaned, {"title": "Den tist", "start": "2026-11-04", "notes": "a\nb"})
        self.assertEqual(len(apple_data.clean("contacts_search", {"name": "x" * 900})["name"]), 300)


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = apple_data.Store(Path(self.temp.name))

    def test_a_change_cannot_be_made_without_the_yes(self):
        record = self.store.create("career", "calendar_add_event", {"title": "A", "start": "2026-11-04"})
        with self.assertRaises(apple_data.Conflict):
            self.store.answer(record["id"], result={"message": "made"})
        self.store.prepare(record["id"], CARD)
        with self.assertRaises(apple_data.Conflict):
            self.store.answer(record["id"], result={"message": "made"})
        self.store.approve(record["id"])
        self.assertEqual(self.store.answer(record["id"], result={"message": "made"})["state"], "done")

    def test_a_read_is_never_worded_as_a_change(self):
        record = self.store.create("career", "calendar_events", {})
        with self.assertRaises(apple_data.Conflict):
            self.store.prepare(record["id"], CARD)
        with self.assertRaises(apple_data.Conflict):
            self.store.approve(record["id"])

    def test_files_are_private_to_the_person(self):
        self.store.set_bot("career", ["contacts"])
        record = self.store.create("career", "contacts_search", {"name": "Sam"})
        for path in (self.store.root / "bots.json", self.store.root / "requests" / f"{record['id']}.json"):
            self.assertEqual(path.stat().st_mode & 0o777, 0o600, path)
        self.assertEqual(self.store.root.stat().st_mode & 0o777, 0o700)

    def test_switches_round_trip_and_a_damaged_file_turns_everything_off(self):
        self.assertEqual(self.store.set_bot("career", ["contacts", "calendar", "calendar"]), ["calendar", "contacts"])
        self.assertTrue(self.store.enabled("career", "calendar"))
        self.assertFalse(self.store.enabled("career", "reminders"))
        self.store.set_bot("career", [])
        self.assertEqual(self.store.bots(), {})
        with self.assertRaises(ValueError):
            self.store.set_bot("career", ["photos"])
        (self.store.root / "bots.json").write_text("{nope")
        self.assertFalse(self.store.enabled("career", "calendar"))

    def test_the_macs_permissions(self):
        self.assertIsNone(self.store.mac())
        self.store.save_mac({"calendar": "allowed", "contacts": "denied"})
        self.assertEqual(self.store.mac(), {"calendar": "allowed", "reminders": "not_asked", "contacts": "denied"})
        with self.assertRaises(ValueError):
            self.store.save_mac({"calendar": "maybe"})

    def test_old_requests_are_pruned(self):
        clock = Clock()
        store = apple_data.Store(Path(self.temp.name), clock=clock)
        old = store.create("career", "calendar_events", {})
        clock.now += apple_data.REQUEST_LIFETIME + 1
        store.create("career", "calendar_events", {})
        with self.assertRaises(LookupError):
            store.get(old["id"])


class RuleListTests(unittest.TestCase):
    def test_ask_first_leaves_these_to_the_tool_so_nothing_is_asked_twice(self):
        self.assertEqual(ask_first.APPLE_DATA, frozenset(apple_data.TOOLS))
        for tool in apple_data.TOOLS:
            self.assertIsNone(ask_first.classify(tool, {"event_id": "e1"}), tool)

    def test_a_rehearsal_may_read_but_not_change(self):
        for tool in apple_data.READS:
            self.assertTrue(receipts.look_only(tool, {}), tool)
        for tool in apple_data.WRITES:
            self.assertFalse(receipts.look_only(tool, {}), tool)

    def test_every_tool_has_a_schema_in_its_areas_toolset(self):
        self.assertEqual(set(apple_data.SCHEMAS), set(apple_data.TOOLS))
        for tool, schema in apple_data.SCHEMAS.items():
            self.assertEqual(schema["name"], tool)
            self.assertEqual(set(schema["parameters"]["properties"]), set(apple_data.ARGUMENTS[tool]), tool)
            if tool in apple_data.WRITES:
                self.assertIn("asked first", schema["description"], tool)


class PapertrailTests(unittest.TestCase):
    def test_a_local_read_is_kept_and_named_on_the_turn_that_left(self):
        with TemporaryDirectory() as temp:
            home = Path(temp)
            recorder = papertrail.Recorder(home, clock=lambda: 1_800_000_000.0)
            line = recorder._tool("calendar_events", {"start": "x"}, "ok", "t-1", "s-1")
            self.assertEqual((line["route"], line["source"], line["tool"]), ("mac", "tool", "calendar_events"))
            self.assertNotIn("x", json.dumps({k: v for k, v in line.items() if k not in ("tool",)}))
            self.assertIsNone(recorder._tool("calendar_events", {}, "blocked", "t-1", "s-1"))
            model = recorder._call("model", "", "anthropic", "https://api.anthropic.com", "m", "t-1", "s-1",
                                   1_800_000_001.0, {"input_tokens": 10})
            calls = [dict(line, at=1_800_000_000.0, **{"in": 0}), model]
            entry = papertrail._entry(("turn", "t-1"), [papertrail_call(c) for c in calls], lambda _: None)
            self.assertEqual(entry["local_reads"], ["calendar"])
            self.assertEqual(entry["calls"], 1)
            local = papertrail._entry(("turn", "t-2"), [papertrail_call(dict(line, turn="t-2"))], lambda _: None)
            self.assertIsNone(local)


def papertrail_call(line):
    call = {key: line.get(key) or "" for key in ("provider", "model", "task", "tool", "turn", "session")}
    call.update({key: line.get(key, 0) for key in ("in", "out", "cache", "think", "searches", "pages", "images")})
    call.update(at=line["at"], route=line["route"], source=line["source"], host=line.get("host"))
    return call


class RegistrationTests(unittest.TestCase):
    def test_each_area_has_its_own_toolset_and_shows_only_while_on(self):
        registered = {}

        class Context:
            def register_tool(self, **kwargs):
                registered[kwargs["name"]] = kwargs

            def current_cron_execution(self):
                return None

        with TemporaryDirectory() as temp:
            home = Path(temp)
            apple_data.register(Context(), home, "career", lambda: False)
            self.assertEqual(set(registered), set(apple_data.TOOLS))
            self.assertEqual({r["toolset"] for r in registered.values()},
                             {"nollie_calendar", "nollie_reminders", "nollie_contacts"})
            self.assertFalse(registered["calendar_events"]["check_fn"]())
            apple_data.Store(home).set_bot("career", ["calendar"])
            self.assertTrue(registered["calendar_events"]["check_fn"]())
            self.assertFalse(registered["contacts_search"]["check_fn"]())

    def test_a_private_bot_is_never_given_the_tools(self):
        registered = []

        class Context:
            profile_name = "moss"

            def register_tool(self, **kwargs):
                registered.append(kwargs["name"])

            def register_hook(self, *args, **kwargs):
                pass

        with TemporaryDirectory() as temp, patch.object(apple_data, "register",
                                                         side_effect=lambda *a, **k: registered.append(a)):
            package._register_apple_data(Context(), "moss", Path(temp))
            private_bots.save(Path(temp), ["career"])
            package._register_apple_data(Context(), "career", Path(temp))
        self.assertEqual(registered, [])


@unittest.skipUnless(fastapi, "FastAPI is available in the Hermes runtime")
class RouteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        route_spec = importlib.util.spec_from_file_location("apple_data_api_test", ROOT / "dashboard/plugin_api.py")
        cls.api = importlib.util.module_from_spec(route_spec)
        route_spec.loader.exec_module(cls.api)

    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        for name, value in (("home", self.home), ("bot_home", self.home)):
            patcher = patch.object(self.api, name, return_value=value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.store = self.api._apple.Store(self.home)

    def body(self, response):
        self.assertEqual(response.headers["cache-control"], "no-store")
        return json.loads(response.body)

    def status(self, call, *args):
        with self.assertRaises(fastapi.HTTPException) as raised:
            call(*args)
        return raised.exception.status_code

    def test_switches_round_trip_with_the_macs_permissions(self):
        self.assertEqual(self.body(self.api.apple_data_bot("career")), {"bot": "career", "on": [], "mac": None})
        saved = self.api.save_apple_data_bot(self.api.AppleSwitches(bot="career", on=["contacts", "calendar"]))
        self.assertEqual(self.body(saved)["on"], ["calendar", "contacts"])
        self.api.save_apple_data_mac(self.api.AppleAccess(access={"calendar": "allowed"}))
        self.assertEqual(self.body(self.api.apple_data_bot("career"))["mac"]["calendar"], "allowed")
        self.assertEqual(self.status(self.api.save_apple_data_bot, self.api.AppleSwitches(bot="career", on=["x"])), 422)
        self.assertEqual(self.status(self.api.apple_data_bot, "../etc"), 422)

    def test_private_bots_are_refused_and_never_listed(self):
        self.store.set_bot("career", ["calendar"])
        record = self.store.create("career", "calendar_events", {})
        private_bots.save(self.home, ["career"])
        self.assertEqual(self.status(self.api.apple_data_bot, "career"), 403)
        self.assertEqual(self.status(self.api.apple_data_bot, "moss"), 403)
        listed = self.body(self.api.apple_data_requests())
        self.assertEqual(listed, {"requests": [], "bots": {}})
        self.assertEqual(self.status(self.api.answer_apple_data, record["id"],
                                     self.api.AppleAnswer(result={"events": []})), 404)

    def test_the_mac_reads_words_and_answers(self):
        self.store.set_bot("career", ["calendar"])
        read = self.store.create("career", "calendar_events", {"start": "2026-11-04"})
        change = self.store.create("career", "calendar_add_event", {"title": "A", "start": "2026-11-04"})
        listed = self.body(self.api.apple_data_requests())
        self.assertEqual({r["id"] for r in listed["requests"]}, {read["id"], change["id"]})
        self.assertEqual(listed["bots"], {"career": ["calendar"]})
        self.assertEqual(set(listed["requests"][0]), {"id", "bot", "tool", "area", "write", "args", "state",
                                                      "created_at"})
        answered = self.api.answer_apple_data(read["id"], self.api.AppleAnswer(result={"events": []}))
        self.assertEqual(self.body(answered)["state"], "done")
        # A change is worded, never made, until the tool has the person's yes.
        self.assertEqual(self.status(self.api.answer_apple_data, change["id"],
                                     self.api.AppleAnswer(result={"message": "made"})), 409)
        self.assertEqual(self.body(self.api.prepare_apple_data(change["id"], self.api.AppleCard(card=CARD)))["state"],
                         "prepared")
        self.assertEqual([r["state"] for r in self.body(self.api.apple_data_requests())["requests"]], ["prepared"])
        self.assertEqual(self.status(self.api.answer_apple_data, change["id"],
                                     self.api.AppleAnswer(result={"message": "made"})), 409)
        self.store.approve(change["id"])
        self.assertEqual(self.body(self.api.answer_apple_data(change["id"],
                                                              self.api.AppleAnswer(result={"message": "made"})))["state"],
                         "done")
        self.assertEqual(self.status(self.api.answer_apple_data, "../../x", self.api.AppleAnswer(error="no")), 404)
        self.assertEqual(self.status(self.api.answer_apple_data, change["id"], self.api.AppleAnswer()), 422)


if __name__ == "__main__":
    unittest.main()
