#!/usr/bin/env python3
"""Rehearse the managed Mac setup with the current pins, in a throwaway folder.

    python3 -I Tools/dev/managed-setup-dry-run.py --folder <empty scratch folder> [--smoke]

It follows NativeDependencyInstaller step by step, with the same isolated environment:
download uv and Hermes from Tools/pins.json (size and SHA-256 checked before use), apply the
Hermes overlay exactly as the app does (each original checked first), let the pinned uv install
the pinned Python, sync Hermes's frozen lockfile (wheels only), build the Setup Kit and run its
add-on installer. --smoke then starts the API and gateway roles through runtime_entry.py, the
way Nollie Runtime does, checks the API's identity and the add-ons' routes, and stops both.

It never registers a launch agent, never reads or writes ~/.hermes, and refuses a folder inside
it or inside Nollie's real setups. A report with sizes and times goes to <folder>/report.json.
Set HTTPS_PROXY if this Mac's network needs one for uv.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import pwd
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def sibling(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pinslib = sibling("pinslib", "pinslib.py")
setup_kit = sibling("setup_kit", "setup-kit.py")
REAL_HOME = Path(pwd.getpwuid(os.getuid()).pw_dir)
FORBIDDEN = [REAL_HOME / ".hermes", REAL_HOME / "Library/Application Support/Nollie"]


def environment(installation):
    """NativeSetupPlan.environment, the same keys and values."""
    i = Path(installation)
    values = {"HOME": str(i / "user"), "HERMES_HOME": str(i / "home"), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
              "LANG": "en_US.UTF-8", "NO_COLOR": "1", "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
              "UV_PYTHON_INSTALL_DIR": str(i / "python"), "UV_PYTHON_BIN_DIR": str(i / "bin"),
              "UV_CACHE_DIR": str(i / "cache/uv"), "UV_PROJECT_ENVIRONMENT": str(i / "environment"),
              "UV_NO_CONFIG": "1", "UV_NO_MODIFY_PATH": "1", "UV_PYTHON_DOWNLOADS": "manual",
              "XDG_CACHE_HOME": str(i / "cache"), "XDG_CONFIG_HOME": str(i / "user/config"),
              "XDG_DATA_HOME": str(i / "user/data"), "TMPDIR": str(i / "temporary")}
    if os.environ.get("HTTPS_PROXY"):
        values["HTTPS_PROXY"] = os.environ["HTTPS_PROXY"]
    return values


def run(command, installation, timeout, **extra):
    result = subprocess.run([str(part) for part in command], cwd=installation, env={**environment(installation), **extra},
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        sys.exit(f"Step failed ({result.returncode}): {' '.join(map(str, command[:4]))}\n{result.stdout[-3000:]}{result.stderr[-3000:]}")
    return result.stdout


def apply_overlay(staging):
    """The app's NativeSetupKit.Overlay.apply, in Python."""
    manifest = pinslib.overlay_manifest()
    for entry in manifest["files"]:
        data = (pinslib.OVERLAY / "files" / entry["path"]).read_bytes()
        assert len(data) == entry["bytes"] and pinslib.sha256_bytes(data) == entry["after"], entry["path"]
        target = Path(staging) / entry["path"]
        if entry["before"] is None:
            assert not target.exists(), f"{entry['path']} already exists in the pinned source"
        else:
            assert pinslib.sha256_file(target) == entry["before"], f"{entry['path']} differs from the reviewed original"
        target.write_bytes(data)
    return len(manifest["files"])


def du(path):
    total = 0
    for item in Path(path).rglob("*"):
        if item.is_file() and not item.is_symlink():
            total += item.stat().st_size
    return total


def smoke(installation, report):
    """Start both roles as Nollie Runtime would, check them, stop them."""
    i = Path(installation)
    token = secrets.token_hex(32)
    entry = ROOT / "Services/Runtime/runtime_entry.py"
    (i / "runtime/store").mkdir(parents=True, exist_ok=True)
    children, logs = {}, {}
    try:
        # A fake key for the main bot, as Nollie Runtime hands keys over from the Keychain.
        keys = json.dumps({"version": 1, "profiles": {"default": {"OPENROUTER_API_KEY": "fake-dry-run-key"}}}).encode()
        for role in ("api", "gateway"):
            read_end, write_end = os.pipe()
            keys_read, keys_write = os.pipe()
            env = {**environment(i), "HERMES_RUNTIME_DIR": str(i / "runtime/store"), "HERMES_INSTALL_ROOT": str(i / "hermes"),
                   "HERMES_DISABLE_LAZY_INSTALLS": "1", "PYTHONPATH": str(i / "hermes"),
                   "PATH": str(i / "environment/bin") + ":/usr/bin:/bin:/usr/sbin:/sbin", "PYTHONUNBUFFERED": "1",
                   "NOLLIE_OWNER_FD": str(read_end), "NOLLIE_KEYS_FD": str(keys_read)}
            env.pop("HTTPS_PROXY", None)
            if role == "api":
                env["HERMES_DASHBOARD_SESSION_TOKEN"] = token
            logs[role] = open(i / f"smoke-{role}.log", "w")
            process = subprocess.Popen([str(i / "environment/bin/python"), "-I", "-B", str(entry), "--source", str(i / "hermes"),
                                        "--role", role], cwd=i / "hermes", env=env, stdin=subprocess.DEVNULL, stdout=logs[role],
                                       stderr=subprocess.STDOUT, pass_fds=(read_end, keys_read))
            os.close(read_end)
            os.close(keys_read)
            with os.fdopen(keys_write, "wb") as handle:
                handle.write(keys)
            children[role] = (process, write_end)
        port = None
        deadline = time.time() + 90
        while time.time() < deadline and port is None:
            text = (i / "smoke-api.log").read_text(errors="replace")
            for line in text.splitlines():
                if line.startswith("HERMES_BACKEND_READY port="):
                    port = int(line.split("=", 1)[1])
            if children["api"][0].poll() is not None:
                break
            time.sleep(0.5)
        if port is None:
            report["smoke"] = {"api": "did not report ready"}
            return False

        def get(path):
            request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", headers={"X-Hermes-Session-Token": token})
            try:
                with urllib.request.urlopen(request, timeout=20) as response:
                    return response.status, json.loads(response.read() or b"null")
            except urllib.error.HTTPError as error:
                return error.code, None

        status, identity = get("/api/host/identity")
        routes = {path: get(path)[0] for path in ("/api/plugins/nollie-workflow/attention",
                                                  "/api/plugins/nollie-workflow/private-bots",
                                                  "/api/plugins/nollie-workflow/papertrail?days=1",
                                                  "/api/plugins/nollie-crew/crew")}
        _, options = get("/api/model/options?profile=default")
        # A fresh setup lists OpenRouter only once Hermes holds a key for it.
        signed_in = [p.get("slug") for p in (options or {}).get("providers", []) if isinstance(p, dict) and p.get("authenticated")]
        time.sleep(10)  # Let the gateway load its plugins and settle.
        gateway_alive = children["gateway"][0].poll() is None
        gateway_log = (i / "smoke-gateway.log").read_text(errors="replace")
        plugin_errors = [line for line in gateway_log.splitlines()
                         if "nollie" in line.lower() and any(word in line.lower() for word in ("error", "traceback", "failed"))]
        report["smoke"] = {"api_identity": status == 200 and bool(identity and identity.get("ok")),
                           "routes": routes, "gateway_running_after_10s": gateway_alive,
                           "key_from_pipe_reaches_hermes": "openrouter" in signed_in,
                           "no_key_in_files": "fake-dry-run-key" not in (i / "home/.env").read_text(errors="replace")
                           if (i / "home/.env").exists() else True,
                           "gateway_plugin_errors": plugin_errors[:10]}
        return (report["smoke"]["api_identity"] and gateway_alive and not plugin_errors
                and report["smoke"]["key_from_pipe_reaches_hermes"] and report["smoke"]["no_key_in_files"])
    finally:
        for role, (process, write_end) in children.items():
            os.close(write_end)  # Closing the owner pipe is how Nollie Runtime stops a role.
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
            logs[role].close()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--folder", type=Path, required=True)
    parser.add_argument("--smoke", action="store_true", help="also start and stop both runtime roles")
    parser.add_argument("--seed", type=Path, help="a folder of already downloaded artifacts to reuse (each is still checked)")
    args = parser.parse_args()
    folder = args.folder.resolve()
    for forbidden in FORBIDDEN:
        if folder == forbidden.resolve() or forbidden.resolve() in folder.parents:
            sys.exit(f"Refusing {folder}: it is inside {forbidden}.")
    folder.mkdir(parents=True, exist_ok=True)
    pins = pinslib.load()
    uv, hermes, python = (pinslib.component(pins, name) for name in ("uv", "hermes", "python"))
    installation = folder / str(uuid.uuid4()).upper()
    installation.mkdir(mode=0o700)
    for name in ("downloads", "receipts", "user", "home", "bin", "cache", "temporary"):
        (installation / name).mkdir(mode=0o700)
    starter = json.loads((ROOT / "Apps/Nollie/Resources/nollie-starter.json").read_text())
    (installation / "home/config.yaml").write_text(json.dumps(starter["config"], indent=2))
    report = {"installation": str(installation), "pins": {c["id"]: c["version"] for c in pins["components"]}, "steps": {}}
    started = time.time()

    def step(name, action):
        began = time.time()
        result = action()
        report["steps"][name] = {"seconds": round(time.time() - began, 1), "result": result}
        print(f"{name}: {result} ({report['steps'][name]['seconds']}s)", flush=True)

    def download(component, filename):
        target = installation / "downloads" / filename
        seeded = args.seed / filename if args.seed else None
        if seeded and seeded.is_file():
            shutil.copyfile(seeded, target)
        pinslib.fetch(component["artifact"], target)
        return f"{component['artifact']['bytes']} bytes, SHA-256 verified"

    step("uv download", lambda: download(uv, "uv.tar.gz"))
    step("uv unpack", lambda: str(pinslib.safe_extract(installation / "downloads/uv.tar.gz", installation / "uv").name))
    step("uv version", lambda: run([installation / "uv/uv", "--version"], installation, 30).strip())
    step("hermes download", lambda: download(hermes, "hermes.tar.gz"))

    def unpack_hermes():
        staging = installation / f"staging-{uuid.uuid4()}"
        pinslib.safe_extract(installation / "downloads/hermes.tar.gz", staging)
        count = apply_overlay(staging)
        staging.rename(installation / "hermes")
        return f"unpacked, {count} reviewed files applied"
    step("hermes unpack and overlay", unpack_hermes)
    python_path = installation / "python" / python["key"] / "bin/python3.14"

    def install_python():
        (installation / "python").mkdir(mode=0o700)
        run([installation / "uv/uv", "--no-config", "python", "install", python["key"], "--no-bin"], installation, 600)
        return run([python_path, "-I", "--version"], installation, 15).strip()
    step("python", install_python)
    if report["steps"]["python"]["result"] != "Python " + python["version"]:
        sys.exit("The installed Python does not match the pin.")

    def sync():
        run([installation / "uv/uv", "--no-config", "sync", "--frozen", "--no-default-groups", "--no-install-project", "--no-build",
             "--python", python_path, "--project", installation / "hermes"], installation, 1200)
        run([installation / "environment/bin/python", "-I", "-B", "-c",
             "import fastapi, uvicorn, websockets, openai; from ruamel.yaml import YAML"], installation, 60)
        return "frozen lockfile synced, imports checked"
    step("dependencies", sync)

    def addons():
        kit = installation / "Setup Kit"
        setup_kit.build(kit)
        output = run([installation / "environment/bin/python", "-I", "-B", kit / "add-ons/managed_addons.py", "--kit", kit / "add-ons",
                      "--installation", installation, "--uv", installation / "uv/uv", "--python", python_path], installation, 900)
        again = run([installation / "environment/bin/python", "-I", "-B", kit / "add-ons/managed_addons.py", "--kit", kit / "add-ons",
                     "--installation", installation, "--uv", installation / "uv/uv", "--python", python_path], installation, 900)
        return {"first": output.strip().splitlines(), "second": again.strip().splitlines()}
    step("addons", addons)
    report["seconds_total"] = round(time.time() - started, 1)
    report["bytes_on_disk"] = {name: du(installation / name) for name in
                               ("downloads", "uv", "python", "hermes", "environment", "cache", "home")}
    report["bytes_on_disk"]["total"] = du(installation)
    ok = True
    if args.smoke:
        ok = smoke(installation, report)
        print("smoke: " + json.dumps(report["smoke"]))
    # Every home and cache the steps saw was inside the throwaway installation.
    report["isolated"] = all(value.startswith(str(installation)) for key, value in environment(installation).items()
                             if key in ("HOME", "HERMES_HOME", "UV_CACHE_DIR", "UV_PYTHON_INSTALL_DIR", "TMPDIR"))
    (folder / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Report: {folder / 'report.json'}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
