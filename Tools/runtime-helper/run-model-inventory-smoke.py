"""Exercise pinned model inventory with no network and a disposable empty Hermes home."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--python", type=Path, required=True)
parser.add_argument("--source", type=Path, required=True)
args = parser.parse_args()
source, python = args.source.resolve(strict=True), args.python.absolute()
if not python.is_file():
    raise SystemExit("Fixture Python is unavailable.")
entry = ROOT / "Services/Runtime/runtime_entry.py"

child = r'''
import json, runpy, socket, sys, threading, time, urllib.request
sys.path.insert(0, SOURCE)
import requests
attempts = []
def offline(*args, **kwargs):
    attempts.append(threading.current_thread().name)
    raise OSError("offline fixture")
requests.sessions.Session.request = offline
urllib.request.urlopen = offline
socket.getaddrinfo = offline
if PATCHED:
    runpy.run_path(ENTRY)["_install_model_inventory_compatibility"](SOURCE)
    from hermes_cli.web_routers import local_models
    route = next(r for r in local_models.router.routes if r.path == "/api/nollie/local-model/reply-check")
    assert route.methods == {"POST"}
    assert [field.name for field in route.dependant.query_params] == ["profile"]
    assert not route.dependant.body_params
from hermes_cli.inventory import ConfigContext, build_model_options_payload
started = time.monotonic()
empty = build_model_options_payload(ConfigContext("", "", "", {}, [], []))
saved = build_model_options_payload(
    ConfigContext("anthropic", "fixture-saved-model", "", {}, [], []), explicit_only=True)
assert empty["model"] == "" and empty["provider"] == "" and empty["providers"] == []
assert saved["model"] == "fixture-saved-model" and saved["provider"] == "anthropic"
assert not any(row.get("authenticated") is True for row in saved["providers"])
foreground = sum(name == "MainThread" for name in attempts)
assert (foreground == 0) if PATCHED else (foreground > 0)
print("RESULT " + json.dumps({"patched": PATCHED, "elapsed_seconds": round(time.monotonic()-started, 3),
    "foreground_network_attempts": foreground, "local_probe_registered": PATCHED, "empty_model_unconfigured": True,
    "saved_model_preserved": True, "missing_auth_not_ready": True}), flush=True)
'''
results = []
for patched in (False, True):
    with tempfile.TemporaryDirectory(prefix="nollie-model-inventory-") as temporary:
        root = Path(temporary)
        for name in ("home", "user", "runtime", "cache", "config", "data", "tmp"):
            (root / name).mkdir()
        environment = {
            "HOME": str(root / "user"), "HERMES_HOME": str(root / "home"),
            "HERMES_RUNTIME_DIR": str(root / "runtime"), "HERMES_INSTALL_ROOT": str(source),
            "PATH": f"{python.parent}:/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
            "NO_COLOR": "1", "PYTHONDONTWRITEBYTECODE": "1", "HERMES_DISABLE_LAZY_INSTALLS": "1",
            "XDG_CACHE_HOME": str(root / "cache"), "XDG_CONFIG_HOME": str(root / "config"),
            "XDG_DATA_HOME": str(root / "data"), "TMPDIR": str(root / "tmp"),
        }
        program = f"SOURCE={str(source)!r}\nENTRY={str(entry)!r}\nPATCHED={patched!r}\n" + child
        process = subprocess.run([str(python), "-I", "-B", "-c", program], env=environment,
                                 capture_output=True, text=True, timeout=20)
        # Never relay imported package output. Only the fixture's bounded result is public.
        lines = [line[7:] for line in process.stdout.splitlines() if line.startswith("RESULT ")]
        if process.returncode or len(lines) != 1:
            raise SystemExit(f"Inventory fixture failed (exit {process.returncode}); no process output retained.")
        results.append(json.loads(lines[0]))
output = ROOT / "build/nollie-runtime-supervisor/model-inventory-smoke.json"
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps({"scope": "Pinned code, disposable empty homes, all network blocked.",
                              "results": results}, indent=2) + "\n")
print(output.read_text())
