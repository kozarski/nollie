import asyncio
import base64
import contextlib
import threading
import importlib.util
import json
from dataclasses import asdict, dataclass, field
from pathlib import Path
from tempfile import TemporaryDirectory
import time
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


takeover = load("takeover_core", ROOT / "dashboard/takeover_core.py")
core = load("preview_core_for_takeover", ROOT / "dashboard/preview_core.py")
PNG = base64.b64encode(b"\x89PNG\r\n\x1a\n" + b"fixture").decode()


class FakeLease:
    """Hermes's lease module as tools/bot_desktop/lease.py behaves: one JSON file per home, every
    accepted transition increments the epoch, and a missing file is the agent's at epoch 0."""

    @dataclass
    class Lease:
        holder: str = "agent"
        viewer_id: object = None
        since: float = field(default_factory=time.time)
        reason: str = ""
        epoch: int = 0

    def __init__(self, home):
        self.home = Path(home)
        self.transitions = 0
        self.locked_paths = []
        self.notified = []

    def path(self, key=None):
        return Path(key or self.home) / "bot-desktop" / "lease.json"

    def get(self, profile_key=None):
        try:
            data = json.loads(self.path(profile_key).read_text())
        except FileNotFoundError:
            return self.Lease()
        return self.Lease(**data)

    def _transition(self, profile_key, mutate):
        lease = self.get(profile_key)
        if not mutate(lease):
            return lease
        lease.epoch += 1
        self.transitions += 1
        self.path(profile_key).parent.mkdir(parents=True, exist_ok=True)
        self.path(profile_key).write_text(json.dumps(asdict(lease)))
        return lease

    # The pieces of tools/bot_desktop/lease.py that Hand back uses to remove a lease.
    _lock = threading.Condition()

    def _locked(self, path):
        self.locked_paths.append(Path(path))
        return contextlib.nullcontext()

    def _read(self, path):
        return self.get(Path(path).parent.parent)

    def _notify(self, key, lease):
        self.notified.append((key, lease.holder, lease.epoch))

    def hermes_home_key(self, path):
        return str(path)

    def write(self, **values):
        self.path().parent.mkdir(parents=True, exist_ok=True)
        self.path().write_text(json.dumps(asdict(self.Lease(**values))))


class ControlTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.home = Path(self.temp.name) / "default"
        self.home.mkdir()
        self.lease = FakeLease(self.home)
        self.private = {"names": frozenset({"private", "moss"})}
        self.service = takeover.ControlService(lease_loader=lambda: self.lease, home_for=lambda _: self.home,
                                               private_reader=lambda: self.private["names"])

    def tearDown(self):
        self.temp.cleanup()

    def record(self):
        path = self.home / "bot-desktop" / takeover.RECORD
        return json.loads(path.read_text()) if path.exists() else None

    def test_take_over_pauses_the_helper_and_hand_back_returns_it(self):
        self.lease.write(holder="agent", epoch=4)
        self.assertEqual(self.service.control("default"), "helper")
        self.assertEqual(self.service.take_over("default"), {"control": "you"})
        held = self.lease.get()
        self.assertEqual((held.holder, held.viewer_id, held.epoch), ("human", "nollie-watch", 5))
        self.assertEqual(self.record()["epoch"], 5)
        self.assertEqual(self.record()["prior"], {"holder": "agent", "absent": False})
        self.assertEqual(self.service.control("default"), "you")
        self.assertEqual(self.service.hand_back("default"), {"control": "helper"})
        back = self.lease.get()
        self.assertEqual((back.holder, back.viewer_id, back.reason, back.epoch), ("agent", None, "", 6))
        self.assertIsNone(self.record())

    def test_repeats_change_nothing(self):
        self.lease.write(holder="agent", epoch=0)
        self.service.take_over("default")
        self.service.take_over("default")
        self.assertEqual(self.lease.transitions, 1)
        self.service.hand_back("default")
        self.service.hand_back("default")
        self.assertEqual(self.lease.transitions, 2)
        self.assertEqual(self.lease.get().epoch, 2, "The epoch only ever grows")

    def test_no_lease_file_before_means_none_after(self):
        self.assertFalse(self.lease.path().exists())
        self.assertEqual(self.service.take_over("default"), {"control": "you"})
        self.assertEqual(self.record()["prior"], {"holder": "agent", "absent": True})
        self.assertEqual(self.lease.get().holder, "human")
        self.assertEqual(self.service.hand_back("default"), {"control": "helper"})
        self.assertFalse(self.lease.path().exists(), "Hand back must not leave a lease naming the helper")
        self.assertIsNone(self.record())
        self.assertIn(self.lease.path(), self.lease.locked_paths, "Removed under the lease's own lock")
        self.assertEqual(self.lease.notified, [(str(self.home), "agent", 0)])
        self.assertEqual(self.lease.transitions, 1, "Only Take over wrote a lease")

    def test_a_missing_file_is_only_removed_while_the_lease_is_still_ours(self):
        self.service.take_over("default")
        # Mac control switched off elsewhere meanwhile: that lease stays, whatever the record says.
        self.lease.write(holder="human", viewer_id="nollie-app", reason="off", epoch=1)
        self.service.hand_back("default")
        self.assertEqual((self.lease.get().viewer_id, self.lease.get().epoch), ("nollie-app", 1))
        # Taken over again, then the lease moved on under the same holder: the epoch must match.
        self.lease.path().unlink()
        self.service.take_over("default")
        self.lease.write(holder="human", viewer_id="nollie-watch", reason="", epoch=5)
        self.service.hand_back("default")
        self.assertTrue(self.lease.path().exists())
        self.assertEqual((self.lease.get().holder, self.lease.get().viewer_id), ("human", "nollie-app"),
                         "A mismatched record never removes a lease or grants more")

    def test_an_older_record_never_removes_a_lease(self):
        self.lease.write(holder="agent", epoch=2)
        self.service.take_over("default")
        path = self.home / "bot-desktop" / takeover.RECORD
        for prior in ({"holder": "agent"}, {"holder": "agent", "absent": "yes"}, {"holder": "agent", "absent": 1}):
            document = json.loads(path.read_text()) if path.exists() else {"version": 1, "epoch": 3}
            document["prior"] = prior
            path.write_text(json.dumps(document))
            self.assertFalse(takeover.read_record(self.home)["absent"], prior)
        self.service.hand_back("default")
        self.assertTrue(self.lease.path().exists())
        self.assertEqual(self.lease.get().holder, "agent")

    def test_mac_control_off_is_restored_exactly(self):
        reason = "System control is off in the Nollie app"
        self.lease.write(holder="human", viewer_id="nollie-app", reason=reason, epoch=9)
        self.assertEqual(self.service.control("default"), "helper")
        self.assertEqual(self.service.take_over("default"), {"control": "you"})
        self.assertEqual(self.service.hand_back("default"), {"control": "helper"})
        back = self.lease.get()
        self.assertEqual((back.holder, back.viewer_id, back.reason, back.epoch), ("human", "nollie-app", reason, 11),
                         "Hand back must never switch Mac control on")

    def test_another_person_is_never_evicted(self):
        for viewer in ("desktop-viewer-1", "unreadable-lease"):
            self.lease.write(holder="human", viewer_id=viewer, epoch=3)
            self.assertEqual(self.service.control("default"), "someone")
            self.assertEqual(self.service.take_over("default"), {"control": "someone"})
            self.assertEqual(self.service.hand_back("default"), {"control": "someone"})
            self.assertEqual(self.lease.get().viewer_id, viewer)
            self.assertEqual(self.lease.get().epoch, 3)
            self.assertIsNone(self.record())

    def test_hand_back_leaves_a_lease_changed_by_someone_else(self):
        self.service.take_over("default")
        # Mac control turned off in another copy of Nollie meanwhile.
        self.lease.write(holder="human", viewer_id="nollie-app", reason="off", epoch=7)
        self.assertEqual(self.service.hand_back("default"), {"control": "helper"})
        self.assertEqual((self.lease.get().viewer_id, self.lease.get().epoch), ("nollie-app", 7))
        self.assertIsNone(self.record())

    def test_without_a_trusted_record_hand_back_never_grants_more(self):
        for damage in ("missing", "stale", "garbled"):
            self.lease.write(holder="agent", epoch=1)
            self.service.take_over("default")
            path = self.home / "bot-desktop" / takeover.RECORD
            if damage == "missing":
                path.unlink()
            elif damage == "stale":
                path.write_text(json.dumps({"version": 1, "epoch": 1, "prior": {"holder": "agent"}}))
            else:
                path.write_text("{")
            self.service.hand_back("default")
            back = self.lease.get()
            self.assertEqual((back.holder, back.viewer_id), ("human", "nollie-app"), damage)

    def test_private_unknown_and_unreadable_bots_are_refused(self):
        for profile in ("private", "moss", "../default", "Default", "", None):
            with self.assertRaises(takeover.ControlUnavailable):
                self.service.take_over(profile)
            with self.assertRaises(takeover.ControlUnavailable):
                self.service.hand_back(profile)
            self.assertIsNone(self.service.control(profile))
        self.private["names"] = None  # an unreadable Private list refuses everything
        with self.assertRaises(takeover.ControlUnavailable):
            self.service.take_over("default")
        self.assertEqual(self.lease.transitions, 0)
        self.assertFalse(self.lease.path().exists())


class HookTests(unittest.TestCase):
    def test_only_cua_tools_pause_and_only_while_nollie_holds(self):
        held = {"value": True}
        holds = lambda: held["value"]
        for name, args in (("mcp__cua__computer_click", {"x": 1, "y": 2}), ("mcp__cua__space_bash", {}),
                           ("tool_call", {"calls": [{"name": "mcp__cua__computer_type"}]}),
                           ("tool_call", {"name": "mcp__cua__computer_screenshot"}),
                           ("tool_call", {"calls": "not json"})):
            self.assertEqual(takeover.blocked_message(name, args, holds), takeover.BLOCKED, name)
        for name, args in (("terminal", {}), ("computer_use", {"action": "click"}),
                           ("tool_call", {"calls": [{"name": "read_file"}]})):
            self.assertIsNone(takeover.blocked_message(name, args, holds), name)
        held["value"] = False
        self.assertIsNone(takeover.blocked_message("mcp__cua__computer_click", {}, holds))

        def broken():
            raise ImportError()
        self.assertIsNone(takeover.blocked_message("mcp__cua__computer_click", {}, broken))

    def test_held_by_nollie_reads_the_current_lease(self):
        with TemporaryDirectory() as temp:
            lease = FakeLease(temp)
            lease.get = (lambda original: lambda profile_key=None: original(profile_key or temp))(lease.get)
            self.assertFalse(takeover.held_by_nollie(lease))
            lease.write(holder="human", viewer_id="nollie-app")
            self.assertFalse(takeover.held_by_nollie(lease))
            lease.write(holder="human", viewer_id="nollie-watch")
            self.assertTrue(takeover.held_by_nollie(lease))

    def test_plugin_registers_the_hook(self):
        plugin = load("nollie_computer_plugin", ROOT / "__init__.py")
        hooks = {}
        plugin.register(SimpleNamespace(register_hook=lambda name, fn: hooks.setdefault(name, fn)))
        self.assertIn("pre_tool_call", hooks)
        # Outside Hermes there is no lease module, so nothing can have been taken over.
        self.assertIsNone(hooks["pre_tool_call"](tool_name="mcp__cua__computer_click", args={}))
        self.assertIn("provides_hooks", (ROOT / "plugin.yaml").read_text())


def click(target, name, args, call_id, result='{"success":true}', at=None):
    rows = [{"role": "assistant", "tool_calls": [{"id": call_id, "function": {
        "name": name, "arguments": json.dumps({"sandbox": target, **args})}}]},
        {"role": "tool", "tool_call_id": call_id, "content": result}]
    if at is not None:
        rows[1]["timestamp"] = at
    return rows


class PointerTests(unittest.TestCase):
    def test_pointer_comes_only_from_successful_actions_on_this_computer(self):
        clicked = click("local:desk", "mcp__cua__computer_click", {"x": 120, "y": 80}, "a", at=1700.5)
        self.assertEqual(core.resolve_target(clicked)["pointer"], {"x": 120, "y": 80, "at": 1700.5})
        shot = click("local:desk", "mcp__cua__computer_screenshot", {}, "b",
                     result='{"result":"MEDIA:/cache/screen.png"}')
        self.assertEqual(core.resolve_target(clicked + shot)["pointer"]["x"], 120, "A look keeps the last spot")
        dragged = click("local:desk", "mcp__cua__computer_drag",
                        {"start_x": 1, "start_y": 2, "end_x": 300, "end_y": 200}, "c")
        self.assertEqual(core.resolve_target(clicked + dragged)["pointer"], {"x": 300, "y": 200})
        other = click("local:other", "mcp__cua__computer_screenshot", {}, "d",
                      result='{"result":"MEDIA:/cache/screen.png"}')
        self.assertIsNone(core.resolve_target(clicked + other)["pointer"], "Another computer forgets the spot")
        failed = click("local:desk", "mcp__cua__computer_click", {"x": 5, "y": 5}, "e", result='{"error":"no"}')
        self.assertEqual(core.resolve_target(clicked + failed)["pointer"]["x"], 120)
        for bad in ({"x": "1", "y": 2}, {"x": True, "y": 2}, {"x": -1, "y": 2}, {"x": 1.5, "y": 2},
                    {"x": 99999, "y": 2}, {"y": 2}):
            target = core.resolve_target(click("local:desk", "mcp__cua__computer_click", bad, "f"))
            self.assertIsNone(target["pointer"], bad)
        typed = click("local:desk", "mcp__cua__computer_type", {"text": "hi", "x": 3, "y": 4}, "g")
        self.assertIsNone(core.resolve_target(typed)["pointer"], "Only position tools report a spot")
        mac = click("local:desk", "computer_use", {"action": "click", "x": 3, "y": 4}, "h")
        self.assertIsNone(core.resolve_target(clicked + mac)["pointer"])


class PreviewControlTests(unittest.IsolatedAsyncioTestCase):
    async def test_preview_reports_control_and_pointer_outside_the_cache(self):
        messages = click("local:desk", "mcp__cua__computer_click", {"x": 10, "y": 20}, "a")
        control = {"value": "helper"}
        service = core.PreviewService(AsyncMock(return_value=messages), AsyncMock(return_value="data:image/png;base64," + PNG),
                                      lambda: 100.0, private_reader=lambda: frozenset(),
                                      control_reader=lambda profile: control["value"], typing_reader=lambda: False)
        first = await service.preview("default", "chat")
        self.assertEqual((first["state"], first["control"], first["pointer"]), ("live", "helper", {"x": 10, "y": 20}))
        control["value"] = "you"
        self.assertEqual((await service.preview("default", "chat"))["control"], "you")
        control["value"] = "elsewhere"
        self.assertNotIn("control", await service.preview("default", "chat"))

    async def test_private_bots_never_read_control(self):
        read = []
        service = core.PreviewService(AsyncMock(return_value=[]), AsyncMock(), private_reader=lambda: frozenset({"moss"}),
                                      control_reader=lambda profile: read.append(profile) or "helper",
                                      typing_reader=lambda: False)
        self.assertEqual((await service.preview("moss", "chat"))["state"], "unavailable")
        self.assertEqual(read, [])


class RouteTests(unittest.TestCase):
    def test_routes_answer_alike_for_refusals(self):
        try:
            from fastapi import FastAPI
            from fastapi.testclient import TestClient
        except ImportError:
            self.skipTest("fastapi is not installed")
        api = load("nollie_computer_api_for_test", ROOT / "dashboard/plugin_api.py")

        def refuse(_profile):
            raise takeover.ControlUnavailable()
        api._control = SimpleNamespace(take_over=refuse, hand_back=refuse)
        app = FastAPI()
        app.include_router(api.router)
        client = TestClient(app)
        for path in ("/take-over", "/hand-back"):
            reply = client.post(path, params={"profile": "moss"})
            self.assertEqual(reply.status_code, 409)
            self.assertEqual(reply.headers["cache-control"], "no-store")
            self.assertNotIn("moss", reply.text)
        api._control = SimpleNamespace(take_over=lambda p: {"control": "you"}, hand_back=lambda p: {"control": "helper"})
        self.assertEqual(client.post("/take-over", params={"profile": "default"}).json(), {"control": "you"})
        self.assertEqual(client.post("/hand-back", params={"profile": "default"}).json(), {"control": "helper"})
        self.assertEqual(client.get("/take-over", params={"profile": "default"}).status_code, 405)


if __name__ == "__main__":
    unittest.main()
