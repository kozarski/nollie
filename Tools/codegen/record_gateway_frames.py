#!/usr/bin/env python3
"""Record real gateway frames from a throwaway Hermes for the wire-type tests.

    python3 Tools/codegen/record_gateway_frames.py

Starts Hermes's stdio gateway (the same JSON-RPC as /api/ws) with HOME and HERMES_HOME pointed at a new
temporary folder, so it never sees your own Hermes, its settings or its history. No AI provider is set up,
so a prompt fails quickly but still produces real session events with seq numbers. Writes
Tests/Unit/Fixtures/GatewayRecordedFrames.swift with each call, its answer and every event, after replacing
the temporary folder's path with /tmp/nollie-fixture.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERMES = Path.home() / ".hermes/hermes-agent/.hermes/bin/hermes"
OUTPUT = ROOT / "Tests/Unit/Fixtures/GatewayRecordedFrames.swift"
PLACEHOLDER = "/tmp/nollie-fixture"


class Recorder:
    def __init__(self, home: Path):
        env = {"HOME": str(home), "HERMES_HOME": str(home / ".hermes"), "PATH": "/usr/bin:/bin",
               "PYTHONDONTWRITEBYTECODE": "1"}
        (home / ".hermes").mkdir(parents=True)
        self.process = subprocess.Popen([str(HERMES), "--run-module", "tui_gateway.entry"], cwd=home, env=env,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                        text=True)
        self.frames: list[str] = []
        self.calls: list[tuple[str, dict, int]] = []
        self.lock = threading.Lock()
        self.next_id = 0
        threading.Thread(target=self.read, daemon=True).start()

    def read(self) -> None:
        for line in self.process.stdout:
            if line.strip():
                with self.lock:
                    self.frames.append(line.strip())

    def answer(self, call_id: int):
        with self.lock:
            for line in self.frames:
                frame = json.loads(line)
                if frame.get("id") == call_id and "method" not in frame:
                    return frame
        return None

    def call(self, method: str, params: dict, wait: float = 6.0):
        self.next_id += 1
        call_id = self.next_id
        self.calls.append((method, params, call_id))
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": call_id, "method": method, "params": params}) + "\n")
        self.process.stdin.flush()
        deadline = time.time() + wait
        while time.time() < deadline:
            if (frame := self.answer(call_id)) is not None:
                return frame
            time.sleep(0.05)
        return None

    def wait_for_ready(self, wait: float = 60.0) -> None:
        deadline = time.time() + wait
        while time.time() < deadline:
            with self.lock:
                if any('"gateway.ready"' in line for line in self.frames):
                    return
            time.sleep(0.1)
        raise SystemExit("Hermes never said it was ready")

    def stop(self) -> None:
        self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.terminate()


def script(rec: Recorder) -> None:
    rec.call("client.capabilities", {"server_requests": True})
    rec.call("ping", {})
    rec.call("gateway.capabilities", {})
    rec.call("session.events.stats", {})
    created = rec.call("session.create", {"cols": 80}, wait=20) or {}
    session = (created.get("result") or {}).get("session_id")
    if session:
        rec.call("approval.pending", {"session_id": session})
        rec.call("prompt.submit", {"session_id": session, "text": "hello"}, wait=20)
        time.sleep(8)
        rec.call("session.events.since", {"session_id": session, "last_seen": 0})
        rec.call("session.events.since", {"session_id": session, "last_seen": 2})
        rec.call("session.interrupt", {"session_id": session})
        rec.call("session.close", {"session_id": session})
    rec.call("session.events.since", {"session_id": "missing-session", "last_seen": 5})
    for method in ("session.list", "session.active_list", "projects.list", "session.most_recent", "i18n.languages"):
        rec.call(method, {})
    rec.call("profiles.list", {}, wait=15)
    rec.call("no.such.method", {})
    rec.call("prompt.submit", {"session_id": "missing", "text": "x"})


def scrub(text: str, home: Path) -> str:
    for spelling in {str(home), str(home.resolve()), "/private" + str(home)}:
        text = text.replace(spelling, PLACEHOLDER)
    return text


def swift_raw(text: str) -> str:
    if '"###' in text:
        raise SystemExit("a frame would end the raw string")
    return f'###"{text}"###'


def render(rec: Recorder, home: Path) -> str:
    lines = ["// Recorded by Tools/codegen/record_gateway_frames.py from a throwaway Hermes. Do not edit.", "",
             "/// Real frames from Hermes's gateway, in arrival order, and the calls that produced the answers.",
             "let gatewayRecordedCalls: [GatewayRecordedCall] = ["]
    for method, params, call_id in rec.calls:
        lines.append(f"    GatewayRecordedCall(id: {call_id}, method: {json.dumps(method)}, "
                     f"params: {swift_raw(scrub(json.dumps(params), home))}),")
    lines.append("]")
    lines.append("")
    lines.append("let gatewayRecordedFrames: [String] = [")
    with rec.lock:
        for frame in rec.frames:
            lines.append(f"    {swift_raw(scrub(frame, home))},")
    lines.append("]")
    return "\n".join(lines) + "\n"


def main() -> int:
    if not HERMES.exists():
        print(f"Hermes is not installed at {HERMES}", file=sys.stderr)
        return 1
    home = Path(tempfile.mkdtemp(prefix="nollie-frames-"))
    try:
        rec = Recorder(home)
        rec.wait_for_ready()
        script(rec)
        time.sleep(1)
        rec.stop()
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(render(rec, home), encoding="utf-8")
        print(f"{len(rec.frames)} frames, {len(rec.calls)} calls")
    finally:
        shutil.rmtree(home, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
