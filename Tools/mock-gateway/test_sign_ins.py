import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("sign_ins_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)

PATH = "/api/plugins/nollie-workflow/sign-ins"


class SignInsFixtureTests(unittest.TestCase):
    def setUp(self):
        mock.PASSWORD_AUTH["enabled"] = False
        self.request("/api/_mock/sign-ins", "POST", {"sites": ["example.com"], "history": False})
        self.request("/api/_mock/private-bots", "POST")

    def tearDown(self):
        mock.sign_ins_reset()
        self.request("/api/_mock/private-bots", "POST")

    def request(self, path, method="GET", body=None):
        request = SimpleNamespace(path=path, method=method, body=json.dumps(body or {}).encode(), headers={})
        response = mock.process_request(None, request)
        return response.status_code, json.loads(response.body)

    def open_request(self, bot="work", site="example.com"):
        record = {"id": "a" * 32, "bot": bot, "site": site, "computer": "local:dev", "focus": "username",
                  "state": "asking", "approver": None, "outcome": None, "reason": None, "code_note": False,
                  "created_at": 1}
        mock.SIGN_INS["requests"][record["id"]] = record
        return record

    def test_sites_hold_hosts_only(self):
        self.assertEqual(self.request(PATH + "/sites"), (200, {"sites": ["example.com"]}))
        self.assertEqual(self.request(PATH + "/sites", "PUT", {"sites": ["News.org", "news.org", "example.com"]}),
                         (200, {"sites": ["example.com", "news.org"]}))
        for body in ({"sites": ["no site"]}, {"sites": "a.com"}, {"sites": ["10.0.0.1"]}, {"sites": ["a.com"], "passwords": ["x"]}):
            self.assertEqual(self.request(PATH + "/sites", "PUT", body)[0], 422, body)
        self.assertEqual(self.request(PATH + "/sites?profile=work")[0], 403)

    def test_a_request_is_claimed_once_started_once_and_reported_in_fixed_words(self):
        record = self.open_request()
        self.assertEqual([r["id"] for r in self.request(PATH + "/requests")[1]["requests"]], [record["id"]])
        url = f"{PATH}/requests/{record['id']}"
        self.assertEqual(self.request(url + "/claim", "POST", {"approver": "iphone"})[1]["approver"], "iphone")
        self.assertEqual(self.request(url + "/claim", "POST", {"approver": "mac"})[0], 409)
        self.assertEqual(self.request(url + "/start", "POST")[0], 409)
        record["state"] = "approved"
        self.assertEqual(self.request(url + "/start", "POST")[1]["state"], "filling")
        self.assertEqual(self.request(url + "/result", "POST", {"outcome": "signed_in", "password": "x"})[0], 422)
        self.assertEqual(self.request(url + "/result", "POST", {"outcome": "failed", "reason": "it was hunter2"})[0], 422)
        self.assertEqual(self.request(url + "/result", "POST", {"outcome": "signed_in", "code_note": True})[1]["state"], "done")
        self.assertEqual(self.request(PATH + "/requests")[1]["requests"], [])

    def test_private_bots_requests_and_history_are_hidden(self):
        record = self.open_request(bot="moss")
        mock.SIGN_INS["history"].append({"at": int(mock.time.time()), "bot": "moss", "site": "example.com",
                                         "outcome": "signed_in", "approver": "mac", "computer": "space"})
        self.assertEqual(self.request(PATH + "/requests")[1]["requests"], [])
        self.assertEqual(self.request(f"{PATH}/requests/{record['id']}")[0], 404)
        self.assertEqual(self.request(PATH + "/history")[1]["entries"], [])

    def test_history_has_no_secrets_and_checks_days(self):
        self.request("/api/_mock/sign-ins", "POST", {"history": True})
        entries = self.request(PATH + "/history?days=7")[1]["entries"]
        self.assertEqual(len(entries), 3)
        self.assertTrue(all(set(e) == {"at", "bot", "site", "outcome", "approver", "computer"} for e in entries))
        self.assertEqual(self.request(PATH + "/history?days=0")[0], 422)


if __name__ == "__main__":
    unittest.main()
