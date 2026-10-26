import datetime
import importlib
import importlib.util
import json
from pathlib import Path
import re
from types import SimpleNamespace
import unittest


spec = importlib.util.spec_from_file_location("papertrail_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)

ROUTE = "/api/plugins/nollie-workflow/papertrail"
ENTRY_KEYS = ["id", "at", "started_at", "route", "provider", "provider_name", "host", "model", "calls",
              "helpers", "services", "input_tokens", "output_tokens", "cache_read_tokens", "reasoning_tokens",
              "searches", "pages", "images"]
WHY_KEYS = {"origin", "task", "platform", "messages", "backup", "approvals"}
ADDON = Path(__file__).resolve().parents[2] / "Companions/nollie-workflow"
VENDORS = re.compile(r"anthropic|claude|sonnet|opus|haiku|openai|gpt|openrouter|\bnous\b|hermes-4|\bexa\b|"
                     r"gemini|google|llama|qwen|mistral|tavily|firecrawl", re.IGNORECASE)


class PapertrailFixtureTests(unittest.TestCase):
    def setUp(self):
        mock.PASSWORD_AUTH["enabled"] = False
        mock.PRIVATE_BOTS["profiles"] = None
        mock.PAPERTRAIL["state"] = "busy"
        mock.NEUTRAL_MODELS = False

    def tearDown(self):
        mock.PRIVATE_BOTS["profiles"] = None
        mock.PAPERTRAIL["state"] = "busy"
        mock.CREATED_PROFILES.clear()
        mock.NEUTRAL_MODELS = False

    def request(self, path=ROUTE, method="GET", body=None):
        request = SimpleNamespace(path=path, method=method, body=json.dumps(body or {}).encode(), headers={})
        return mock.process_request(None, request)

    def get(self, query=""):
        response = self.request(ROUTE + query)
        return response.status_code, json.loads(response.body)

    def test_default_week_has_the_spec_shape(self):
        response = self.request(ROUTE)
        body = json.loads(response.body)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["Cache-Control"], "no-store")
        self.assertEqual(list(body), ["bot", "days", "now", "today_starts_at", "tomorrow_starts_at", "since", "recording_since",
                                      "stayed", "left", "entries", "more"])
        self.assertEqual((body["bot"], body["days"], body["more"]), ("default", 7, 0))
        # Entries kept before 1.1 have no reason; the rest carry it last.
        self.assertTrue(all(list(entry) in (ENTRY_KEYS, ENTRY_KEYS + ["why"]) for entry in body["entries"]))
        times = [entry["at"] for entry in body["entries"]]
        self.assertEqual(times, sorted(times, reverse=True))
        self.assertTrue(all(body["since"] <= at <= body["now"] for at in times))
        self.assertLess(body["recording_since"], body["since"])
        self.assertEqual(body["left"]["window"], len(body["entries"]))
        routes = {entry["route"] for entry in body["entries"]}
        self.assertEqual(routes, {"online", "network"})
        search_only = [e for e in body["entries"] if e["provider"] is None]
        self.assertTrue(search_only and all(e["model"] is None and e["searches"] for e in search_only))
        self.assertTrue(any(e["helpers"] for e in body["entries"]))
        network = next(e for e in body["entries"] if e["route"] == "network")
        self.assertEqual(network["host"], "http://192.168.1.40:8080")

    def test_today_is_split_from_the_rest_of_the_week(self):
        _, body = self.get()
        midnight = datetime.datetime.combine(datetime.date.fromtimestamp(body["now"]), datetime.time()).timestamp()
        self.assertEqual(body["today_starts_at"], int(midnight))
        today = [e for e in body["entries"] if e["at"] >= body["today_starts_at"]]
        self.assertEqual(body["left"]["today"], len(today))
        self.assertGreater(len(today), 1)
        self.assertGreater(len(body["entries"]), len(today))
        self.assertGreater(body["stayed"]["today"], 0)
        self.assertGreater(body["stayed"]["window"], body["stayed"]["today"])

    def test_today_still_has_rows_just_after_midnight(self):
        midnight = datetime.datetime.combine(datetime.date.today(), datetime.time()).timestamp()
        for seconds in (0, 0.3, 0.95, 120):
            body = mock.papertrail_view("default", 7, now=midnight + seconds)
            today = [e for e in body["entries"] if e["at"] >= body["today_starts_at"]]
            self.assertEqual(len(today), body["left"]["today"], seconds)
            self.assertGreater(len(today), 1, seconds)
            self.assertTrue(all(e["started_at"] <= e["at"] <= body["now"] for e in today), seconds)

    def test_days_widens_the_window(self):
        _, week = self.get()
        _, one = self.get("?days=1")
        _, fortnight = self.get("?bot=default&days=14")
        self.assertEqual(one["left"]["window"], one["left"]["today"])
        self.assertEqual(one["since"], one["today_starts_at"])
        self.assertGreater(fortnight["left"]["window"], week["left"]["window"])
        self.assertGreater(fortnight["stayed"]["window"], week["stayed"]["window"])

    def test_work_has_a_lighter_week(self):
        status, work = self.get("?bot=work")
        _, default = self.get()
        self.assertEqual((status, work["bot"]), (200, "work"))
        self.assertGreater(work["left"]["today"], 0)
        self.assertLess(work["left"]["window"], default["left"]["window"])

    def test_private_bots_are_refused(self):
        for name in ("private", "moss"):
            self.assertEqual(self.get(f"?bot={name}"), (403, {"detail": "Papertrail is not kept for private bots."}))
        mock.PRIVATE_BOTS["profiles"] = ["work"]
        self.assertEqual(self.get("?bot=work")[0], 403)
        # The carried-over names always count, as in the add-on.
        self.assertEqual(self.get("?bot=moss")[0], 403)
        self.assertEqual(self.get("?bot=moss-2")[0], 403)

    def test_bots_without_papertrail_and_unknown_bots_are_404(self):
        mock.crew_member("Scout")
        self.assertEqual(self.get("?bot=scout"), (404, {"detail": "Papertrail is not on for this bot."}))
        self.assertEqual(self.get("?bot=nobody"), (404, {"detail": "No such bot."}))

    def test_malformed_requests_are_422(self):
        for query in ("?bot=", "?bot=Work", "?bot=a%2Fb", "?days=0", "?days=36", "?days=seven", "?days="):
            self.assertEqual(self.get(query)[0], 422, query)

    def test_other_profiles_are_refused_like_the_workflow_routes(self):
        self.assertEqual(self.get("?profile=work"), (403, {"detail": "Board follow-through belongs to Nollie."}))
        self.assertEqual(self.get("?profile=default&bot=work")[0], 200)

    def test_control_route_switches_the_default_bot(self):
        response = self.request("/api/_mock/papertrail", "POST", {"state": "empty"})
        self.assertEqual((response.status_code, json.loads(response.body)), (200, {"state": "empty"}))
        status, body = self.get()
        self.assertEqual((status, body["entries"], body["left"]), (200, [], {"today": 0, "window": 0}))
        self.assertGreater(body["stayed"]["window"], 0)
        self.assertIsNotNone(body["recording_since"])
        self.assertGreater(self.get("?bot=work")[1]["left"]["window"], 0)

        self.request("/api/_mock/papertrail", "POST", {"state": "off"})
        self.assertEqual(self.get(), (404, {"detail": "Papertrail is not on for this bot."}))
        self.assertEqual(self.get("?bot=work")[0], 200)

        self.assertEqual(self.request("/api/_mock/papertrail", "POST", {"state": "loud"}).status_code, 422)
        self.request("/api/_mock/papertrail", "POST", {"state": "busy"})
        self.assertTrue(self.get()[1]["entries"])

    def test_reasons_have_the_add_ons_shape_and_some_entries_have_none(self):
        _, body = self.get("?days=35")
        whys = [entry.get("why") for entry in body["entries"]]
        self.assertIn(None, whys)  # The app's fallback for an entry kept before reasons were.
        kept = [why for why in whys if why]
        self.assertEqual({why["origin"] for why in kept}, {"chat", "schedule", "board", "helper"})
        self.assertTrue(any(why["backup"] for why in kept) and any(why["platform"] for why in kept))
        for entry in body["entries"]:
            why = entry.get("why")
            if not why:
                continue
            self.assertEqual(set(why), WHY_KEYS)
            for answer in why["approvals"]:
                self.assertEqual(set(answer), {"at", "choice", "ask"})
                self.assertTrue(entry["started_at"] <= answer["at"] <= entry["at"])
                self.assertIn(answer["choice"], {"once", "session", "always", "deny"})
        self.assertEqual({a["choice"] for why in kept for a in why["approvals"]}, {"once", "deny"})

    def test_reasons_match_what_the_add_on_builds(self):
        spec = importlib.util.spec_from_file_location("papertrail_addon_for_mock", ADDON / "__init__.py",
                                                      submodule_search_locations=[str(ADDON)])
        package = importlib.util.module_from_spec(spec)
        import sys
        sys.modules[spec.name] = package
        spec.loader.exec_module(package)
        papertrail = importlib.import_module(spec.name + ".papertrail")
        call = dict(at=10.0, route="online", source="model", origin="chat", platform="", messages=3, backup=False,
                    job="", board="", choice="", ask="")
        built = papertrail._why([call], [call], {})
        self.assertEqual(set(built), WHY_KEYS)

    def test_neutral_bodies_name_no_vendor_and_online_routes_never_read_local(self):
        mock.NEUTRAL_MODELS = True
        for bot in ("default", "work"):
            response = self.request(f"{ROUTE}?bot={bot}&days=35")
            text = response.body.decode()
            self.assertIsNone(VENDORS.search(text), text)
            for entry in json.loads(text)["entries"]:
                route = " ".join(str(entry[k] or "") for k in ("provider", "provider_name", "model"))
                self.assertTrue(entry["route"] != "online" or "local" not in route.lower(), entry)
                self.assertTrue(all(service and "local" not in service for service in entry["services"]))


if __name__ == "__main__":
    unittest.main()
