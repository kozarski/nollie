"""One scripted conversation with a real Hermes process: Nollie adds a member, then retires it.

Uses Hermes's offline scripted model (``tests/fakes/fake_llm_provider.py`` in the Hermes
source) and the add-on installed by its own installer, all inside a temporary HOME.
Started by test_hermes.py; prints one JSON object with what it saw.
"""
import json
import os
from pathlib import Path
import pwd
import re
import subprocess
import sys

temp = Path(os.environ["CREW_SCENARIO_TMP"]).resolve()
home = Path(os.environ["HOME"]).resolve()
real = (Path(pwd.getpwuid(os.getuid()).pw_dir) / ".hermes").resolve()
root = home / ".hermes"
if not str(home).startswith(str(temp)) or str(root).startswith(str(real)):
    sys.exit("refusing to run outside a temporary home")

import hermes_yaml  # noqa: E402
from tests.fakes.fake_llm_provider import FakeLLMServer, Text, ToolCall, write_hermes_home  # noqa: E402
from support import install_workflow  # noqa: E402

ADDON = Path(__file__).resolve().parents[1]
ADD = {"name": "Rover", "role": "check new roles each morning", "come_to_me_for": "New job listings, every morning.",
       "asked_by_person": True}
MAC = dict(ADD, name="Pixel", role="tidy the desktop", toolsets=["file", "computer_use"])
DONE = "CREW-SCRIPT-DONE"


def last_user(body):
    for message in reversed(body.get("messages") or []):
        if message.get("role") == "user":
            content = message.get("content")
            return content if isinstance(content, str) else json.dumps(content)
    return ""


def tool_results(body):
    messages = body.get("messages") or []
    start = max((i for i, m in enumerate(messages) if m.get("role") == "user"), default=-1)
    return [m for m in messages[start + 1:] if m.get("role") == "tool"]


def offered(body):
    return {(t.get("function") or {}).get("name") for t in body.get("tools") or []}


def call(body, name, args):
    if name in offered(body) or "tool_call" not in offered(body):
        return ToolCall(name, args)
    return ToolCall("tool_call", {"calls": [{"name": name, "arguments": args}]})


def responder(record):
    body = record["body"]
    asked, done = last_user(body), len(tool_results(body))
    if "add a crew member" in asked:
        steps = [("crew_add", ADD)]
    elif "use the Mac" in asked:
        steps = [("crew_add", MAC)]
    elif "retire" in asked:
        steps = [("crew_retire", {"name": "Rover"}), ("crew_retire", {"name": "Rover", "confirm": True})]
    else:
        steps = []
    return call(body, *steps[done]) if done < len(steps) else Text(DONE)


def payload(text):
    match = re.search(r"^\{.*\}$", text or "", re.MULTILINE | re.DOTALL)
    return json.loads(match.group(0)) if match else {}


def run_chat(prompt, env):
    return subprocess.run([sys.executable, "-m", "hermes_cli.main", "chat", "-q", prompt, "-Q"], env=env,
                          cwd=str(temp), capture_output=True, text=True, timeout=240, stdin=subprocess.DEVNULL)


seen = {}
with FakeLLMServer(responder) as server:
    write_hermes_home(root, server.base_url)
    install_workflow(root)
    config = hermes_yaml.safe_load((root / "config.yaml").read_text())
    config.update({
        "platform_toolsets": {"cli": ["clarify", "computer_use", "file", "memory", "todo", "web", "nollie_crew"]},
        "approvals": {"mode": "manual", "deny": ["sudo *"]},
        "plugins": {"enabled": ["nollie-crew"]},
        "updates": {"check": False},
    })
    (root / "config.yaml").write_text(hermes_yaml.safe_dump(config, sort_keys=False))
    env = {k: v for k, v in os.environ.items() if k in ("PATH", "LANG", "TMPDIR", "PYTHONPATH", "HOME")}
    env.update(HERMES_HOME=str(root), NO_COLOR="1", TERM="dumb", PYTHONUNBUFFERED="1",
               HERMES_STATE_DB_GUARD_BYPASS="1")
    install = subprocess.run([sys.executable, str(ADDON / "install.py"), "--apply"], env=env,
                             capture_output=True, text=True, timeout=60)
    seen["install"] = install.returncode
    first = run_chat("Please add a crew member to check new roles each morning.", env)
    seen["first_exit"] = first.returncode
    seen["first_done"] = DONE in first.stdout
    seen["offered"] = sorted(n for n in set().union(*(offered(b) for b in server.main_requests())) if str(n).startswith("crew_") or n == "tool_call")
    results = [m.get("content") for b in server.main_requests() for m in tool_results(b)]
    seen["add_result"] = next((payload(r) for r in results if payload(r).get("status") == "added"), None)
    seen["profile_after_add"] = (root / "profiles" / "rover" / "config.yaml").exists()
    second = run_chat("Yes, please retire Rover now.", env)
    seen["second_exit"] = second.returncode
    seen["retire_results"] = [payload(m.get("content")).get("status") for m in tool_results(server.main_requests()[-1])]
    seen["profile_after_retire"] = (root / "profiles" / "rover").exists()
    seen["archives"] = len(list((root / "nollie-crew" / "archives").glob("rover-*.tar.gz")))
    # Without a person to answer, Hermes's approval prompt fails closed and nothing is created.
    third = run_chat("Add someone who can use the Mac to tidy the desktop.", env)
    seen["third_exit"] = third.returncode
    seen["mac_results"] = [m.get("content") for m in tool_results(server.main_requests()[-1])]
    seen["mac_profile"] = (root / "profiles" / "pixel").exists()
    if not seen["first_done"] or seen["second_exit"] or seen["third_exit"]:
        seen["stderr"] = (first.stderr + second.stderr + third.stderr)[-3000:]
print(json.dumps(seen, default=str))
