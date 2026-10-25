import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("nollie_mac_server", ROOT / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

STAMP = {"session_id": "20261019_200000_abc123", "chat": "agent:career:chat-7", "profile": "career", "platform": "api_server"}


class FakeNollie:
    """Nollie's control socket: records each request and answers from a script."""

    def __init__(self, answers):
        self.answers = list(answers)
        self.requests = []
        self.folder = tempfile.mkdtemp(prefix="nm-", dir="/tmp")
        self.path = os.path.join(self.folder, "c.sock")
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.path)
        self.listener.listen(4)
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while self.answers:
            try:
                client, _ = self.listener.accept()
            except OSError:
                return
            with client:
                data = b""
                while not data.endswith(b"\n"):
                    chunk = client.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                self.requests.append(json.loads(data))
                client.sendall(json.dumps(self.answers.pop(0)).encode() + b"\n")

    def close(self):
        self.listener.close()
        os.unlink(self.path)
        os.rmdir(self.folder)


def approved(apps=(("Notes", False),)):
    return {"ok": True, "task": "t" * 64, "expires_at": 1, "apps": [{"name": n, "bundle_id": "x", "view_only": v} for n, v in apps]}


class ServerTests(unittest.TestCase):
    def mac(self, answers):
        fake = FakeNollie(answers)
        self.addCleanup(fake.close)
        return server.Mac(fake.path), fake

    def test_refuses_everything_without_the_plugin_stamp(self):
        mac, fake = self.mac([])
        for name in ("mac_start", "mac_look", "mac_click", "mac_done"):
            with self.assertRaises(server.Refused) as caught:
                mac.call(name, {"apps": ["Notes"], "task": "notes", "app": "Notes"})
            self.assertEqual(str(caught.exception), server.NO_STAMP)
        # A stamp the model wrote itself is replaced by the plugin; one without a chat is refused here.
        with self.assertRaises(server.Refused):
            mac.call("mac_start", {"apps": ["Notes"], "task": "x", "_nollie": {"profile": "career"}})
        self.assertEqual(fake.requests, [])

    def test_actions_need_an_approved_task_for_this_chat(self):
        mac, fake = self.mac([approved()])
        with self.assertRaises(server.Refused) as caught:
            mac.call("mac_click", {"app": "Notes", "element": "s0000002a:1", "_nollie": dict(STAMP)})
        self.assertEqual(str(caught.exception), server.NOT_STARTED)
        mac.call("mac_start", {"apps": ["Notes"], "task": "tidy notes", "_nollie": dict(STAMP)})
        other = dict(STAMP, session_id="20261019_200000_other", chat="agent:career:chat-8")
        with self.assertRaises(server.Refused):
            mac.call("mac_look", {"app": "Notes", "_nollie": other})
        self.assertEqual([r["op"] for r in fake.requests], ["start"])

    def test_start_sends_the_chat_and_reports_view_only_apps(self):
        mac, fake = self.mac([approved((("Notes", False), ("Safari", True)))])
        content = mac.call("mac_start", {"apps": ["Notes", "Safari"] * 6, "task": "compare" * 100, "_nollie": dict(STAMP)})
        request = fake.requests[0]
        self.assertEqual(request["op"], "start")
        self.assertEqual(request["session_id"], STAMP["session_id"])
        self.assertEqual(request["chat"], STAMP["chat"])
        self.assertEqual(request["profile"], "career")
        self.assertEqual(len(request["apps"]), 8)
        self.assertEqual(len(request["purpose"]), 300)
        self.assertIn("Notes, Safari (view only)", content[0]["text"])

    def test_refusal_from_nollie_reaches_the_bot_and_starts_nothing(self):
        mac, fake = self.mac([{"ok": False, "error": "The person said no. Don't try again unless they ask."}])
        with self.assertRaises(server.Refused) as caught:
            mac.call("mac_start", {"apps": ["Notes"], "task": "x", "_nollie": dict(STAMP)})
        self.assertIn("said no", str(caught.exception))
        self.assertEqual(mac.tasks, {})

    def test_actions_carry_the_task_and_only_known_fields(self):
        look = {"ok": True, "content": [{"type": "text", "text": "[1] AXButton \"New\""},
                                         {"type": "image", "data": "iVBOR", "mimeType": "image/png"},
                                         {"type": "resource", "uri": "file:///etc/passwd"}]}
        mac, fake = self.mac([approved(), look, {"ok": True, "content": [{"type": "text", "text": "Done."}]}, {"ok": True}])
        mac.call("mac_start", {"apps": ["Notes"], "task": "x", "_nollie": dict(STAMP)})
        content = mac.call("mac_look", {"app": "Notes", "query": "New", "_nollie": dict(STAMP)})
        self.assertEqual([c["type"] for c in content], ["text", "image"])
        mac.call("mac_key", {"app": "Notes", "keys": ["cmd", "n"], "scope": "desktop", "pid": 1, "_nollie": dict(STAMP)})
        act = fake.requests[2]
        self.assertEqual(act, {"op": "act", "task": "t" * 64, "action": "key", "app": "Notes", "keys": ["cmd", "n"]})
        mac.call("mac_done", {"_nollie": dict(STAMP)})
        self.assertEqual(fake.requests[3], {"op": "end", "task": "t" * 64})
        self.assertEqual(mac.tasks, {})

    def test_a_new_session_id_in_the_same_chat_keeps_its_task(self):
        # Hermes gives a compressed conversation a new session id; the chat key stays.
        mac, fake = self.mac([approved(), {"ok": True, "content": [{"type": "text", "text": "tree"}]}])
        mac.call("mac_start", {"apps": ["Notes"], "task": "x", "_nollie": dict(STAMP)})
        mac.call("mac_look", {"app": "Notes", "_nollie": dict(STAMP, session_id="20261019_210000_def456")})
        self.assertEqual(fake.requests[1]["task"], "t" * 64)

    def test_an_ended_task_is_forgotten(self):
        ended = {"ok": False, "error": "Access to the Mac has ended. Ask again with mac_start if the person wants."}
        mac, _ = self.mac([approved(), ended])
        mac.call("mac_start", {"apps": ["Notes"], "task": "x", "_nollie": dict(STAMP)})
        with self.assertRaises(server.Refused):
            mac.call("mac_scroll", {"app": "Notes", "direction": "down", "_nollie": dict(STAMP)})
        self.assertEqual(mac.tasks, {})

    def test_nollie_not_running_is_a_plain_refusal(self):
        mac = server.Mac("/tmp/nollie-mac-test-missing.sock")
        with self.assertRaises(server.Refused) as caught:
            mac.call("mac_start", {"apps": ["Notes"], "task": "x", "_nollie": dict(STAMP)})
        self.assertIn("Open Nollie", str(caught.exception))

    def test_mcp_session(self):
        mac, _ = self.mac([])
        lines = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "mac_look", "arguments": {"app": "Notes"}}},
            {"jsonrpc": "2.0", "id": 4, "method": "nope"},
        ]
        out = io.StringIO()
        server.serve(mac, io.StringIO("\n".join(json.dumps(l) for l in lines) + "\nnot json\n"), out)
        replies = [json.loads(l) for l in out.getvalue().splitlines()]
        self.assertEqual([r["id"] for r in replies], [1, 2, 3, 4])
        self.assertEqual(replies[0]["result"]["serverInfo"]["name"], "nollie-mac")
        names = [t["name"] for t in replies[1]["result"]["tools"]]
        self.assertEqual(names, ["mac_start", "mac_look", "mac_click", "mac_type", "mac_key", "mac_scroll", "mac_done"])
        self.assertTrue(replies[2]["result"]["isError"])
        self.assertEqual(replies[3]["error"]["code"], -32601)


if __name__ == "__main__":
    unittest.main()
