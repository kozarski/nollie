"""Paying with saved cards: the tool, its request files, the Mac's rules carried through it, the picture pause,
Papertrail's payment lines, and the routes the Mac and the iPhone use. Only a payment provider's published test
card (4242 4242 4242 4242) appears here, and only to prove it never reaches the helper."""
import importlib.util
import json
from pathlib import Path
import re
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
NAME = "payments_test_package"
spec = importlib.util.spec_from_file_location(NAME, ROOT / "__init__.py", submodule_search_locations=[str(ROOT)])
package = importlib.util.module_from_spec(spec)
sys.modules[NAME] = package
spec.loader.exec_module(package)
from payments_test_package import ask_first, papertrail, payments, private_bots, sign_ins  # noqa: E402

try:
    import fastapi
except ImportError:
    fastapi = None

TEST_NUMBER = "4242424242424242"
KEY = re.compile(r"^nollie-ask-first:buy:[0-9a-f]{32}$")
WORDS = "Pay £48.99 to shop.example.com with Visa ending 4242.\nYour Mac asks for the security code first."
CARDS = [{"id": "card-1", "brand": "visa", "last4": "4242", "holder": "Sam Example"}]


class Clock:
    def __init__(self):
        self.now = 1_800_000_000.0

    def __call__(self):
        return self.now


class Mac:
    """Nollie on the Mac, as the app answers a payment: its rules ask or spare the card, or refuse; after the yes the
    person types the security code and the Mac types the card. It holds the number; the add-on never does."""

    def __init__(self, store, *, here=True, ask=True, refuse=None, expected=None, outcome="paid", reason=None,
                 showing=False, confirm=True):
        self.store, self.here, self.ask, self.refuse, self.expected = store, here, ask, refuse, expected
        self.outcome, self.reason, self.showing, self.confirm = outcome, reason, showing, confirm
        self.typed = []
        self.number = TEST_NUMBER

    def step(self):
        if not self.here:
            return
        for record in self.store.open_requests():
            if record["state"] == "waiting":
                if self.refuse:
                    self.store.refuse(record["id"], self.refuse, self.expected)
                else:
                    self.store.prepare(record["id"], WORDS, "Visa ending 4242", self.ask)
            elif record["state"] == "approved" and self.confirm:
                if self.outcome == "paid":
                    self.store.start(record["id"])
                    self.typed.append(self.number)
                self.store.report(record["id"], self.outcome, self.reason, self.showing and self.outcome == "paid")


class Harness:
    count = 0

    def __init__(self, home, *, allowed=True, cards=CARDS, private=False, unattended=False, bypassed=False,
                 answer="once", mac=None):
        self.clock = Clock()
        # A home of its own each time, so one harness's switches and cards never carry over to the next.
        Harness.count += 1
        self.store = payments.Store(Path(home) / f"home-{Harness.count}", clock=self.clock)
        if allowed:
            self.store.set_bot("career", True)
        if cards:
            self.store.save_cards(cards)
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

    def call(self, args=None):
        args = {"site": "https://Shop.Example.com/checkout", "total": "48.99", "currency": "gbp",
                "computer": "local:dev"} if args is None else args
        raw = payments.handle(args, store=self.store, bot="career", is_private=lambda: self.private,
                              unattended=lambda: self.unattended, bypassed=lambda: self.bypassed, ask=self.ask,
                              clock=self.clock, sleep=self.sleep)
        self.raw = raw
        return json.loads(raw)


class ToolTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)

    def assertNoNumber(self, text):
        digits = re.sub(r"[^0-9]", "", text)
        self.assertNotIn(TEST_NUMBER, digits)
        self.assertNotIn(TEST_NUMBER[:8], digits)

    def test_a_payment_asks_on_the_buy_card_then_the_mac_fills_it(self):
        h = Harness(self.home)
        reply = h.call()
        self.assertEqual(reply["status"], "paid")
        self.assertEqual(reply["card"], "Visa ending 4242")
        self.assertIn("£48.99", reply["message"])
        self.assertIn("shop.example.com", reply["message"])
        [(description, rule)] = h.asked
        self.assertEqual(description, WORDS)
        self.assertRegex(rule, KEY)
        self.assertEqual(h.mac.typed, [TEST_NUMBER])
        self.assertNoNumber(h.raw)
        [entry] = h.store.history()
        self.assertEqual((entry["site"], entry["card"], entry["outcome"], entry["approver"]),
                         ("shop.example.com", "4242", "paid", "card"))
        self.assertNoNumber((h.store.root / "history.jsonl").read_text())

    def test_every_payment_gets_a_fresh_key(self):
        h = Harness(self.home)
        h.call()
        h.call()
        self.assertEqual(len({rule for _, rule in h.asked}), 2)

    def test_the_macs_quick_pay_rule_spares_the_card_but_the_mac_still_confirms(self):
        h = Harness(self.home, mac={"ask": False})
        reply = h.call()
        self.assertEqual(reply["status"], "paid")
        self.assertEqual(h.asked, [])
        self.assertEqual(h.store.history()[0]["approver"], "quick")

    def test_a_no_or_no_answer_pays_nothing(self):
        for answer, outcome in (("deny", "declined"), (None, "no_answer")):
            h = Harness(self.home, answer=answer)
            reply = h.call()
            self.assertEqual(reply["status"], "declined")
            self.assertEqual(h.mac.typed, [])
            self.assertEqual(h.store.history()[0]["outcome"], outcome)

    def test_nobody_at_the_mac_pays_nothing(self):
        h = Harness(self.home, mac={"confirm": False})
        reply = h.call()
        self.assertEqual(reply["status"], "not_paid")
        self.assertIn("Nobody confirmed on the Mac", reply["message"])
        self.assertEqual(h.mac.typed, [])

    def test_the_mac_closed_pays_nothing_and_asks_nobody(self):
        h = Harness(self.home, mac={"here": False})
        reply = h.call()
        self.assertEqual(reply["status"], "not_paid")
        self.assertEqual(h.asked, [])

    def test_a_currency_the_person_does_not_pay_in_is_refused_before_asking(self):
        h = Harness(self.home, mac={"refuse": "currency", "expected": "GBP"})
        reply = h.call({"site": "shop.example.com", "total": "48.99", "currency": "USD", "computer": "local:dev"})
        self.assertEqual(reply["status"], "not_paid")
        self.assertIn("pays in GBP", reply["message"])
        self.assertIn("USD", reply["message"])
        self.assertEqual(h.asked, [])

    def test_a_total_the_screen_does_not_show_aborts_with_nothing_typed(self):
        h = Harness(self.home, mac={"outcome": "failed", "reason": "total_not_shown"})
        reply = h.call()
        self.assertEqual(reply["status"], "not_paid")
        self.assertIn("didn't show £48.99", reply["message"])
        self.assertEqual(h.mac.typed, [])

    def test_a_payment_changed_after_the_card_aborts(self):
        h = Harness(self.home, mac={"outcome": "failed", "reason": "changed"})
        self.assertIn("changed after the person was asked", h.call()["message"])

    def test_private_bots_unattended_runs_and_switched_off_helpers_never_pay(self):
        for options, status in (({"private": True}, "refused"), ({"allowed": False}, "not_paid"),
                                ({"unattended": True}, "blocked"), ({"bypassed": True}, "blocked")):
            h = Harness(self.home, **options)
            reply = h.call()
            self.assertEqual(reply["status"], status, options)
            self.assertEqual(h.asked, [])
            self.assertEqual(h.mac.typed, [])
        held = Harness(self.home, unattended=True).call()
        self.assertTrue(held["message"].startswith(ask_first.HELD))

    def test_a_damaged_private_list_refuses(self):
        h = Harness(self.home)

        def broken():
            raise ValueError("damaged")
        raw = payments.handle({"site": "shop.example.com", "total": "1", "currency": "GBP", "computer": "local:dev"},
                              store=h.store, bot="career", is_private=broken, unattended=lambda: False,
                              bypassed=lambda: False, ask=h.ask, clock=h.clock, sleep=h.sleep)
        self.assertEqual(json.loads(raw)["status"], "refused")

    def test_bad_arguments_are_refused_before_anyone_is_asked(self):
        h = Harness(self.home)
        base = {"site": "shop.example.com", "total": "48.99", "currency": "GBP", "computer": "local:dev"}
        for change in ({"site": "192.168.1.1"}, {"site": "shop.example.com@evil.net"}, {"total": "-5"},
                       {"total": "48.999"}, {"total": "0"}, {"total": "1e3"}, {"total": True}, {"currency": "£"},
                       {"computer": "local:../x"}, {"computer": "mac"}, {"card": "1111"}):
            reply = h.call({**base, **change})
            self.assertEqual(reply["status"], "not_paid", change)
        self.assertEqual(h.asked, [])
        self.assertEqual(Harness(self.home, cards=[]).call()["status"], "not_paid")

    def test_cleaning_amounts_currencies_and_cards(self):
        self.assertEqual(payments.clean_total("48.99"), "48.99")
        self.assertEqual(payments.clean_total("1,048.5"), "1048.50")
        self.assertEqual(payments.clean_total(20), "20.00")
        self.assertIsNone(payments.clean_total("100001"))
        self.assertEqual(payments.clean_currency(" gbp "), "GBP")
        self.assertIsNone(payments.clean_currency("pounds"))
        self.assertEqual(payments.clean_last4("Visa ending 4242"), "4242")

    def test_the_mac_can_only_send_labels(self):
        store = payments.Store(self.home)
        for card in ({"id": "c", "brand": "visa", "last4": "4242", "number": TEST_NUMBER},
                     {"id": "c", "brand": "visa", "last4": TEST_NUMBER},
                     {"id": "c", "brand": "visa", "last4": "4242", "holder": "Sam " + TEST_NUMBER},
                     {"id": "c", "brand": "rocket", "last4": "4242"}):
            with self.assertRaises(ValueError, msg=card):
                store.save_cards([card])
        record = store.create("career", "shop.example.com", "48.99", "GBP", "local:dev")
        for label in ("Visa ending " + TEST_NUMBER, TEST_NUMBER, "Visa"):
            with self.assertRaises(ValueError, msg=label):
                store.prepare(record["id"], WORDS, label, True)
        with self.assertRaises(ValueError):
            store.prepare(record["id"], "x" * 500, "Visa ending 4242", True)

    def test_paid_needs_typing_first(self):
        store = payments.Store(self.home)
        record = store.create("career", "shop.example.com", "48.99", "GBP", "local:dev")
        store.prepare(record["id"], WORDS, "Visa ending 4242", True)
        store.approve(record["id"], "card")
        with self.assertRaises(payments.Conflict):
            store.report(record["id"], "paid")
        store.start(record["id"])
        with self.assertRaises(payments.Conflict):
            store.start(record["id"])
        self.assertEqual(store.report(record["id"], "paid")["state"], "done")


class PicturePauseTests(unittest.TestCase):
    def test_pictures_pause_while_a_card_is_typed_and_while_the_number_shows(self):
        with TemporaryDirectory() as temp:
            home = Path(temp)
            clock = Clock()
            store = payments.Store(home, clock=clock)
            record = store.create("career", "shop.example.com", "48.99", "GBP", "local:dev")
            self.assertEqual(sign_ins.typing_now(home, clock), [])
            store.prepare(record["id"], WORDS, "Visa ending 4242", True)
            store.approve(record["id"], "card")
            self.assertEqual(sign_ins.typing_now(home, clock), [])
            store.start(record["id"])
            self.assertEqual(len(sign_ins.typing_now(home, clock)), 1)
            store.report(record["id"], "paid", showing=True)
            clock.now += 600
            self.assertEqual(len(sign_ins.typing_now(home, clock)), 1, "still paused while the number shows")
            pause = sign_ins.PicturePause(home, clock)
            self.assertEqual(pause.hook("mcp__cua__computer_screenshot", {})["action"], "block")
            store.clear(record["id"])
            self.assertEqual(len(sign_ins.typing_now(home, clock)), 1, "and for a moment after")
            clock.now += sign_ins.SETTLE + 1
            self.assertEqual(sign_ins.typing_now(home, clock), [])

    def test_a_damaged_payment_file_pauses_pictures(self):
        with TemporaryDirectory() as temp:
            home = Path(temp)
            folder = home / "nollie-workflow" / "payments" / "requests"
            folder.mkdir(parents=True)
            (folder / ("a" * 32 + ".json")).write_text("{")
            self.assertEqual(len(sign_ins.typing_now(home)), 1)

    def test_the_computer_preview_pauses_too(self):
        path = ROOT.parent / "nollie-computer" / "dashboard" / "preview_core.py"
        preview_spec = importlib.util.spec_from_file_location("payments_preview_core", path)
        preview = importlib.util.module_from_spec(preview_spec)
        preview_spec.loader.exec_module(preview)
        with TemporaryDirectory() as temp:
            home = Path(temp)
            clock = Clock()
            store = payments.Store(home, clock=clock)
            record = store.create("career", "shop.example.com", "48.99", "GBP", "local:dev")
            self.assertFalse(preview.sign_in_typing(home, clock()))
            store.prepare(record["id"], WORDS, "Visa ending 4242", True)
            store.approve(record["id"], "card")
            store.start(record["id"])
            self.assertTrue(preview.sign_in_typing(home, clock()))


class AskFirstTests(unittest.TestCase):
    def test_the_tools_ask_for_themselves_so_ask_first_never_asks_twice(self):
        self.assertIsNone(ask_first.classify("request_payment", {"site": "shop.example.com", "total": "48.99"}))
        self.assertIsNone(ask_first.classify("payment_cards", {}))
        # Anything else named for paying still asks.
        self.assertEqual(ask_first.classify("stripe_pay_invoice", {"invoice": "in_1"}).kind, "buy")


class PapertrailTests(unittest.TestCase):
    def test_a_payment_shows_the_site_and_the_last_four_only(self):
        with TemporaryDirectory() as temp:
            recorder = papertrail.Recorder(Path(temp), is_private=lambda: False)
            args = {"site": "https://shop.example.com/pay", "total": "48.99", "currency": "GBP", "computer": "local:dev"}
            result = json.dumps({"status": "paid", "message": "Nollie filled in Visa ending 4242", "card": "Visa ending 4242"})
            line = recorder._tool("request_payment", args, "ok", "t-1", "s-1", result)
            self.assertEqual((line["route"], line["host"], line["card"], line["paid"]),
                             ("online", "shop.example.com", "4242", 1))
            self.assertNotIn("48.99", json.dumps(line))
            for status, answer in (("blocked", result), ("ok", json.dumps({"status": "declined"})), ("ok", "nonsense")):
                self.assertIsNone(recorder._tool("request_payment", args, status, "t-1", "s-1", answer))
            model = recorder._call("model", "", "anthropic", "https://api.anthropic.com", "m", "t-1", "s-1",
                                   1_800_000_001.0, {"input_tokens": 10})
            calls = [dict(line, at=1_800_000_000.0), model]
            path = Path(temp) / "day.jsonl"
            path.write_text("\n".join(json.dumps(c) for c in calls))
            parsed = list(papertrail._calls(path, 0))
            entry = papertrail._entry(("turn", "t-1"), parsed, lambda _: None)
            self.assertEqual(entry["payments"], [{"site": "shop.example.com", "card": "4242"}])


class RegistrationTests(unittest.TestCase):
    def test_the_tools_show_only_while_the_switch_is_on(self):
        registered = {}

        class Context:
            def register_tool(self, **kwargs):
                registered[kwargs["name"]] = kwargs

            def current_cron_execution(self):
                return None

        with TemporaryDirectory() as temp:
            home = Path(temp)
            payments.register(Context(), home, "career", lambda: False)
            self.assertEqual(set(registered), {"request_payment", "payment_cards"})
            self.assertEqual({r["toolset"] for r in registered.values()}, {"nollie_payments"})
            self.assertFalse(registered["request_payment"]["check_fn"]())
            payments.Store(home).set_bot("career", True)
            self.assertTrue(registered["request_payment"]["check_fn"]())

    def test_a_private_bot_is_never_given_the_tools(self):
        registered = []

        class Context:
            def register_tool(self, **kwargs):
                registered.append(kwargs["name"])

        with TemporaryDirectory() as temp, patch.object(payments, "register",
                                                         side_effect=lambda *a, **k: registered.append(a)):
            package._register_payments(Context(), "moss", Path(temp))
            private_bots.save(Path(temp), ["career"])
            package._register_payments(Context(), "career", Path(temp))
        self.assertEqual(registered, [])

    def test_payment_cards_lists_labels_and_names_only(self):
        with TemporaryDirectory() as temp:
            store = payments.Store(Path(temp))
            store.save_cards(CARDS)
            off = json.loads(payments.list_cards(store=store, bot="career", is_private=lambda: False))
            self.assertEqual(off["status"], "off")
            store.set_bot("career", True)
            listed = json.loads(payments.list_cards(store=store, bot="career", is_private=lambda: False))
            self.assertEqual(listed["cards"], [{"card": "Visa ending 4242", "name_on_card": "Sam Example"}])
            refused = json.loads(payments.list_cards(store=store, bot="career", is_private=lambda: True))
            self.assertEqual(refused["status"], "refused")


@unittest.skipUnless(fastapi, "FastAPI is available in the Hermes runtime")
class RouteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        route_spec = importlib.util.spec_from_file_location("payments_api_test", ROOT / "dashboard/plugin_api.py")
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
        self.store = self.api._payments.Store(self.home)

    def body(self, response):
        self.assertEqual(response.headers["cache-control"], "no-store")
        return json.loads(response.body)

    def status(self, call, *args):
        with self.assertRaises(fastapi.HTTPException) as raised:
            call(*args)
        return raised.exception.status_code

    def test_cards_and_switches_round_trip(self):
        saved = self.api.save_payment_cards(self.api.PaymentCards(cards=CARDS))
        self.assertEqual(self.body(saved)["cards"], CARDS)
        self.assertEqual(self.body(self.api.payment_cards())["cards"], CARDS)
        number = dict(CARDS[0], number=TEST_NUMBER)
        self.assertEqual(self.status(self.api.save_payment_cards, self.api.PaymentCards(cards=[number])), 422)
        self.assertEqual(self.body(self.api.payment_bot_switch("career")), {"bot": "career", "on": False})
        on = self.api.save_payment_bot_switch(self.api.PaymentSwitch(bot="career", on=True))
        self.assertEqual(self.body(on), {"bot": "career", "on": True})
        self.assertEqual(self.status(self.api.payment_bot_switch, "../etc"), 422)

    def test_private_bots_are_refused_and_never_listed(self):
        self.store.set_bot("career", True)
        record = self.store.create("career", "shop.example.com", "48.99", "GBP", "local:dev")
        private_bots.save(self.home, ["career"])
        self.assertEqual(self.status(self.api.payment_bot_switch, "career"), 403)
        self.assertEqual(self.status(self.api.save_payment_bot_switch,
                                     self.api.PaymentSwitch(bot="moss", on=True)), 403)
        self.assertEqual(self.body(self.api.payment_requests()), {"requests": [], "bots": []})
        self.assertEqual(self.status(self.api.prepare_payment, record["id"],
                                     self.api.PaymentWords(words=WORDS, card="Visa ending 4242", ask=False)), 404)

    def test_the_mac_words_starts_reports_and_clears(self):
        record = self.store.create("career", "shop.example.com", "48.99", "GBP", "local:dev")
        listed = self.body(self.api.payment_requests())["requests"]
        self.assertEqual(set(listed[0]), {"id", "bot", "site", "total", "currency", "card", "computer", "state", "ask",
                                          "approver", "created_at"})
        prepared = self.api.prepare_payment(record["id"], self.api.PaymentWords(words=WORDS, card="Visa ending 4242",
                                                                                ask=True))
        self.assertEqual(self.body(prepared)["state"], "prepared")
        # Nothing is typed before the person's yes.
        self.assertEqual(self.status(self.api.start_payment, record["id"]), 409)
        self.store.approve(record["id"], "card")
        self.assertEqual(self.body(self.api.start_payment(record["id"]))["state"], "filling")
        shown = self.api.report_payment(record["id"], self.api.PaymentReport(outcome="paid", showing=True))
        self.assertEqual(self.body(shown)["state"], "showing")
        self.assertEqual(self.body(self.api.clear_payment(record["id"]))["state"], "done")
        self.assertEqual(self.status(self.api.report_payment, record["id"],
                                     self.api.PaymentReport(outcome="paid", reason="free text")), 422)
        other = self.store.create("career", "shop.example.com", "5.00", "USD", "local:dev")
        refused = self.api.refuse_payment(other["id"], self.api.PaymentRefusal(reason="currency", expected="GBP"))
        self.assertEqual(self.body(refused)["state"], "done")
        self.assertEqual(self.status(self.api.get_payment_request, "../../x"), 404)


if __name__ == "__main__":
    unittest.main()
