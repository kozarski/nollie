import asyncio
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import time
from types import SimpleNamespace
import unittest

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed, InvalidStatus

spec = importlib.util.spec_from_file_location("live_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)

FIXTURE = Path(__file__).with_name("fixtures") / "live-desktop.hevclive"


def decode_video(message: bytes) -> dict:
    """LiveWire version 1 video, read here on its own (not with the mock's code) and as strictly
    as the app reads it: a 20-byte header, parameter sets on keyframes only, then NAL units that
    fill the rest exactly."""
    assert len(message) >= 20, "short header"
    version, kind, flags, codec, sequence, micros, width, height = struct.unpack_from(">BBBBIQHH", message)
    assert (version, kind, codec) == (1, 1, 1), (version, kind, codec)
    assert flags & ~0b11 == 0, f"unknown flags {flags}"
    keyframe, has_format = bool(flags & 1), bool(flags & 2)
    assert keyframe == has_format, "a keyframe carries its format and nothing else does"
    assert 1 <= width <= 8192 and 1 <= height <= 8192
    offset, sets = 20, None
    if has_format:
        count = message[offset]
        offset += 1
        assert 1 <= count <= 8
        sets = []
        for _ in range(count):
            (length,) = struct.unpack_from(">H", message, offset)
            assert 1 <= length <= 4096
            sets.append(message[offset + 2:offset + 2 + length])
            assert len(sets[-1]) == length, "truncated parameter set"
            offset += 2 + length
    units = []
    while offset < len(message):
        assert len(message) - offset >= 4, "truncated NAL length"
        (length,) = struct.unpack_from(">I", message, offset)
        assert length >= 1 and offset + 4 + length <= len(message), "NAL units must fill the sample exactly"
        units.append(message[offset + 4:offset + 4 + length])
        offset += 4 + length
    assert units, "a frame has at least one NAL unit"
    return {"keyframe": keyframe, "sequence": sequence, "micros": micros, "width": width, "height": height,
            "sets": sets, "units": units}


def fixture_messages() -> list[bytes]:
    data = FIXTURE.read_bytes()
    assert data[:4] == b"NLV1"
    (count,), offset, out = struct.unpack_from(">I", data, 4), 8, []
    for _ in range(count):
        (length,) = struct.unpack_from(">I", data, offset)
        out.append(data[offset + 4:offset + 4 + length])
        assert len(out[-1]) == length
        offset += 4 + length
    assert offset == len(data), "nothing after the last message"
    return out


class LiveFixtureTests(unittest.TestCase):
    def test_every_message_is_good_wire_and_only_the_first_is_a_keyframe(self):
        self.assertLess(FIXTURE.stat().st_size, 400_000)
        videos = [decode_video(message) for message in fixture_messages()]
        self.assertEqual(len(videos), 60, "four seconds at 15 fps")
        self.assertEqual([v["keyframe"] for v in videos], [True] + [False] * 59)
        self.assertEqual(len(videos[0]["sets"]), 3, "VPS, SPS and PPS")
        # HEVC NAL types: VPS 32, SPS 33, PPS 34, in VideoToolbox's order.
        self.assertEqual([(s[0] >> 1) & 0x3F for s in videos[0]["sets"]], [32, 33, 34])
        self.assertEqual({(v["width"], v["height"]) for v in videos}, {(1280, 800)})
        self.assertEqual([v["sequence"] for v in videos], list(range(60)))
        self.assertGreater(len({b"".join(v["units"]) for v in videos}), 50, "the picture moves")


class LiveSocketTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        mock.COMPUTER_PREVIEW.update(state="live", active=False, held=False, live_connections=0, live_frames=0,
                                     live_keyframes=0, last_report=None)
        mock.PRIVATE_BOTS["profiles"] = None
        mock.sign_ins_reset()
        self.beat = mock.LIVE_BEAT_SECONDS
        mock.LIVE_BEAT_SECONDS = 0.25
        self.saved = (mock.LIVE_FIXTURE, list(mock._LIVE_FRAMES), mock.NOTIFICATION_ACTIVITY_DEMO)
        self.server = await serve(mock.ws_handler, "127.0.0.1", 0, process_request=mock.process_request, max_size=None)
        self.port = self.server.sockets[0].getsockname()[1]

    async def asyncTearDown(self):
        self.server.close()
        await self.server.wait_closed()
        mock.LIVE_BEAT_SECONDS = self.beat
        mock.LIVE_FIXTURE, mock._LIVE_FRAMES[:], mock.NOTIFICATION_ACTIVITY_DEMO = self.saved

    def url(self, profile="default", session=None):
        return f"ws://127.0.0.1:{self.port}/nollie/live?profile={profile}&session_id={session or mock.COMPUTER_SESSION}"

    async def read(self, ws, seconds, until=None):
        """Messages for up to `seconds`: ("video", fields) or (type, json), stopping after `until` matches."""
        loop = asyncio.get_running_loop()
        end, out = loop.time() + seconds, []
        while (left := end - loop.time()) > 0:
            try:
                raw = await asyncio.wait_for(ws.recv(), left)
            except TimeoutError:
                break
            if isinstance(raw, bytes):
                item = ("video", {**decode_video(raw), "at": time.time()})
            else:
                body = json.loads(raw)
                item = (body["type"], body)
            out.append(item)
            if until and until(item):
                break
        return out

    @staticmethod
    def videos(items):
        return [fields for kind, fields in items if kind == "video"]

    async def until_closed(self, ws):
        """Everything left before the close, as read()'s items."""
        items = []
        with self.assertRaises(ConnectionClosed):
            while True:
                raw = await asyncio.wait_for(ws.recv(), 3)
                items.append(("video", decode_video(raw)) if isinstance(raw, bytes) else (json.loads(raw)["type"], json.loads(raw)))
        return items

    async def assert_ends(self, url, reason, code):
        async with connect(url) as ws:
            items = await self.until_closed(ws)
            self.assertEqual(items[-1], ("end", {"type": "end", "reason": reason}), items[-3:])
            self.assertEqual(ws.close_code, code)
        return items

    async def test_hello_then_pointer_then_keyframe_and_frames_stamped_now(self):
        async with connect(self.url()) as ws:
            self.assertEqual(json.loads(await ws.recv()), {"type": "hello", "v": 1, "kind": "space",
                                                           "computer": "Studio desktop", "source": {"w": 1280, "h": 800}})
            pointer = json.loads(await ws.recv())
            self.assertEqual(pointer["type"], "pointer")
            self.assertTrue(0 <= pointer["x"] < 1280 and 0 <= pointer["y"] < 800, pointer)
            self.assertAlmostEqual(pointer["at"], time.time(), delta=2)
            items = await self.read(ws, 1.0)
        videos = self.videos(items)
        self.assertGreaterEqual(len(videos), 10, "about 15 a second")
        self.assertTrue(videos[0]["keyframe"])
        self.assertEqual(len(videos[0]["sets"]), 3)
        self.assertTrue(all(not v["keyframe"] for v in videos[1:]))
        self.assertEqual([v["sequence"] for v in videos], list(range(len(videos))))
        for video in videos:
            self.assertLess(abs(video["micros"] / 1e6 - video["at"]), 0.5, "captureMicros is the time it was sent")
        self.assertIn("beat", [kind for kind, _ in items])
        moved = [fields for kind, fields in items if kind == "pointer"]
        self.assertTrue(moved and moved[-1]["x"] != pointer["x"], "the pointer follows the progress bar")

    async def test_beats_come_once_a_second(self):
        mock.LIVE_BEAT_SECONDS = 1.0
        async with connect(self.url()) as ws:
            items = await self.read(ws, 2.3)
        beats = [fields for kind, fields in items if kind == "beat"]
        self.assertEqual(len(beats), 3, beats)
        for earlier, later in zip(beats, beats[1:]):
            self.assertAlmostEqual((later["t"] - earlier["t"]) / 1e6, 1.0, delta=0.2)
        self.assertEqual(beats[0], {"type": "beat", "t": beats[0]["t"], "fresh": True, "link": "fine", "level": 0,
                                    "control": "helper"})
        self.assertAlmostEqual(beats[-1]["t"] / 1e6, time.time(), delta=1.5)

    async def test_a_keyframe_request_starts_the_picture_over(self):
        async with connect(self.url()) as ws:
            first = self.videos(await self.read(ws, 0.8))
            self.assertGreater(len(first), 5)
            await ws.send(json.dumps({"type": "keyframe"}))
            after = self.videos(await self.read(ws, 0.5, until=lambda item: item[0] == "video" and item[1]["keyframe"]))
        self.assertTrue(after and after[-1]["keyframe"], "a keyframe comes soon after the request")
        self.assertEqual(len(after[-1]["sets"]), 3)
        sequences = [v["sequence"] for v in first + after]
        self.assertEqual(sequences, list(range(len(sequences))), "the sequence keeps counting")
        self.assertEqual(mock.COMPUTER_PREVIEW["live_keyframes"], 1)

    async def test_held_stops_frames_but_beats_go_on_saying_you(self):
        async with connect(self.url()) as ws:
            before = self.videos(await self.read(ws, 0.5))
            await mock.computer_preview_control("POST", {"held": True})
            await self.read(ws, 0.1)
            held = await self.read(ws, 0.7)
            await mock.computer_preview_control("POST", {"held": False})
            resumed = self.videos(await self.read(ws, 0.4))
        self.assertEqual(self.videos(held), [], "a waiting helper's screen stays still")
        beats = [fields for kind, fields in held if kind == "beat"]
        self.assertGreaterEqual(len(beats), 2)
        self.assertTrue(all(b["fresh"] and b["control"] == "you" for b in beats), beats)
        self.assertTrue(resumed and not resumed[0]["keyframe"], "the picture carries on where it stopped")
        self.assertGreater(resumed[0]["sequence"], before[-1]["sequence"])

    async def test_stale_beats_say_not_fresh_and_send_no_frames(self):
        await mock.computer_preview_control("POST", {"state": "stale"})
        async with connect(self.url()) as ws:
            items = await self.read(ws, 0.7)
            self.assertEqual([kind for kind, _ in items[:2]], ["hello", "pointer"])
            self.assertEqual(self.videos(items), [])
            beats = [fields for kind, fields in items if kind == "beat"]
            self.assertGreaterEqual(len(beats), 2)
            self.assertTrue(all(not b["fresh"] for b in beats))
            await mock.computer_preview_control("POST", {"state": "live"})
            back = self.videos(await self.read(ws, 0.5))
        self.assertTrue(back and back[0]["keyframe"], "a picture coming back starts from a keyframe")

    async def test_a_sign_in_being_typed_holds_every_picture_back_as_the_preview_does(self):
        request = {"id": "a" * 32, "bot": "default", "site": "example.com", "computer": "local:dev", "focus": "username",
                   "state": "approved", "approver": "mac", "outcome": None, "reason": None, "code_note": False,
                   "created_at": int(time.time())}
        async with connect(self.url()) as ws:
            before = self.videos(await self.read(ws, 0.5))
            mock.SIGN_INS["requests"][request["id"]] = request
            # The beat saying so comes at once, not up to a beat later.
            first = await self.read(ws, 0.2, until=lambda item: item[0] == "beat" and "hold" in item[1])
            paused = await self.read(ws, 0.7)
            preview = mock.computer_preview_rest({"profile": "default", "session_id": mock.COMPUTER_SESSION})
            said = mock.rest("/api/plugins/nollie-computer/paused", {})
            request["state"] = "filling"
            still = await self.read(ws, 0.3)
            request["state"] = "done"
            back = await self.read(ws, 0.6)
        self.assertTrue(before)
        self.assertEqual(first[-1][1]["hold"], "sign_in")
        self.assertEqual(self.videos(paused) + self.videos(still), [], "no picture while a sign-in is typed")
        beats = [fields for kind, fields in paused + still if kind == "beat"]
        self.assertGreaterEqual(len(beats), 3)
        self.assertTrue(all(b["hold"] == "sign_in" and not b["fresh"] for b in beats), beats)
        self.assertEqual(preview, (200, {"state": "paused", "kind": "space", "computer_name": "Studio desktop",
                                         "message": "Paused while Nollie types a saved sign-in."}))
        self.assertEqual(said, (200, {"paused": True}))
        videos = self.videos(back)
        self.assertTrue(videos and videos[0]["keyframe"], "pictures come back from a keyframe")
        self.assertGreater(videos[0]["sequence"], before[-1]["sequence"])
        # One held beat may already have been on its way; from the first that isn't, none is.
        after = [fields for kind, fields in back if kind == "beat"]
        clear = next(i for i, b in enumerate(after) if "hold" not in b)
        self.assertTrue(all("hold" not in b and b["fresh"] for b in after[clear:]), after)
        self.assertEqual(mock.rest("/api/plugins/nollie-computer/paused", {}), (200, {"paused": False}))
        self.assertEqual(mock.computer_preview_rest({"profile": "default", "session_id": mock.COMPUTER_SESSION})[1]["state"], "live")

    async def test_the_paused_state_holds_pictures_back_too(self):
        await mock.computer_preview_control("POST", {"state": "paused"})
        async with connect(self.url()) as ws:
            items = await self.read(ws, 0.7)
            self.assertEqual([kind for kind, _ in items[:2]], ["hello", "pointer"])
            self.assertEqual(self.videos(items), [])
            beats = [fields for kind, fields in items if kind == "beat"]
            self.assertTrue(beats and all(b["hold"] == "sign_in" and not b["fresh"] for b in beats), beats)
            await mock.computer_preview_control("POST", {"state": "live"})
            back = self.videos(await self.read(ws, 0.5))
        self.assertTrue(back and back[0]["keyframe"])

    async def test_pictures_stay_paused_for_the_add_ons_tail_after_a_fill(self):
        request = {"id": "b" * 32, "bot": "default", "site": "example.com", "computer": "local:dev", "focus": "username",
                   "state": "filling", "approver": "mac", "outcome": None, "reason": None, "code_note": False,
                   "created_at": int(time.time())}
        mock.SIGN_INS["requests"][request["id"]] = request
        paused = lambda: mock.rest("/api/plugins/nollie-computer/paused", {})
        self.assertEqual(paused(), (200, {"paused": True}))
        status, _ = mock.sign_ins_rest("POST", f"/api/plugins/nollie-workflow/sign-ins/requests/{request['id']}/result",
                                       {}, {"outcome": "signed_in"})
        self.assertEqual(status, 200)
        self.assertEqual(request["state"], "done")
        self.assertEqual(paused(), (200, {"paused": True}), "still paused right after the fill, as the add-on is")
        self.assertEqual(mock.computer_preview_rest({"profile": "default", "session_id": mock.COMPUTER_SESSION})[1]["state"], "paused")
        self.assertAlmostEqual(request["quiet_until"], time.time() + mock.SIGN_IN_SETTLE, delta=2)
        request["quiet_until"] = time.time() - 1
        self.assertEqual(paused(), (200, {"paused": False}), "and not once the tail has passed")

    async def test_wrong_chat_or_private_bot_is_refused(self):
        for url in (self.url(session="20260101_000000_nope00"), self.url(profile="moss"),
                    self.url(profile="private"), self.url(profile="work")):
            async with connect(url) as ws:
                self.assertEqual(json.loads(await ws.recv()), {"type": "end", "reason": "refused"})
                with self.assertRaises(ConnectionClosed):
                    await ws.recv()
                self.assertEqual(ws.close_code, 1008)
        self.assertEqual(mock.COMPUTER_PREVIEW["live_frames"], 0)

    async def test_unsupported_answers_the_upgrade_with_404(self):
        await mock.computer_preview_control("POST", {"state": "unsupported"})
        with self.assertRaises(InvalidStatus) as refused:
            async with connect(self.url()):
                pass
        self.assertEqual(refused.exception.response.status_code, 404)

    async def test_viewer_rules_binary_big_and_unknown_messages_close(self):
        cases = ((b"\x00", 1003), ("x" * 600, 1008), (json.dumps({"type": "hello"}), 1008),
                 (json.dumps({"type": "report", "t": 0, "got": -1, "shown": 0, "late": 0, "limit": "none"}), 1008),
                 ("not json", 1008))
        for message, code in cases:
            async with connect(self.url()) as ws:
                await ws.recv()
                await ws.send(message)
                with self.assertRaises(ConnectionClosed):
                    while True:
                        await asyncio.wait_for(ws.recv(), 2)
                self.assertEqual(ws.close_code, code, message)

    async def test_a_chat_that_never_used_a_computer_ends_stopped(self):
        items = await self.assert_ends(self.url(session="20260921_093355_d4e5f6"), "stopped", 1000)
        self.assertEqual(len(items), 1)

    async def test_unavailable_at_connect_ends_the_stream(self):
        await mock.computer_preview_control("POST", {"state": "unavailable"})
        items = await self.assert_ends(self.url(), "unavailable", 1013)
        self.assertEqual(len(items), 1)

    async def test_unavailable_mid_stream_ends_the_stream(self):
        async with connect(self.url()) as ws:
            self.assertTrue(self.videos(await self.read(ws, 0.4)))
            await mock.computer_preview_control("POST", {"state": "unavailable"})
            items = await self.until_closed(ws)
            self.assertEqual(items[-1], ("end", {"type": "end", "reason": "unavailable"}))
            self.assertEqual(ws.close_code, 1013)

    async def test_a_missing_fixture_is_unavailable(self):
        mock.LIVE_FIXTURE, mock._LIVE_FRAMES[:] = str(FIXTURE.with_name("missing.hevclive")), []
        await self.assert_ends(self.url(), "unavailable", 1013)

    async def test_a_cut_fixture_is_unavailable_and_leaves_nothing_behind(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        cut = Path(folder.name) / "cut.hevclive"
        cut.write_bytes(FIXTURE.read_bytes()[:15_000])
        mock.LIVE_FIXTURE, mock._LIVE_FRAMES[:] = str(cut), []
        for _ in range(2):
            await self.assert_ends(self.url(), "unavailable", 1013)
            self.assertEqual(mock._LIVE_FRAMES, [])
        cut.write_bytes(FIXTURE.read_bytes() + b"\x00")
        await self.assert_ends(self.url(), "unavailable", 1013)
        self.assertEqual(mock._LIVE_FRAMES, [])

    async def test_a_viewer_joining_while_held_gets_one_keyframe(self):
        await mock.computer_preview_control("POST", {"held": True})
        async with connect(self.url()) as ws:
            items = await self.read(ws, 0.3, until=lambda item: item[0] == "video")
            first = self.videos(items)
            after = await self.read(ws, 0.6)
        self.assertEqual(len(first), 1)
        self.assertTrue(first[0]["keyframe"])
        self.assertEqual(self.videos(after), [], "then the screen stays still")
        self.assertTrue(all(fields["control"] == "you" for kind, fields in items + after if kind == "beat"))

    async def test_idle_beats_say_not_fresh_and_send_no_frames(self):
        await mock.computer_preview_control("POST", {"state": "idle"})
        async with connect(self.url()) as ws:
            items = await self.read(ws, 0.7)
        self.assertEqual(self.videos(items), [])
        beats = [fields for kind, fields in items if kind == "beat"]
        self.assertGreaterEqual(len(beats), 2)
        self.assertTrue(all(not b["fresh"] for b in beats))

    async def test_the_activity_chat_streams_the_work_desktop_even_when_unsupported(self):
        mock.NOTIFICATION_ACTIVITY_DEMO = True
        await mock.computer_preview_control("POST", {"state": "unsupported"})
        async with connect(self.url(profile="work", session=mock.ACTIVITY_SESSION)) as ws:
            self.assertEqual(json.loads(await ws.recv())["computer"], "Work desktop")
            items = await self.read(ws, 0.7)
        self.assertGreater(len(self.videos(items)), 5)
        beats = [fields for kind, fields in items if kind == "beat"]
        self.assertTrue(beats and all(b["fresh"] and b["control"] is None for b in beats), beats)
        with self.assertRaises(InvalidStatus) as refused:
            async with connect(self.url()):
                pass
        self.assertEqual(refused.exception.response.status_code, 404, "the computer chat still has no live picture")

    async def test_a_huge_viewer_message_is_never_read_in_full(self):
        async with connect(self.url(), max_size=None) as ws:
            await ws.recv()
            await ws.send("x" * 5_000_000)
            with self.assertRaises(ConnectionClosed):
                while True:
                    await asyncio.wait_for(ws.recv(), 3)
            self.assertEqual(ws.close_code, 1009)

    async def test_counters_move_and_reset(self):
        def request(method="GET", body=None):
            return SimpleNamespace(path="/api/_mock/computer-preview", method=method, body=json.dumps(body or {}).encode(),
                                   headers={})
        report = {"type": "report", "t": 0, "got": 12, "shown": 12, "late": 0, "limit": "low"}
        async with connect(self.url()) as ws:
            await self.read(ws, 0.4)
            await ws.send(json.dumps(report))
            await self.read(ws, 0.2)
            seen = json.loads((await mock.process_request(None, request())).body)
            self.assertEqual(seen["live_open"], 1)
        self.assertEqual(seen["live_connections"], 1)
        self.assertGreater(seen["live_frames"], 3)
        self.assertEqual(seen["last_report"], report)
        for _ in range(50):
            if mock.COMPUTER_PREVIEW["live_open"] == 0:
                break
            await asyncio.sleep(0.02)
        self.assertEqual(mock.COMPUTER_PREVIEW["live_open"], 0)
        reset = json.loads((await mock.process_request(None, request("POST", {"reset_log": True}))).body)
        self.assertEqual({key: reset[key] for key in ("live_open", "live_connections", "live_frames", "last_report")},
                         {"live_open": 0, "live_connections": 0, "live_frames": 0, "last_report": None})


if __name__ == "__main__":
    unittest.main()
