import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from urllib.parse import urlencode

spec = importlib.util.spec_from_file_location("session_mutations_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)

CHAT = "20260921_093355_d4e5f6"


class SessionMutationTests(unittest.TestCase):
    def setUp(self):
        mock.PASSWORD_AUTH["enabled"] = False
        self.request("/api/_mock/session-mutations", "POST")

    def tearDown(self):
        self.request("/api/_mock/session-mutations", "POST")

    def request(self, path, method="GET", body=None, query=None):
        target = path + ("?" + urlencode(query) if query else "")
        request = SimpleNamespace(path=target, method=method, body=json.dumps(body or {}).encode(), headers={})
        response = mock.process_request(None, request)
        return response.status_code, json.loads(response.body)

    def snapshot(self, chat=CHAT):
        return self.request(f"/api/sessions/{chat}/mutation-snapshot", query={"profile": "default"})

    def test_snapshot_names_the_revision_and_an_unknown_chat(self):
        self.assertEqual(self.snapshot(), (200, dict(session_id=CHAT, exists=True, runtime_revision=0, runtime_generation=0)))
        self.assertEqual(self.snapshot("nope")[1]["exists"], False)

    def test_a_change_without_identity_is_refused_as_0_23_does(self):
        status, body = self.request(f"/api/sessions/{CHAT}", "PATCH", {"title": "x"})
        self.assertEqual(status, 409)
        self.assertTrue(body["detail"].startswith("client_upgrade_required"))
        status, body = self.request(f"/api/sessions/{CHAT}", "PATCH", {"title": "x", "request_id": "r1"})
        self.assertEqual((status, body["detail"]), (409, "mutation_identity_required"))
        status, body = self.request(f"/api/sessions/{CHAT}", "DELETE", query={"request_id": "r1", "expected_revision": 0})
        self.assertEqual((status, body["detail"]), (409, "mutation_identity_required"))

    def test_rename_with_identity_moves_the_revision_and_replays_its_receipt(self):
        change = {"title": "Faster export", "request_id": "r1", "expected_revision": 0, "expected_generation": 0}
        status, body = self.request(f"/api/sessions/{CHAT}", "PATCH", change)
        self.assertEqual((status, body["title"], body["revision"]), (200, "Faster export", 1))
        self.assertEqual(self.snapshot()[1]["runtime_revision"], 1)
        self.assertEqual(self.request(f"/api/sessions/{CHAT}", "PATCH", change), (200, body))
        self.assertEqual(self.request(f"/api/sessions/{CHAT}", "PATCH", dict(change, title="Other"))[1]["detail"], "admission_conflict")
        stale = {"title": "Late", "request_id": "r2", "expected_revision": 0, "expected_generation": 0}
        self.assertEqual(self.request(f"/api/sessions/{CHAT}", "PATCH", stale)[1]["detail"], "revision_conflict")

    def test_switches_make_conflicts_and_busy_chats(self):
        self.request("/api/_mock/session-mutations", "POST", {"conflicts": 1, "busy": 1})
        change = {"archived": True, "request_id": "r1", "expected_revision": 0, "expected_generation": 0}
        self.assertEqual(self.request(f"/api/sessions/{CHAT}", "PATCH", change)[1]["detail"], "revision_conflict")
        self.assertEqual(self.snapshot()[1]["runtime_revision"], 1)
        change["expected_revision"] = 1
        self.assertEqual(self.request(f"/api/sessions/{CHAT}", "PATCH", change)[1]["detail"], "session_busy")
        self.assertEqual(self.request(f"/api/sessions/{CHAT}", "PATCH", change)[0], 200)
        self.assertTrue(mock.stored_row(CHAT)["archived"])
        log = self.request("/api/_mock/session-mutations")[1]["log"]
        self.assertEqual([entry["request_id"] for entry in log], ["r1", "r1", "r1"])

    def test_delete_takes_its_identity_in_the_query_and_an_absent_chat_is_fine(self):
        identity = {"profile": "default", "request_id": "d1", "expected_revision": 0, "expected_generation": 0}
        self.assertEqual(self.request(f"/api/sessions/{CHAT}", "DELETE", query=identity)[0], 200)
        self.assertIsNone(mock.stored_row(CHAT))
        self.assertFalse(self.snapshot()[1]["exists"])
        again = dict(identity, request_id="d2")
        self.assertEqual(self.request(f"/api/sessions/{CHAT}", "DELETE", query=again), (200, dict(ok=True, already_absent=True)))
        self.request("/api/_mock/session-mutations", "POST")
        self.assertIsNotNone(mock.stored_row(CHAT))

    def test_older_hermes_has_no_snapshot_and_takes_plain_changes(self):
        self.request("/api/_mock/session-mutations", "POST", {"mode": "0.22"})
        self.assertEqual(self.snapshot()[0], 404)
        status, body = self.request(f"/api/sessions/{CHAT}", "PATCH", {"title": "Plain", "profile": "default"})
        self.assertEqual((status, body["title"]), (200, "Plain"))


if __name__ == "__main__":
    unittest.main()
