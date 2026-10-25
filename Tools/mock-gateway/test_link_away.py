"""Away from home in the mock: the door's own routes for a linked phone, and a Mac whose exit node
cuts its helpers' computers off the internet."""
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("link_away_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)


class LinkAwayFixtureTests(unittest.TestCase):
    def setUp(self):
        mock.PASSWORD_AUTH["enabled"] = False
        mock.PRIVATE_BOTS["profiles"] = None
        self.request("/api/_mock/link", "POST", {"reset": True})
        self.request("/api/_mock/own-computer", "POST", {"reset": True})

    tearDown = setUp

    def request(self, path, method="GET", body=None):
        request = SimpleNamespace(path=path, method=method, body=json.dumps(body or {}).encode(), headers={})
        response = mock.process_request(None, request)
        return response.status_code, json.loads(response.body)

    def test_starts_off_and_at_home_only(self):
        status, body = self.request("/nollie/link/hosts")
        self.assertEqual(status, 200)
        self.assertEqual(body, {"hosts": ["192.168.1.20", "studio.local"], "away": False, "tailscale": "missing"})

    def test_the_phone_turns_it_on_and_off(self):
        self.request("/api/_mock/link", "POST", {"tailscale": "ready"})
        status, body = self.request("/nollie/link/away/on", "POST")
        self.assertEqual((status, body["away"]), (200, True))
        self.assertIn("studio.tail1234.ts.net", body["hosts"])
        self.assertIn("100.101.102.103", body["hosts"])
        status, body = self.request("/nollie/link/away/off", "POST")
        self.assertEqual((status, body["away"]), (200, False))
        self.assertFalse(any(h.endswith(".ts.net") or h.startswith("100.") for h in body["hosts"]))
        self.assertEqual(self.request("/api/_mock/link")[1]["log"], ["on", "off"])

    def test_without_tailscale_no_tailnet_hosts_even_when_on(self):
        self.request("/api/_mock/link", "POST", {"away": True, "tailscale": "missing"})
        body = self.request("/nollie/link/hosts")[1]
        self.assertEqual((body["away"], body["tailscale"], body["hosts"]), (True, "missing", ["192.168.1.20", "studio.local"]))

    def test_wrong_methods_are_refused(self):
        self.assertEqual(self.request("/nollie/link/hosts", "POST")[0], 405)
        self.assertEqual(self.request("/nollie/link/away/on")[0], 405)

    def test_exit_node_shows_in_the_computer_status(self):
        route = "/api/plugins/nollie-computer/own-computer?profile=work"
        self.assertIsNone(self.request(route)[1]["internet"])
        self.request("/api/_mock/own-computer", "POST", {"exit_node": True})
        self.assertEqual(self.request(route)[1]["internet"], "exit_node")
        # Nollie Runtime's relay carries the traffic: nothing to show.
        self.request("/api/_mock/own-computer", "POST", {"relay": True})
        self.assertEqual(self.request(route)[1]["internet"], "relay")
        self.request("/api/_mock/own-computer", "POST", {"reset": True})
        self.assertIsNone(self.request(route)[1]["internet"])


if __name__ == "__main__":
    unittest.main()
