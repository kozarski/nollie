import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("bot_looks_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)

PATH = "/api/plugins/nollie-workflow/bot-looks"


class BotLooksFixtureTests(unittest.TestCase):
    def setUp(self):
        mock.PASSWORD_AUTH["enabled"] = False
        self.request("/api/_mock/bot-looks", "POST")
        self.request("/api/_mock/private-bots", "POST")
        self.addCleanup(self.request, "/api/_mock/bot-looks", "POST")
        self.addCleanup(self.request, "/api/_mock/private-bots", "POST")

    def request(self, path=PATH, method="GET", body=None):
        request = SimpleNamespace(path=path, method=method, body=json.dumps(body or {}).encode(), headers={})
        response = mock.process_request(None, request)
        return response.status_code, json.loads(response.body)

    def test_a_look_picked_on_one_device_is_what_the_others_read(self):
        self.assertEqual(self.request(), (200, {"bots": {}, "saved": False}))
        self.assertEqual(self.request(PATH + "/Planner", "PUT", {"look": "duo", "colour": "#aa3311"}),
                         (200, {"bots": {"planner": {"look": "duo", "colour": "#AA3311"}}, "saved": True}))
        self.request(PATH + "/shopper", "PUT", {"look": "swell"})
        self.assertEqual(self.request()[1]["bots"], {"planner": {"look": "duo", "colour": "#AA3311"},
                                                     "shopper": {"look": "swell"}})
        self.assertEqual(self.request(PATH + "/shopper", "PUT", {})[1]["bots"], {"planner": {"look": "duo", "colour": "#AA3311"}})

    def test_private_bots_and_bad_looks_are_refused(self):
        self.assertEqual(self.request(PATH + "/moss", "PUT", {"look": "nite"})[0], 403)
        for body in ({"look": "Duo!"}, {"colour": "blue"}, {"look": 3}):
            self.assertEqual(self.request(PATH + "/planner", "PUT", body)[0], 422, body)
        self.assertEqual(self.request(PATH + "?profile=work")[0], 403)
        self.assertEqual(self.request(), (200, {"bots": {}, "saved": False}))


if __name__ == "__main__":
    unittest.main()
