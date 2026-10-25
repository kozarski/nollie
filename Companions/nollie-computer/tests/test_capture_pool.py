import asyncio
import base64
import importlib.util
import json
import time
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


core = load("preview_core_for_pool", ROOT / "dashboard/preview_core.py")
PNG = base64.b64encode(b"\x89PNG\r\n\x1a\n" + b"fixture").decode()
MAIN_HOME = TemporaryDirectory()


def setUpModule():
    core.main_home = lambda: Path(MAIN_HOME.name)


def tearDownModule():
    MAIN_HOME.cleanup()


def rows(target="local:desk", call_id="capture-1"):
    return [{"role": "assistant", "tool_calls": [{"id": call_id, "function": {
        "name": "mcp__cua__computer_screenshot", "arguments": json.dumps({"sandbox": target})}}]},
        {"role": "tool", "tool_call_id": call_id, "content": json.dumps({"result": "MEDIA:/cache/screen.png"})}]


class FakeCua:
    """A Cua MCP child answering from a script. With a gate, screenshots wait for it; an unset gate never answers."""

    def __init__(self, space="local:desk", shot=None, gate=None, gone=(), echo=False):
        self.gone, self.echo = gone, echo  # echo: any Space asked for exists
        self.stdout = asyncio.StreamReader()
        self.stdin = SimpleNamespace(write=self.write, drain=AsyncMock())
        self.info = {"id": space, "location": space.split(":")[0], "status": "ready"}
        self.shot = shot or {"content": [{"type": "image", "mimeType": "image/png", "data": PNG}]}
        self.gate, self.calls, self.returncode, self.pid = gate, [], None, 4242

    def write(self, raw):
        message = json.loads(raw)
        if "id" not in message:
            return
        name = message["params"].get("name", message["method"])
        self.calls.append(name)
        if name == "computer_screenshot" and self.gate is not None:
            asyncio.get_running_loop().create_task(self.later(message["id"]))
        elif name == "computer_screenshot":
            self.answer(message["id"], self.shot)
        elif name == "sandbox_get" and message["params"]["arguments"]["name"] in self.gone:
            self.answer(message["id"], {"isError": True, "structuredContent": {"error": {"kind": "not_found"}}})
        elif name == "sandbox_get":
            info = {**self.info, "id": message["params"]["arguments"]["name"]} if self.echo else self.info
            self.answer(message["id"], {"content": [{"type": "text", "text": json.dumps(info)}]})
        else:
            self.answer(message["id"], {})

    def answer(self, request_id, result):
        self.stdout.feed_data((json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}) + "\n").encode())

    async def later(self, request_id):
        await self.gate.wait()
        self.answer(request_id, self.shot)

    def terminate(self):
        self.returncode = -15

    def kill(self):
        self.returncode = -9

    async def wait(self):
        return self.returncode


class Spawner:
    def __init__(self, pause=False, **options):
        self.options, self.children, self.pause = options, [], pause

    async def __call__(self):
        if self.pause:
            await asyncio.sleep(0)
        child = FakeCua(**self.options)
        self.children.append(child)
        return child

    def shots(self):
        return sum(child.calls.count("computer_screenshot") for child in self.children)


async def settle():
    for _ in range(5):
        await asyncio.sleep(0)


class PoolTests(unittest.IsolatedAsyncioTestCase):
    async def test_one_child_is_reused_and_looked_up_once(self):
        spawn = Spawner()
        pool = core.CapturePool(spawn)
        for _ in range(3):
            self.assertTrue((await pool.capture("desk")).startswith("data:image/png;base64,"))
        self.assertEqual(len(spawn.children), 1)
        self.assertEqual(spawn.children[0].calls, ["initialize", "sandbox_get"] + ["computer_screenshot"] * 3)
        self.assertIsNone(spawn.children[0].returncode)
        await pool.close()
        self.assertEqual(spawn.children[0].returncode, -15)

    async def test_the_lookup_runs_again_on_the_same_child_after_a_while(self):
        spawn, clock = Spawner(), [0.0]
        pool = core.CapturePool(spawn, clock=lambda: clock[0])
        await pool.capture("local:desk")
        clock[0] += core.RECHECK_SECONDS
        await pool.capture("local:desk")
        self.assertEqual(len(spawn.children), 1)
        self.assertEqual(spawn.children[0].calls.count("sandbox_get"), 2)
        spawn.children[0].info["status"] = "stopped"
        clock[0] += core.RECHECK_SECONDS
        with self.assertRaises(core.PreviewUnavailable):
            await pool.capture("local:desk")
        self.assertEqual(spawn.children[0].calls[-1], "sandbox_get")
        self.assertEqual(spawn.children[0].returncode, -15)
        await pool.close()

    async def test_closed_when_unused(self):
        spawn = Spawner()
        pool = core.CapturePool(spawn, idle=0.01)
        await pool.capture("desk")
        await asyncio.sleep(0.05)
        self.assertEqual(spawn.children[0].returncode, -15)
        self.assertEqual(pool._live, set())
        await pool.capture("desk")
        self.assertEqual(len(spawn.children), 2)
        await pool.close()

    async def test_closed_on_an_error_answer_and_reopened_next_time(self):
        spawn = Spawner(shot={"isError": True, "content": [{"type": "text", "text": "secret detail"}]})
        pool = core.CapturePool(spawn)
        with self.assertRaises(core.PreviewUnavailable):
            await pool.capture("desk")
        self.assertEqual(spawn.children[0].returncode, -15)
        spawn.options = {}
        await pool.capture("desk")
        self.assertEqual(len(spawn.children), 2)
        self.assertEqual(spawn.children[1].calls[:2], ["initialize", "sandbox_get"])
        await pool.close()

    async def test_closed_on_timeout_and_on_cancel_after_reuse(self):
        spawn = Spawner()
        pool = core.CapturePool(spawn, timeout=0.05)
        await pool.capture("desk")
        spawn.children[0].gate = asyncio.Event()
        with self.assertRaises(TimeoutError):
            await pool.capture("desk")
        self.assertEqual(spawn.children[0].returncode, -15)
        spawn.options = {"gate": asyncio.Event()}
        pool.timeout = 60
        task = asyncio.create_task(pool.capture("desk"))
        await settle()
        self.assertEqual(spawn.children[1].calls[-1], "computer_screenshot")
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertEqual(spawn.children[1].returncode, -15)
        self.assertEqual(pool._live, set())

    async def test_a_child_that_exited_while_waiting_is_replaced(self):
        spawn = Spawner()
        pool = core.CapturePool(spawn)
        await pool.capture("desk")
        spawn.children[0].returncode = 1
        await pool.capture("desk")
        self.assertEqual(len(spawn.children), 2)
        await pool.close()

    async def test_children_are_bounded(self):
        spawn = Spawner()
        pool = core.CapturePool(spawn, limit=1)
        await pool.capture("local:desk")
        spawn.options = {"space": "local:other"}
        await pool.capture("local:other")
        await settle()
        self.assertEqual(spawn.children[0].returncode, -15)
        self.assertEqual(len(pool._live), 1)
        await pool.close()

    async def test_children_are_bounded_when_started_together(self):
        spawn = Spawner(pause=True, echo=True)
        pool = core.CapturePool(spawn, limit=2)
        names = [f"local:desk{n}" for n in range(4)]
        answers = await asyncio.gather(*(pool.capture(name) for name in names), return_exceptions=True)
        self.assertEqual(len(spawn.children), 2)
        self.assertEqual(sum(isinstance(answer, core.PreviewUnavailable) for answer in answers), 2)
        self.assertEqual(len(pool._live), 2)
        await pool.close()

    async def test_bad_names_never_start_a_child(self):
        spawn = Spawner()
        pool = core.CapturePool(spawn)
        for value in ("direct:127.0.0.1:3211", "../desk", "", None):
            with self.assertRaises(core.PreviewUnavailable):
                await pool.capture(value)
        self.assertEqual(spawn.children, [])

    async def test_kill_at_exit_signals_running_children(self):
        spawn = Spawner()
        pool = core.CapturePool(spawn)
        await pool.capture("desk")
        with patch.object(core.os, "kill") as kill:
            pool.kill()
        kill.assert_called_once_with(4242, core.signal.SIGTERM)
        await pool.close()


class SharedCaptureTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        patch.object(core, "read_owned_space", return_value=None).start()
        self.addCleanup(patch.stopall)

    async def test_concurrent_captures_share_one_call_even_when_fresh(self):
        gate = asyncio.Event()
        spawn = Spawner(gate=gate)
        service = core.PreviewService(AsyncMock(return_value=rows()), pool=core.CapturePool(spawn))
        waiting = [asyncio.create_task(service.preview("default", "chat", fresh=True)) for _ in range(3)]
        waiting.append(asyncio.create_task(service.preview("default", "other-chat")))
        await settle()
        gate.set()
        answers = await asyncio.gather(*waiting)
        self.assertEqual(spawn.shots(), 1)
        self.assertEqual({answer["state"] for answer in answers}, {"live"})
        self.assertEqual(len({answer["captured_at"] for answer in answers}), 1)
        await service.close()

    async def test_fresh_skips_the_cache(self):
        capture, clock = AsyncMock(side_effect=["frame1", "frame2", "frame3"]), [100.0]
        service = core.PreviewService(AsyncMock(return_value=rows()), capture, lambda: clock[0])
        self.assertEqual((await service.preview("default", "chat"))["image_data_url"], "frame1")
        self.assertEqual((await service.preview("default", "chat"))["image_data_url"], "frame1")
        self.assertEqual(capture.await_count, 1)
        clock[0] += 0.5
        fresh = await service.preview("default", "chat", fresh=True)
        self.assertEqual((fresh["image_data_url"], fresh["captured_at"]), ("frame2", 100.5))
        self.assertEqual((await service.preview("default", "chat"))["image_data_url"], "frame2")
        self.assertEqual(capture.await_count, 2)
        self.assertEqual(set(fresh), {"state", "kind", "computer_name", "target_source", "image_data_url", "captured_at"})

    async def test_target_change_closes_the_old_child_unless_another_chat_shows_it(self):
        spawn = Spawner()
        reads = {"chat": rows(), "other-chat": rows()}
        async def read(profile, session_id):
            return reads[session_id]
        service = core.PreviewService(read, pool=core.CapturePool(spawn))
        await service.preview("default", "chat")
        await service.preview("default", "other-chat")
        self.assertEqual(len(spawn.children), 1)
        spawn.options = {"space": "local:other"}
        reads["chat"] = rows() + rows("local:other", call_id="capture-2")
        self.assertEqual((await service.preview("default", "chat", fresh=True))["computer_name"], "other")
        await settle()
        self.assertIsNone(spawn.children[0].returncode)
        reads["other-chat"] = []
        self.assertEqual((await service.preview("default", "other-chat"))["state"], "idle")
        await settle()
        self.assertEqual(spawn.children[0].returncode, -15)
        self.assertIsNone(spawn.children[1].returncode)
        await service.close()
        self.assertEqual(spawn.children[1].returncode, -15)

    async def test_a_missing_chat_computer_falls_back_to_one_kept_owned_child(self):
        core.read_owned_space.return_value = "local:mine"
        spawn = Spawner(space="local:mine", gone={"local:gone"})
        service = core.PreviewService(AsyncMock(return_value=rows("local:gone")), pool=core.CapturePool(spawn))
        for _ in range(3):
            answer = await service.preview("default", "chat", fresh=True)
            self.assertEqual((answer["state"], answer["target_source"]), ("live", "owned"))
            await settle()
        owned = [child for child in spawn.children if "computer_screenshot" in child.calls]
        self.assertEqual(len(owned), 1)
        self.assertEqual(owned[0].calls.count("computer_screenshot"), 3)
        self.assertIsNone(owned[0].returncode)
        await service.close()

    async def test_private_bots_and_wrong_sessions_never_capture_or_get_a_shared_picture(self):
        gate, private = asyncio.Event(), {"names": frozenset()}
        spawn = Spawner(gate=gate)
        async def read(profile, session_id):
            if session_id != "chat":
                raise core.PreviewUnavailable()
            return rows()
        service = core.PreviewService(read, pool=core.CapturePool(spawn), private_reader=lambda: private["names"])
        owner = asyncio.create_task(service.preview("default", "chat", fresh=True))
        await settle()
        self.assertEqual(spawn.shots(), 1)
        private["names"] = frozenset({"scout"})
        for profile, session_id in (("scout", "chat"), ("default", "wrong-chat")):
            answer = await service.preview(profile, session_id, fresh=True)
            self.assertEqual(answer["state"], "unavailable")
            self.assertNotIn("image_data_url", answer)
        # The owner turns private while its picture is on the way: the picture is not handed out.
        private["names"] = frozenset({"default"})
        gate.set()
        self.assertEqual(await owner, {"state": "unavailable", "message": "This chat has no available computer preview."})
        self.assertEqual(spawn.shots(), 1)
        # Nor is it reused from the cache.
        private["names"] = frozenset({"default"})
        self.assertNotIn("image_data_url", await service.preview("default", "chat"))
        self.assertEqual(spawn.shots(), 1)
        await service.close()

    async def test_a_cached_picture_is_not_reused_once_the_bot_is_private(self):
        private = {"names": frozenset()}
        capture = AsyncMock(return_value="frame")
        service = core.PreviewService(AsyncMock(return_value=rows()), capture, lambda: 100.0,
                                      private_reader=lambda: private["names"])
        self.assertEqual((await service.preview("default", "chat"))["state"], "live")
        names = iter([frozenset(), frozenset({"default"})])
        service.private_reader = lambda: next(names, frozenset({"default"}))
        self.assertNotIn("image_data_url", await service.preview("default", "chat"))
        self.assertEqual(capture.await_count, 1)

    async def test_one_caller_giving_up_does_not_cancel_the_shared_picture(self):
        gate = asyncio.Event()
        spawn = Spawner(gate=gate)
        service = core.PreviewService(AsyncMock(return_value=rows()), pool=core.CapturePool(spawn))
        first = asyncio.create_task(service.preview("default", "chat"))
        second = asyncio.create_task(service.preview("default", "chat", fresh=True))
        await settle()
        first.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await first
        gate.set()
        self.assertEqual((await second)["state"], "live")
        self.assertIsNone(spawn.children[0].returncode)
        await service.close()


class PausedPoolTests(unittest.IsolatedAsyncioTestCase):
    """A saved sign-in pauses fresh=1 callers and shared pictures exactly as it pauses the cached preview."""

    PAUSED = {"state": "paused", "kind": "space", "computer_name": "desk",
              "message": "Paused while Nollie types a saved sign-in."}

    def setUp(self):
        patch.object(core, "read_owned_space", return_value=None).start()
        self.addCleanup(patch.stopall)

    async def test_fresh_never_captures_while_paused(self):
        spawn, typing = Spawner(), {"now": True}
        service = core.PreviewService(AsyncMock(return_value=rows()), pool=core.CapturePool(spawn),
                                      typing_reader=lambda: typing["now"])
        for _ in range(3):
            self.assertEqual(await service.preview("default", "chat", fresh=True), self.PAUSED)
        self.assertEqual(spawn.shots(), 0)
        self.assertEqual(spawn.children, [])
        typing["now"] = False
        self.assertEqual((await service.preview("default", "chat", fresh=True))["state"], "live")
        self.assertEqual(spawn.shots(), 1)
        await service.close()

    async def test_a_shared_picture_that_lands_after_a_sign_in_began_reaches_no_one(self):
        gate, typing = asyncio.Event(), {"now": False}
        spawn = Spawner(gate=gate)
        service = core.PreviewService(AsyncMock(return_value=rows()), pool=core.CapturePool(spawn),
                                      typing_reader=lambda: typing["now"])
        waiting = [asyncio.create_task(service.preview("default", chat, fresh=True)) for chat in ("chat", "other")]
        await settle()
        self.assertEqual(spawn.shots(), 1)
        typing["now"] = True
        gate.set()
        self.assertEqual(await asyncio.gather(*waiting), [self.PAUSED, self.PAUSED])
        self.assertEqual(service._cache, {})
        # The kept child stays for the next picture; nothing from before the pause is served.
        self.assertIsNone(spawn.children[0].returncode)
        typing["now"] = False
        answer = await service.preview("default", "chat")
        self.assertEqual(answer["state"], "live")
        self.assertEqual(spawn.shots(), 2)
        self.assertEqual(len(spawn.children), 1)
        await service.close()

    async def test_by_default_a_typed_sign_in_in_the_main_home_pauses(self):
        spawn = Spawner()
        service = core.PreviewService(AsyncMock(return_value=rows()), pool=core.CapturePool(spawn))
        folder = Path(MAIN_HOME.name) / "nollie-workflow" / "sign-ins" / "requests"
        folder.mkdir(parents=True, exist_ok=True)
        request = folder / ("b" * 32 + ".json")
        now = int(time.time())
        request.write_text(json.dumps({"state": "filling", "created_at": now, "updated_at": now}))
        self.addCleanup(request.unlink, missing_ok=True)
        self.assertEqual(await service.preview("default", "chat", fresh=True), self.PAUSED)
        self.assertEqual(spawn.shots(), 0)
        request.unlink()
        self.assertEqual((await service.preview("default", "chat", fresh=True))["state"], "live")
        await service.close()


class RouteTests(unittest.TestCase):
    def test_fresh_is_optional_and_passed_through(self):
        try:
            from fastapi import FastAPI
            from fastapi.testclient import TestClient
        except ImportError:
            self.skipTest("fastapi is not installed")
        api = load("nollie_computer_api_for_pool_test", ROOT / "dashboard/plugin_api.py")
        asked = []
        async def preview(profile, session_id, fresh=False):
            asked.append((profile, session_id, fresh))
            return {"state": "idle", "message": "No computer has been used in this chat yet."}
        api._service = SimpleNamespace(preview=preview)
        app = FastAPI()
        app.include_router(api.router)
        client = TestClient(app)
        for query, fresh in (({}, False), ({"fresh": "1"}, True), ({"fresh": "0"}, False)):
            reply = client.get("/preview", params={"profile": "default", "session_id": "chat", **query})
            self.assertEqual(reply.status_code, 200)
            self.assertEqual(reply.headers["cache-control"], "no-store")
            self.assertEqual(reply.json()["state"], "idle")
            self.assertEqual(asked[-1], ("default", "chat", fresh))
        self.assertEqual(client.get("/preview", params={"profile": "default", "session_id": "chat",
                                                        "fresh": "maybe"}).status_code, 422)
        self.assertEqual(len(asked), 3)

    def test_paused_says_the_previews_own_answer(self):
        try:
            from fastapi import FastAPI
            from fastapi.testclient import TestClient
        except ImportError:
            self.skipTest("fastapi is not installed")
        api = load("nollie_computer_api_for_paused_test", ROOT / "dashboard/plugin_api.py")
        app = FastAPI()
        app.include_router(api.router)
        client = TestClient(app)
        for answer in (True, False):
            api._service.typing_reader = lambda: answer
            reply = client.get("/paused")
            self.assertEqual((reply.status_code, reply.json()), (200, {"paused": answer}))
            self.assertEqual(reply.headers["cache-control"], "no-store")
        # A check that fails pauses, as the preview does.
        def broken():
            raise OSError("disk")
        api._service.typing_reader = broken
        self.assertEqual(client.get("/paused").json(), {"paused": True})
        self.assertEqual(client.post("/paused").status_code, 405)


if __name__ == "__main__":
    unittest.main()
