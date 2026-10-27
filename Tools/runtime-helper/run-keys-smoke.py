"""Run Hermes's real credential resolution with Nollie's Keychain source, offline.

    python3 Tools/runtime-helper/run-keys-smoke.py --python <env>/bin/python --source <pinned-hermes-source>

The pinned source is imported read-only in a disposable home with every network connection
blocked. It checks that the launch bot's keys reach the process environment, that every other
bot gets only its own keys in its own scope, that a fresh bot gets none, that a later .env edit
wins, that a copied bot gets the keys it took along, and that messaging tokens stay behind on a
copy. Values are obvious fakes and only pass/fail is printed. No service is started or changed.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ENTRY = Path(__file__).resolve().parents[2] / "Services/Runtime/runtime_entry.py"

CHILD = r'''
import json, os, runpy, socket, sys
from pathlib import Path

def refuse(*args, **kwargs):
    raise OSError("network blocked in the smoke test")
socket.socket.connect = refuse
socket.create_connection = refuse

source, entry, home = sys.argv[1], sys.argv[2], Path(sys.argv[3])
sys.path.insert(0, source)
ns = runpy.run_path(entry, run_name="nollie_keys_smoke")
keys = {"default": {"OPENROUTER_API_KEY": "fake-default", "TELEGRAM_BOT_TOKEN": "fake-telegram"},
        "scout": {"GROQ_API_KEY": "fake-scout", "OPENROUTER_API_KEY": "fake-scout-router"}}
ns["_install_keychain_source"](source, keys)

from hermes_cli.env_loader import hydrate_profile_secret_sources, load_hermes_dotenv
from agent.secret_scope import build_profile_secret_scope, get_secret, reset_secret_scope, set_secret_scope
load_hermes_dotenv()
checks = {}
checks["launch bot's keys are in its environment"] = os.environ.get("OPENROUTER_API_KEY") == "fake-default"
checks["no other bot's key is in the environment"] = "GROQ_API_KEY" not in os.environ and "fake-scout-router" not in os.environ.values()
checks["the key pipe variable is gone"] = "NOLLIE_KEYS_FD" not in os.environ

scout = home / "profiles" / "scout"
hydrate_profile_secret_sources(scout)
scope = build_profile_secret_scope(scout)
checks["a bot's scope has its own keys"] = scope.get("GROQ_API_KEY") == "fake-scout" and scope.get("OPENROUTER_API_KEY") == "fake-scout-router"
checks["a bot's scope has nothing of the launch bot"] = "TELEGRAM_BOT_TOKEN" not in scope

from tui_gateway.launch_profile_policy import activate_multi_profile_hosting, launch_secret_scope
activate_multi_profile_hosting()
launch = launch_secret_scope(home)
checks["launch scope keeps its keys once hosting many bots"] = launch.get("OPENROUTER_API_KEY") == "fake-default" and "GROQ_API_KEY" not in launch
token = set_secret_scope(build_profile_secret_scope(scout), profile_home=str(scout))
try:
    checks["get_secret inside a bot's scope"] = get_secret("GROQ_API_KEY") == "fake-scout" and get_secret("TELEGRAM_BOT_TOKEN") is None
finally:
    reset_secret_scope(token)

fresh = home / "profiles" / "fresh"
fresh.mkdir()
(fresh / "config.yaml").write_text("model: {}\n")
hydrate_profile_secret_sources(fresh)
checks["a new bot gets no keys"] = not any(v.startswith("fake-") for v in build_profile_secret_scope(fresh).values())

(scout / ".env").write_text("GROQ_API_KEY=fake-newer\n")
checks["a later .env edit wins"] = build_profile_secret_scope(scout).get("GROQ_API_KEY") == "fake-newer"
(scout / ".env").write_text("GROQ_API_KEY=\n")
checks["an emptied key stays cleared"] = not build_profile_secret_scope(scout).get("GROQ_API_KEY")

staging = home / "profiles" / ".copy.staging-1"
staging.mkdir()
ns["_note_cloned_keys"](keys, home)(staging, "default", False)
note = json.loads((staging / ".nollie-keys-from").read_text())
checks["a copy takes provider keys, not messaging tokens"] = note == {"version": 1, "from": "default", "names": ["OPENROUTER_API_KEY"]}
copy = home / "profiles" / "copy"
staging.rename(copy)
(copy / "config.yaml").write_text("model: {}\n")
hydrate_profile_secret_sources(copy)
copied = build_profile_secret_scope(copy)
checks["a copied bot gets the keys it took along"] = copied.get("OPENROUTER_API_KEY") == "fake-default" and "TELEGRAM_BOT_TOKEN" not in copied

from tools.skills_tool_setup import _is_env_var_persisted
token = set_secret_scope(launch_secret_scope(home), profile_home=str(home))
try:
    checks["a skill sees the launch bot's key as set"] = _is_env_var_persisted("OPENROUTER_API_KEY", {})
finally:
    reset_secret_scope(token)
print(json.dumps(checks))
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--python", required=True)
    parser.add_argument("--source", required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="nollie-keys-smoke-") as folder:
        root = Path(folder)
        home = root / "home"
        (home / "profiles" / "scout").mkdir(parents=True)
        (root / "user").mkdir()
        (home / "config.yaml").write_text("model: {}\n")
        (home / ".env").write_text("# no keys here\nHERMES_MAX_ITERATIONS=40\n")
        (home / "profiles" / "scout" / "config.yaml").write_text("model: {}\n")
        (home / "profiles" / "scout" / ".env").write_text("SETTING=1\n")
        environment = {"HERMES_HOME": str(home), "HOME": str(root / "user"), "PATH": "/usr/bin:/bin",
                       "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": str(root)}
        result = subprocess.run([args.python, "-I", "-B", "-c", CHILD, str(Path(args.source).resolve()), str(ENTRY), str(home)],
                                env=environment, cwd=root, capture_output=True, text=True, timeout=300)
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    if result.returncode != 0 or not lines:
        # Only the last line of the failure; no value is ever printed by the child.
        print(json.dumps({"passed": False, "exit": result.returncode,
                          "error": (result.stderr.strip().splitlines() or ["(none)"])[-1][:300]}, indent=2))
        sys.exit(1)
    checks = json.loads(lines[-1])
    print(json.dumps({"passed": all(checks.values()), "checks": checks}, indent=2))
    sys.exit(0 if all(checks.values()) else 1)


if __name__ == "__main__":
    main()
