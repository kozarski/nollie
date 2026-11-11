#!/usr/bin/env python3
"""Rehearse the managed Mac setup with the current pins, in a throwaway folder.

    python3 -I Tools/dev/managed-setup-dry-run.py --folder <empty scratch folder> [--smoke]

It follows NativeDependencyInstaller step by step, with the same isolated environment:
download uv and Hermes from Tools/pins.json (size and SHA-256 checked before use), apply the
Hermes overlay exactly as the app does (each original checked first), let the pinned uv install
the pinned Python, sync Hermes's frozen lockfile (wheels only), build the Setup Kit and run its
add-on installer. --smoke then starts the API and gateway roles through runtime_entry.py the way
Nollie Runtime does: the same RuntimeSpawn code called from a Swift actor, the service's environment
and a stand-in for Papertrail's door. It checks the API's identity and the add-ons' routes, installs
the local model engine through Hermes's own route (the step that once hung for ever), and stops both.

It never registers a launch agent, never reads or writes ~/.hermes, and refuses a folder inside
it or inside Nollie's real setups. A report with sizes and times goes to <folder>/report.json.
Set HTTPS_PROXY if this Mac's network needs one for uv.
"""
import argparse
import base64
import hmac
import importlib.util
import json
import os
from pathlib import Path
import pwd
import secrets
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
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


# Nollie Runtime's launch, as a small program: RuntimeSpawn.swift itself, called from an actor as the
# service calls it, so the child starts from a Swift concurrency thread (which blocks SIGCHLD and SIGTERM).
LAUNCHER_MAIN = r"""
import Darwin
import Foundation

actor Launcher {
    func start(_ a: [String]) -> (pid_t?, Bool) {
        var mask = sigset_t()
        pthread_sigmask(SIG_BLOCK, nil, &mask)
        let pid = RuntimeSpawn.start(executable: a[4], arguments: Array(a.dropFirst(5)),
                                     environment: ProcessInfo.processInfo.environment, directory: a[3],
                                     output: Int32(a[0])!, owner: Int32(a[1])!, keys: Int32(a[2])!)
        return (pid, sigismember(&mask, SIGCHLD) == 1)
    }
}

@main struct Main {
    static func main() async {
        let a = Array(CommandLine.arguments.dropFirst())
        let (started, blocked) = await Launcher().start(a)
        guard let pid = started else { print("failed"); exit(70) }
        print("pid \(pid) starting-thread-blocks-sigchld \(blocked)")
        fflush(stdout)
        for fd in a.prefix(3) { close(Int32(fd)!) }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        exit((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
    }
}
"""


def build_launcher(folder):
    source = folder / "launcher"
    source.mkdir(exist_ok=True)
    (source / "main.swift").write_text(LAUNCHER_MAIN)
    binary = source / "hermes-launcher"
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", str(ROOT / "Services/Runtime/RuntimeSpawn.swift"),
                    str(source / "main.swift"), "-o", str(binary)], check=True, capture_output=True, timeout=600)
    return binary


class StandInDoor(threading.Thread):
    """Papertrail's door as Hermes sees it: a proxy on loopback that wants this run's secret. It notes each
    connection's label and host in door.log and passes the bytes through."""

    def __init__(self, secret, log):
        super().__init__(daemon=True)
        self.secret, self.log, self.lock = secret, log, threading.Lock()
        self.listener = socket.create_server(("127.0.0.1", 0))
        self.port = self.listener.getsockname()[1]

    def run(self):
        while True:
            try:
                client, _ = self.listener.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(client,), daemon=True).start()

    def note(self, line):
        with self.lock, open(self.log, "a") as handle:
            handle.write(line + "\n")

    def serve(self, client):
        upstream = None
        try:
            data = b""
            while b"\r\n\r\n" not in data and len(data) < 65536:
                chunk = client.recv(4096)
                if not chunk:
                    return
                data += chunk
            head, rest = data.split(b"\r\n\r\n", 1)
            lines = head.decode("latin-1").split("\r\n")
            method, target, _ = lines[0].split(" ", 2)
            auth = next((line.split(":", 1)[1].strip() for line in lines[1:] if line.lower().startswith("proxy-authorization:")), "")
            user, _, password = base64.b64decode(auth[6:]).decode().partition(":") if auth.startswith("Basic ") else ("", "", "")
            if not hmac.compare_digest(password, self.secret):
                self.note(f"refused {method}")
                client.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n")
                return
            if method == "CONNECT":
                host, port = target.rsplit(":", 1)
                upstream = socket.create_connection((host, int(port)), timeout=15)
                client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            else:
                parts = urllib.parse.urlsplit(target)
                host = parts.hostname or ""
                upstream = socket.create_connection((host, parts.port or 80), timeout=15)
                kept = [line for line in lines[1:] if not line.lower().startswith("proxy-")]
                path = (parts.path or "/") + ("?" + parts.query if parts.query else "")
                upstream.sendall(f"{method} {path} HTTP/1.1\r\n".encode() + "\r\n".join(kept).encode() + b"\r\n\r\n")
            self.note(f"{user.rsplit('.', 1)[-1]} {host}")
            if rest:
                upstream.sendall(rest)
            upstream.settimeout(None)
            while True:
                ready, _, _ = select.select([client, upstream], [], [], 900)
                if not ready:
                    return
                for end in ready:
                    chunk = end.recv(65536)
                    if not chunk:
                        return
                    (upstream if end is client else client).sendall(chunk)
        except (OSError, ValueError):
            return
        finally:
            client.close()
            if upstream is not None:
                upstream.close()


def service_environment(installation, role, token, door, service):
    """RuntimeContract.Plan.environment(for:token:) over NativeSetupPlan.environment, with the door's variables."""
    i = Path(installation)
    env = {**environment(i), "HERMES_RUNTIME_DIR": str(i / "runtime/store"), "HERMES_INSTALL_ROOT": str(i / "hermes"),
           "HERMES_DISABLE_LAZY_INSTALLS": "1", "PYTHONPATH": str(i / "hermes"),
           "PATH": str(i / "environment/bin") + ":/usr/bin:/bin:/usr/sbin:/sbin", "PYTHONUNBUFFERED": "1",
           "NOLLIE_OWNER_FD": "3", "NOLLIE_KEYS_FD": "4",
           "NOLLIE_EXIT_RELAY": str(service / "exit-relay.json"), "NOLLIE_NETWORK_FILTER": str(service / "network-filter.json")}
    env.pop("HTTPS_PROXY", None)
    url = f"http://unplaced.program:{door.secret}@127.0.0.1:{door.port}"
    for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"):
        env[name] = env[name.lower()] = url
    env["NO_PROXY"] = env["no_proxy"] = "localhost,127.0.0.1,::1"
    env["NODE_USE_ENV_PROXY"] = "1"
    if role == "api":
        env["HERMES_DASHBOARD_SESSION_TOKEN"] = token
    return env


def drain(descriptor, log):
    """Hermes's stdout, read as the service reads it, kept here for the rehearsal."""
    with open(log, "ab") as handle:
        while chunk := os.read(descriptor, 4096):
            handle.write(chunk)
            handle.flush()
    os.close(descriptor)


def smoke(installation, report):
    """Start both roles as Nollie Runtime would, check them, stop them."""
    i = Path(installation)
    token = secrets.token_hex(32)
    entry = ROOT / "Services/Runtime/runtime_entry.py"
    (i / "runtime/store").mkdir(parents=True, exist_ok=True)
    service = i.parent / "service"
    service.mkdir(exist_ok=True)
    launcher = build_launcher(i.parent)
    door = StandInDoor(secrets.token_hex(32), i.parent / "door.log")
    door.start()
    children = {}
    try:
        # A fake key for the main bot, as Nollie Runtime hands keys over from the Keychain.
        keys = json.dumps({"version": 1, "profiles": {"default": {"OPENROUTER_API_KEY": "fake-dry-run-key"}}}).encode()
        for role in ("api", "gateway"):
            output_read, output_write = os.pipe()
            owner_read, owner_write = os.pipe()
            keys_read, keys_write = os.pipe()
            (i / f"smoke-{role}.log").write_bytes(b"")
            process = subprocess.Popen([str(launcher), str(output_write), str(owner_read), str(keys_read), str(i / "hermes"),
                                        str(i / "environment/bin/python"), "-I", "-B", str(entry), "--source", str(i / "hermes"),
                                        "--role", role], env=service_environment(i, role, token, door, service),
                                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, text=True,
                                       pass_fds=(output_write, owner_read, keys_read))
            for descriptor in (output_write, owner_read, keys_read):
                os.close(descriptor)
            with os.fdopen(keys_write, "wb") as handle:
                handle.write(keys)
            started = process.stdout.readline().split()
            threading.Thread(target=drain, args=(output_read, i / f"smoke-{role}.log"), daemon=True).start()
            if len(started) != 4 or started[0] != "pid":
                report["smoke"] = {role: "the launcher could not start it"}
                return False
            report.setdefault("launch", {})[role] = {"starting_thread_blocks_sigchld": started[3] == "true"}
            children[role] = (process, owner_write, int(started[1]))
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
        # A helper bot: made through Hermes's own route (so Ask first goes on before it is served), then
        # the add-ons' routes for it. From Hermes 0.23 a helper's add-on routes run in its own plugin host.
        def post(path, body):
            request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=json.dumps(body).encode(), method="POST",
                                             headers={"X-Hermes-Session-Token": token, "Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    return response.status
            except urllib.error.HTTPError as error:
                return error.code
        helper = {"create": post("/api/profiles", {"name": "rover", "description": "A dry-run helper."})}
        # Nollie's computer add-on looks after each helper from the main bot, so it is told the bot as `bot`.
        for path in ("/api/plugins/nollie-computer/ask-first?bot=rover",
                     "/api/plugins/nollie-computer/own-computer?bot=rover"):
            helper[path] = get(path)[0]
        helper["ask_first_on_disk"] = (i / "home/profiles/rover/plugins/nollie-workflow").is_dir()
        _, options = get("/api/model/options?profile=default")
        # A fresh setup lists OpenRouter only once Hermes holds a key for it.
        signed_in = [p.get("slug") for p in (options or {}).get("providers", []) if isinstance(p, dict) and p.get("authenticated")]
        engine = install_engine(port, token, get)
        time.sleep(10)  # Let the gateway load its plugins and settle.
        gateway_alive = children["gateway"][0].poll() is None
        # Hermes's stderr goes nowhere, as under the service; its own log file and stdout remain.
        gateway_log = "".join(path.read_text(errors="replace") for path in (i / "smoke-gateway.log", i / "home/logs/gateway.log")
                              if path.exists())
        plugin_errors = [line for line in gateway_log.splitlines()
                         if "nollie" in line.lower() and any(word in line.lower() for word in ("error", "traceback", "failed"))]
        report["smoke"] = {"api_identity": status == 200 and bool(identity and identity.get("ok")),
                           "routes": routes, "helper": helper, "gateway_running_after_10s": gateway_alive,
                           "key_from_pipe_reaches_hermes": "openrouter" in signed_in,
                           "no_key_in_files": "fake-dry-run-key" not in (i / "home/.env").read_text(errors="replace")
                           if (i / "home/.env").exists() else True,
                           "gateway_plugin_errors": plugin_errors[:10], "engine": engine,
                           "door_hosts": sorted(set(line.split()[-1] for line in (i.parent / "door.log").read_text().splitlines()
                                                    if not line.startswith("refused")))
                           if (i.parent / "door.log").exists() else []}
        return (report["smoke"]["api_identity"] and gateway_alive and not plugin_errors and engine["status"] == "done"
                and helper["create"] == 200 and helper["ask_first_on_disk"]
                and all(code == 200 for path, code in helper.items() if path.startswith("/api/"))
                and report["smoke"]["key_from_pipe_reaches_hermes"] and report["smoke"]["no_key_in_files"])
    finally:
        stops = report.setdefault("stop_seconds", {})
        for role, (process, owner_write, pid) in children.items():
            # NativeRuntimeBackend.stop: close the owner pipe, SIGTERM the group, SIGKILL it after five seconds.
            began = time.time()
            os.close(owner_write)
            signal_group(pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                signal_group(pid, signal.SIGKILL)
                process.wait(timeout=20)
            signal_group(pid, signal.SIGKILL)
            stops[role] = round(time.time() - began, 1)
        door.listener.close()


def signal_group(pid, number):
    try:
        os.killpg(pid, number)
    except OSError:
        pass


def install_engine(port, token, get, timeout=900):
    """The local model engine, installed through Hermes's own route. Its installer runs uv, which under
    Nollie Runtime once waited for ever: the launch handed it a mask that blocked SIGCHLD."""
    request = urllib.request.Request(f"http://127.0.0.1:{port}/api/local-models/runtime/install", data=b"{}", method="POST",
                                     headers={"X-Hermes-Session-Token": token, "Content-Type": "application/json"})
    began = time.time()
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            job = json.loads(response.read())["job_id"]
    except (urllib.error.URLError, KeyError, ValueError) as error:
        return {"status": f"not started: {error}"}
    seen = {"status": "running"}
    while time.time() - began < timeout:
        code, state = get(f"/api/local-models/jobs/{job}")
        if code == 200 and state:
            seen = {key: state.get(key) for key in ("status", "phase", "detail", "error")}
            if state.get("status") in ("done", "error"):
                break
        time.sleep(1)
    seen["seconds"] = round(time.time() - began, 1)
    return seen


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--folder", type=Path, required=True)
    parser.add_argument("--smoke", action="store_true", help="also start and stop both runtime roles")
    parser.add_argument("--seed", type=Path, help="a folder of already downloaded artifacts to reuse (each is still checked)")
    parser.add_argument("--home-from", type=Path, help="an older rehearsal's installation whose home (bots, chats, settings) "
                        "this one takes over, as a Mac does when Nollie moves it to a newer Hermes")
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

    if args.home_from:
        def carry_home():
            old = next(p for p in args.home_from.iterdir() if (p / "home").is_dir()) / "home"
            shutil.rmtree(installation / "home")
            shutil.copytree(old, installation / "home", symlinks=True)
            profiles = installation / "home/profiles"
            bots = sorted(p.name for p in profiles.iterdir()) if profiles.is_dir() else []
            return f"home from {old.parent.name}: main bot" + "".join(", " + name for name in bots)
        step("home", carry_home)

    def addons():
        kit = installation / "Setup Kit"
        setup_kit.build(kit)
        output = run([installation / "environment/bin/python", "-I", "-B", kit / "add-ons/managed_addons.py", "--kit", kit / "add-ons",
                      "--installation", installation, "--uv", installation / "uv/uv", "--python", python_path], installation, 900)
        again = run([installation / "environment/bin/python", "-I", "-B", kit / "add-ons/managed_addons.py", "--kit", kit / "add-ons",
                     "--installation", installation, "--uv", installation / "uv/uv", "--python", python_path], installation, 900)
        # What the Mac app does next (NativeDependencyInstaller.addOnsRecords): every carried file must sit in
        # the home exactly as the kit lists it, and the reader's marker must be the lock's checksum and a newline.
        import hashlib
        listed = json.loads((kit / "add-ons/kit.json").read_text())
        expected = {"plugins/" + f["path"]: (f["bytes"], f["sha256"]) for item in listed["items"] for f in item["files"]}
        marker = (listed["readerLock"]["sha256"] + "\n").encode()
        expected["nollie-reader/venv/nollie-lock.sha256"] = (len(marker), hashlib.sha256(marker).hexdigest())
        for path, (size, digest) in expected.items():
            data = (installation / "home" / path).read_bytes()
            if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
                sys.exit(f"The app would refuse this setup: {path} is not as the kit lists it.")
        return {"first": output.strip().splitlines(), "second": again.strip().splitlines(), "receipt_files": len(expected)}
    step("addons", addons)
    report["seconds_total"] = round(time.time() - started, 1)
    report["bytes_on_disk"] = {name: du(installation / name) for name in
                               ("downloads", "uv", "python", "hermes", "environment", "cache", "home")}
    report["bytes_on_disk"]["total"] = du(installation)
    ok = True
    if args.smoke:
        ok = smoke(installation, report)
        print("smoke: " + json.dumps({key: report.get(key) for key in ("launch", "smoke", "stop_seconds")}))
    # Every home and cache the steps saw was inside the throwaway installation.
    report["isolated"] = all(value.startswith(str(installation)) for key, value in environment(installation).items()
                             if key in ("HOME", "HERMES_HOME", "UV_CACHE_DIR", "UV_PYTHON_INSTALL_DIR", "TMPDIR"))
    (folder / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Report: {folder / 'report.json'}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
