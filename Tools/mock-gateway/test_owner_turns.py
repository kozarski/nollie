import asyncio
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("owner_turns_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)


def rest(path, method="GET", body=None):
    request = SimpleNamespace(path=path, method=method, body=json.dumps(body or {}).encode(), headers={})
    response = mock.process_request(None, request)
    return response.status_code, json.loads(response.body)


class Socket:
    """Stands in for the WebSocket: keeps every frame sent."""

    def __init__(self):
        self.frames = []

    async def send(self, text):
        self.frames.append(json.loads(text))


class Played(mock.Gateway):
    def __init__(self):
        super().__init__(Socket())

    def events(self):
        return [(f["params"]["type"], f["params"].get("payload") or {}) for f in self.ws.frames if f.get("method") == "event"]


class OwnerTurnTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        mock.PASSWORD_AUTH["enabled"] = False
        self.addCleanup(lambda: rest("/api/_mock/owner", "POST", {"mode": "off"}))
        self.addCleanup(lambda: rest("/api/_mock/reply-frames", "POST", {}))
        self.gateway = Played()
        self.session = mock.Session("sid-owner", "stored-owner", "Chat", "default")
        self.gateway.sessions[self.session.sid] = self.session
        mock.LIVE[self.session.sid] = self.session
        self.session.members.add(self.gateway)
        self.addCleanup(lambda: mock.LIVE.pop(self.session.sid, None))

    async def submit(self, text="Move the export"):
        return await self.gateway.handle(dict(jsonrpc="2.0", id=7, method="prompt.submit",
                                              params=dict(session_id=self.session.sid, text=text)))

    async def test_each_refusal_carries_its_reason(self):
        for mode, reason in (("busy", "SESSION_OWNER_BUSY"), ("unconfirmed", "SESSION_OWNER_UNCONFIRMED"),
                             ("not_owned", "SESSION_NOT_OWNED")):
            self.assertEqual(rest("/api/_mock/owner", "POST", {"mode": mode})[1]["mode"], mode)
            answer = await self.submit()
            self.assertEqual(answer["error"]["code"], 4090)
            self.assertEqual(answer["error"]["data"], {"reason": reason})
        self.assertEqual(rest("/api/_mock/owner", "POST", {"mode": "nope"})[0], 400)

    async def test_a_forwarded_turn_sends_only_start_and_an_empty_complete_and_files_the_reply(self):
        rest("/api/_mock/owner", "POST", {"mode": "forward", "wait": 0, "run": 0})
        answer = await self.submit()
        self.assertEqual(answer["result"]["status"], "queued")
        self.assertTrue(answer["result"]["forwarded"])
        self.assertTrue(answer["result"]["admission_id"].startswith("adm-"))
        for _ in range(20):
            await asyncio.sleep(0.01)
            if any(kind == "message.complete" for kind, _ in self.gateway.events()):
                break
        kinds = [kind for kind, _ in self.gateway.events()]
        self.assertEqual(kinds, ["message.start", "message.complete"])
        self.assertEqual(self.gateway.events()[1][1]["text"], "")
        self.assertEqual([row["text"] for row in self.session.history], ["Move the export", mock.OWNER_REPLY])
        self.assertEqual(len(rest("/api/_mock/owner")[1]["forwarded"]), 1)


class ReplyFrameTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.addCleanup(lambda: rest("/api/_mock/reply-frames", "POST", {}))

    async def test_stamps_follow_hermes_and_twice_sends_each_delta_again(self):
        rest("/api/_mock/reply-frames", "POST", {"stamp": True, "twice": True})
        gateway = Played()
        session = mock.Session("sid-frames", "stored-frames", "Chat", "default")
        mock.LIVE[session.sid] = session
        session.members.add(gateway)
        self.addCleanup(lambda: mock.LIVE.pop(session.sid, None))
        await gateway.event("message.start", session.sid)
        await gateway.event("message.delta", session.sid, {"text": "Sun 🌻"})
        await gateway.event("message.delta", session.sid, {"text": " up"})
        await gateway.event("message.interim", session.sid, {"text": "Sun 🌻 up", "already_streamed": True})
        await gateway.event("message.delta", session.sid, {"text": "Next"})
        events = gateway.events()
        turn = events[0][1]["turn_id"]
        deltas = [(p["segment"], p["offset"], p["text"]) for kind, p in events if kind == "message.delta"]
        self.assertEqual(deltas, [(0, 0, "Sun 🌻"), (0, 0, "Sun 🌻"), (0, 6, " up"), (0, 6, " up"), (1, 0, "Next"), (1, 0, "Next")])
        self.assertTrue(all(p.get("turn_id") == turn for kind, p in events))
        self.assertEqual(next(p["segment"] for kind, p in events if kind == "message.interim"), 0)

    async def test_off_by_default(self):
        gateway = Played()
        session = mock.Session("sid-plain", "stored-plain", "Chat", "default")
        mock.LIVE[session.sid] = session
        session.members.add(gateway)
        self.addCleanup(lambda: mock.LIVE.pop(session.sid, None))
        await gateway.event("message.delta", session.sid, {"text": "a"})
        self.assertEqual(gateway.events(), [("message.delta", {"text": "a"})])


class ProgressTurnTests(unittest.IsolatedAsyncioTestCase):
    async def test_the_progress_turn_reports_ten_steps_on_one_tool(self):
        original = mock.PROGRESS_STEP
        mock.PROGRESS_STEP = 0
        self.addCleanup(lambda: setattr(mock, "PROGRESS_STEP", original))
        gateway = Played()
        session = mock.Session("sid-progress", "stored-progress", "Chat", "default")
        session.members.add(gateway)
        mock.LIVE[session.sid] = session
        self.addCleanup(lambda: mock.LIVE.pop(session.sid, None))
        gateway.stream_words = lambda s, text, delay=0.0, kind="message.delta": gateway.event(kind, s.sid, {"text": text})
        await gateway._progress_turn(session, "progress please")
        steps = [p for kind, p in gateway.events() if kind == "tool.progress"]
        self.assertEqual([p["progress"] for p in steps], [float(n) for n in range(1, 11)])
        self.assertEqual({p["tool_id"] for p in steps}, {next(p["tool_id"] for k, p in gateway.events() if k == "tool.start")})
        self.assertEqual(steps[-1]["percent"], 100)


if __name__ == "__main__":
    unittest.main()
