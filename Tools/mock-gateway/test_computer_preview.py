import asyncio
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("computer_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)


class PreviewFixtureTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        mock.COMPUTER_PREVIEW.update(state="live", active=False, frame=0, requests=[], writes=0, held=False, control_writes=0)
        mock.LIVE.clear()
        mock.PASSWORD_AUTH["enabled"] = False

    async def test_frame_changes_profile_is_checked_and_stale_is_old(self):
        query = {"profile": "default", "session_id": mock.COMPUTER_SESSION}
        first = mock.computer_preview_rest(query)[1]
        second = mock.computer_preview_rest(query)[1]
        self.assertEqual(first["state"], "live")
        self.assertNotEqual(first["image_data_url"], second["image_data_url"])
        self.assertEqual(mock.computer_preview_rest({**query, "profile": "work"})[1]["state"], "unavailable")
        await mock.computer_preview_control("POST", {"state": "stale"})
        stale = mock.computer_preview_rest(query)[1]
        self.assertLess(stale["captured_at"], first["captured_at"] - 20)
        self.assertEqual(mock.COMPUTER_PREVIEW["writes"], 0)

    async def test_control_emits_real_tool_and_turn_completion(self):
        events = []
        class Gateway:
            async def event(self, kind, sid, payload):
                events.append((kind, sid, payload))
        session = mock.Session("live", mock.COMPUTER_SESSION, "Desktop", "default")
        session.members.add(Gateway())
        mock.LIVE[session.sid] = session
        await mock.computer_preview_control("POST", {"active": True})
        self.assertTrue(session.running)
        self.assertEqual(events[0][0], "tool.start")
        self.assertEqual(events[0][2]["name"], "mcp__cua__computer_screenshot")
        await mock.computer_preview_control("POST", {"active": False})
        self.assertFalse(session.running)
        self.assertEqual([event[0] for event in events], ["tool.start", "tool.complete", "message.complete"])

    async def test_http_handler_logs_polling_and_permission_write_attempts(self):
        def request(path, method="GET", body=None):
            return SimpleNamespace(path=path, method=method, body=json.dumps(body or {}).encode(), headers={})
        response = mock.process_request(None, request(
            "/api/plugins/nollie-computer/preview?profile=default&session_id=" + mock.COMPUTER_SESSION))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(mock.COMPUTER_PREVIEW["requests"]), 1)
        mock.process_request(None, request("/api/config", "PUT", {"config": {}}))
        mock.process_request(None, request("/api/files/upload", "POST", {"path": "/home/hermes/bot-desktop/lease.json"}))
        self.assertEqual(mock.COMPUTER_PREVIEW["writes"], 2)
        response = await mock.process_request(None, request("/api/_mock/computer-preview", "POST", {"reset_log": True}))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(mock.COMPUTER_PREVIEW["requests"], [])

    async def test_take_over_holds_the_helper_and_hand_back_returns_it(self):
        def request(path, method="POST"):
            return SimpleNamespace(path=path, method=method, body=b"{}", headers={})
        query = {"profile": "default", "session_id": mock.COMPUTER_SESSION}
        watched = mock.computer_preview_rest(query)[1]
        self.assertEqual(watched["control"], "helper")
        self.assertEqual(set(watched["pointer"]), {"x", "y", "at"})
        self.assertEqual(mock.COMPUTER_PREVIEW["control_writes"], 0, "Watching never takes over")
        taken = mock.process_request(None, request("/api/plugins/nollie-computer/take-over?profile=default"))
        self.assertEqual((taken.status_code, json.loads(taken.body)), (200, {"control": "you"}))
        held = [mock.computer_preview_rest(query)[1] for _ in range(2)]
        self.assertEqual(held[0]["control"], "you")
        self.assertEqual(held[0]["image_data_url"], held[1]["image_data_url"], "A waiting helper's screen stays put")
        for profile in ("private", "moss", "work"):
            refused = mock.process_request(None, request(f"/api/plugins/nollie-computer/take-over?profile={profile}"))
            self.assertEqual(refused.status_code, 409)
        self.assertEqual(mock.process_request(None, request("/api/plugins/nollie-computer/take-over?profile=default", "GET")).status_code, 405)
        back = mock.process_request(None, request("/api/plugins/nollie-computer/hand-back?profile=default"))
        self.assertEqual(json.loads(back.body), {"control": "helper"})
        self.assertEqual(mock.COMPUTER_PREVIEW["control_writes"], 2)
        self.assertEqual(mock.COMPUTER_PREVIEW["writes"], 0, "Take over never changes config or Mac control")


if __name__ == "__main__":
    unittest.main()
