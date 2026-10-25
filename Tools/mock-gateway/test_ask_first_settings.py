import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("ask_first_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)
ROUTE = "/api/plugins/nollie-computer/ask-first"


class AskFirstFixtureTests(unittest.TestCase):
    def setUp(self):
        mock.PASSWORD_AUTH["enabled"] = False
        mock.PRIVATE_BOTS["profiles"] = None
        mock.CREATED_PROFILES.clear()
        self.request("/api/_mock/ask-first", "POST")

    def request(self, path, method="GET", body=None, headers=None):
        request = SimpleNamespace(path=path, method=method, body=json.dumps(body or {}).encode(), headers=headers or {})
        return mock.process_request(None, request)

    def state(self, profile):
        response = self.request(ROUTE + "?profile=" + profile)
        return response.status_code, json.loads(response.body)

    def test_choices_are_per_bot_and_can_be_read_back(self):
        self.assertEqual(self.state("work"), (200, {"profile": "work", "enabled": True}))
        changed = self.request(ROUTE + "?profile=work", "PUT", {"enabled": False})
        self.assertEqual(changed.status_code, 200)
        self.assertEqual(json.loads(changed.body), {"profile": "work", "enabled": False})
        self.assertEqual(changed.headers["Cache-Control"], "no-store")
        self.assertFalse(self.state("work")[1]["enabled"])
        self.assertTrue(self.state("default")[1]["enabled"])
        self.request(ROUTE + "?profile=work", "PUT", {"enabled": True})
        self.assertTrue(self.state("work")[1]["enabled"])

    def test_new_bots_start_on_and_fixture_reset_forgets_choices(self):
        self.request("/api/profiles", "POST", {"name": "garden"})
        self.assertTrue(self.state("garden")[1]["enabled"])
        self.request(ROUTE + "?profile=garden", "PUT", {"enabled": False})
        self.request("/api/_mock/ask-first", "POST")
        self.assertTrue(self.state("garden")[1]["enabled"])

    def test_private_bots_unknown_bots_and_invalid_bodies_are_refused(self):
        mock.PRIVATE_BOTS["profiles"] = ["work"]
        for name in ("work", "work-notes", "moss", "private-notes"):
            response = self.request(ROUTE + "?profile=" + name, "PUT", {"enabled": False})
            self.assertEqual(response.status_code, 403)
        self.assertEqual(mock.ASK_FIRST, {})
        self.assertEqual(self.state("missing")[0], 404)
        self.assertEqual(self.state("../work")[0], 422)
        for body in ({}, {"enabled": "false"}, {"enabled": 0}, {"enabled": False, "profile": "work"}):
            self.assertEqual(self.request(ROUTE + "?profile=default", "PUT", body).status_code, 422)
        self.assertEqual(self.request(ROUTE + "?profile=default", "POST", {"enabled": False}).status_code, 405)
        self.assertTrue(self.state("default")[1]["enabled"])

    def test_a_rejected_sign_in_cannot_change_the_switch(self):
        mock.PASSWORD_AUTH["enabled"] = True
        response = self.request(ROUTE + "?profile=work", "PUT", {"enabled": False},
                                {"Authorization": "Bearer expired-fixture"})
        self.assertEqual(response.status_code, 401)
        self.assertEqual(mock.ASK_FIRST, {})


if __name__ == "__main__":
    unittest.main()
