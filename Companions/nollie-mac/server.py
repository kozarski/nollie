#!/usr/bin/env python3
"""Nollie Mac: an MCP server (stdio) that lets a bot use apps on this Mac, the safe way.

1. `mac_start` asks the Nollie app, for apps the person picked for this Mac. The person approves
   them on a card on the Mac; only then does Nollie start its Nollie Computer helper, limited to
   those apps, for 30 minutes at most.
2. `mac_do` asks for one step in one app. A model on this Mac looks at that window and picks each
   action; Nollie checks every one (approved app, the window in front, view-only browsers, risky
   clicks the person confirms, passwords never) and runs it through the helper's private session.
   Only a short sentence comes back: never a screenshot, never the window's words, so nothing of
   the screen reaches the bot's own model. This server never talks to the helper directly.
3. `mac_done`, Stop on the Mac, the time limit or 5 idle minutes end it; nothing keeps running.

The companion plugin (__init__.py) stamps each call with its chat (`_nollie`) and refuses
scheduled or unattended runs; without the stamp this server refuses everything. Nollie checks the
session with Hermes itself before it shows a card, so a stamp a model wrote isn't enough. Nollie
also checks this very process (run by Hermes's gateway or dashboard, exactly as installed, this
file unchanged), and a task answers only to it. Nollie's task id never leaves this process.
Standard library only. Setting: NOLLIE_MAC_SOCKET (Nollie's socket, for tests).
"""
import json
import os
import socket
import sys

APP_SOCKET = os.environ.get("NOLLIE_MAC_SOCKET") or os.path.expanduser(
    "~/Library/Application Support/Nollie/Computer/control.sock")
NO_STAMP = "Nollie Mac needs its Hermes plugin (nollie-mac) enabled for this bot. Nothing was done."
NOT_STARTED = "No apps are approved for this chat. Use mac_start first."
APP = {"type": "string", "description": "An app approved with mac_start, by name."}
# Longer than Nollie's slowest answer (two minutes for a card, then up to two more for starting
# the helper or running the action), and within Hermes's own five-minute tool limit.
WAIT_FOR_PERSON = 280


def tool(name, description, properties, required=()):
    return {"name": name, "description": description,
            "inputSchema": {"type": "object", "properties": properties, "required": list(required)}}


TOOLS = [
    tool("mac_start", "Ask the person to let you use some of the apps they picked on their Mac for this task. "
         "They approve on the Mac. Never: Nollie, terminals, password managers, System Settings, money apps. "
         "Browsers are view-only. Sending, buying, deleting, uploading, accepting terms, installing and "
         "signing in are confirmed by the person each time.",
         {"apps": {"type": "array", "items": {"type": "string", "maxLength": 100}, "maxItems": 8},
          "task": {"type": "string", "maxLength": 300}},
         ["apps", "task"]),
    tool("mac_do", "Do one step in an approved app, said plainly, like \"make a new note titled Groceries\". "
         "A model on the Mac does the clicking and answers with one short sentence; you never see the screen. "
         "Give the words to type in the step itself. Keep each step small.",
         {"app": APP, "step": {"type": "string", "maxLength": 500}}, ["app", "step"]),
    tool("mac_done", "Say you are finished with the Mac. Nollie ends access straight away.", {}),
]


class Refused(Exception):
    pass


def ask(path, request, timeout):
    """One JSON line to Nollie's socket, one JSON line back."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(timeout)
        try:
            s.connect(path)
            s.sendall(json.dumps(request).encode() + b"\n")
            reply = b""
            while not reply.endswith(b"\n"):
                chunk = s.recv(1 << 20)
                if not chunk:
                    break
                reply += chunk
        except OSError:
            raise Refused("Nollie isn't answering. Open Nollie on the Mac and try again.") from None
    try:
        reply = json.loads(reply)
    except ValueError:
        raise Refused("Nollie sent an answer that couldn't be read.") from None
    if not isinstance(reply, dict) or not reply.get("ok"):
        raise Refused(str((reply or {}).get("error") or "Nollie said no."))
    return reply


class Mac:
    def __init__(self, app_socket=APP_SOCKET):
        self.app_socket = app_socket
        self.tasks = {}  # chat (session id) -> Nollie's task id

    def call(self, name, args):
        stamp = args.pop("_nollie", None)
        if not isinstance(stamp, dict) or not stamp.get("session_id"):
            raise Refused(NO_STAMP)
        session = str(stamp.get("chat") or stamp["session_id"])
        if name == "mac_start":
            apps = [str(a) for a in args.get("apps") or []][:8]
            reply = ask(self.app_socket, {"op": "start", "session_id": str(stamp["session_id"]), "chat": session,
                                          "profile": str(stamp.get("profile", "")),
                                          "apps": apps, "purpose": str(args.get("task", ""))[:300]}, WAIT_FOR_PERSON)
            self.tasks[session] = reply["task"]
            names = ", ".join(a["name"] + (" (view only)" if a.get("view_only") else "") for a in reply.get("apps", []))
            return [{"type": "text", "text": f"Approved for this task: {names}. Use mac_do, one step at a time. Access "
                     "ends after 30 minutes, after 5 minutes without an action, or when the person presses Stop."}]
        task = self.tasks.get(session)
        if task is None:
            raise Refused(NOT_STARTED)
        if name == "mac_done":
            del self.tasks[session]
            ask(self.app_socket, {"op": "end", "task": task}, 10)
            return [{"type": "text", "text": "Done. Nollie ended access to the Mac."}]
        if name != "mac_do":
            raise Refused(f"Unknown tool {name}.")
        request = {"op": "do", "task": task, "app": str(args.get("app") or "")[:100],
                   "step": str(args.get("step") or "")[:500]}
        try:
            reply = ask(self.app_socket, request, WAIT_FOR_PERSON)
        except Refused as refusal:
            if "has ended" in str(refusal):
                self.tasks.pop(session, None)
            raise
        # Words only, however Nollie answers: a picture of the screen never reaches the bot.
        words = " ".join(str(c.get("text", "")) for c in reply.get("content", [])
                         if isinstance(c, dict) and c.get("type") == "text").strip()
        return [{"type": "text", "text": words[:300] or "Done."}]


def serve(mac, read=sys.stdin, write=sys.stdout):
    for line in read:
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if not isinstance(message, dict) or message.get("id") is None:
            continue  # notifications need no answer
        method, ident = message.get("method"), message["id"]
        reply = {"jsonrpc": "2.0", "id": ident}
        if method == "initialize":
            version = (message.get("params") or {}).get("protocolVersion", "2025-06-18")
            reply["result"] = {"protocolVersion": version, "capabilities": {"tools": {}},
                               "serverInfo": {"name": "nollie-mac", "version": "0.2.0"}}
        elif method == "tools/list":
            reply["result"] = {"tools": TOOLS}
        elif method == "tools/call":
            params = message.get("params") or {}
            try:
                reply["result"] = {"content": mac.call(str(params.get("name", "")), dict(params.get("arguments") or {}))}
            except Refused as refusal:
                reply["result"] = {"content": [{"type": "text", "text": str(refusal)}], "isError": True}
        elif method == "ping":
            reply["result"] = {}
        else:
            reply["error"] = {"code": -32601, "message": "Method not found"}
        write.write(json.dumps(reply) + "\n")
        write.flush()


if __name__ == "__main__":
    serve(Mac())
