import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("own_computer_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)

ROUTE = "/api/plugins/nollie-computer/own-computer"


class OwnComputerFixtureTests(unittest.TestCase):
    def setUp(self):
        mock.PASSWORD_AUTH["enabled"] = False
        mock.PRIVATE_BOTS["profiles"] = None
        self.request("/api/_mock/own-computer", "POST", {"reset": True, "ready_after": 0})

    def tearDown(self):
        self.request("/api/_mock/own-computer", "POST", {"reset": True})

    def request(self, path, method="GET", body=None):
        request = SimpleNamespace(path=path, method=method, body=json.dumps(body or {}).encode(), headers={})
        response = mock.process_request(None, request)
        return response.status_code, json.loads(response.body)

    def change(self, action, request_id, profile="work"):
        return self.request(ROUTE, "POST", {"profile": profile, "action": action, "request_id": request_id})

    def test_switch_on_off_and_remove_like_the_add_on(self):
        status, body = self.request(ROUTE + "?profile=work")
        self.assertEqual((status, body["on"], body["state"], body["setup"]), (200, False, "off", "ready"))
        status, body = self.change("on", "request-0001")
        self.assertEqual((status, body["on"], body["state"], body["computer_name"]), (200, True, "ready", "nollie-work"))
        self.assertEqual(self.change("remove", "request-0002")[0], 409)
        self.assertEqual(self.change("off", "request-0003")[1]["has_computer"], True)
        status, body = self.change("remove", "request-0004")
        self.assertEqual((status, body["has_computer"], body["computer_name"]), (200, False, None))

    def test_a_repeated_request_changes_nothing(self):
        self.change("on", "request-0001")
        self.change("on", "request-0001")
        log = self.request("/api/_mock/own-computer")[1]["log"]
        self.assertEqual(len(log), 1)

    def test_getting_ready_then_ready(self):
        self.request("/api/_mock/own-computer", "POST", {"ready_after": 60})
        body = self.change("on", "request-0001")[1]
        self.assertEqual((body["state"], body["busy"]), ("getting_ready", True))
        self.assertEqual(self.change("off", "request-0002")[0], 409)
        mock.OWN_COMPUTERS["profiles"]["work"]["ready_at"] = 0
        self.assertEqual(self.request(ROUTE + "?profile=work")[1]["state"], "ready")

    def test_setup_gates_turning_on_and_private_bots_are_refused(self):
        self.request("/api/_mock/own-computer", "POST", {"setup": "no_cua"})
        self.assertEqual(self.request(ROUTE + "?profile=work")[1]["setup"], "no_cua")
        self.assertEqual(self.change("on", "request-0001")[0], 409)
        self.assertEqual(self.request(ROUTE + "?profile=private")[0], 404)
        self.assertEqual(self.request(ROUTE + "?profile=nobody")[0], 404)

    def test_fixture_states(self):
        self.request("/api/_mock/own-computer", "POST", {"profile": "work", "on": True, "state": "asleep"})
        self.assertEqual(self.request(ROUTE + "?profile=work")[1]["state"], "asleep")
        self.request("/api/_mock/own-computer", "POST", {"profile": "work", "state": "getting_ready"})
        self.assertEqual(self.request(ROUTE + "?profile=work")[1]["state"], "getting_ready")


if __name__ == "__main__":
    unittest.main()
