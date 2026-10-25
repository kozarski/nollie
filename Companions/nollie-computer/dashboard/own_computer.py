"""A computer of its own: one switch per helper, backed by a named local Cua Space.

Turning it on, for one profile only: install Cua's MIT Hermes plugin (hermes-cua-spaces, at a
pinned, reviewed commit) into that profile, point the plugin at a Space named
``nollie-<profile>`` (named, so Hermes keeps asking before risky commands and the plugin never
deletes it), create that Space through Cua's own CLI, record it in owned-spaces.json so the
preview finds it, point it at Nollie Runtime's exit relay (used only while the relay answers),
and only then switch the profile's terminal to the plugin.

Turning it off restores the profile's previous terminal and plugin settings exactly, from the
values saved when it was turned on, and leaves the Space alone. Removing the Space is a separate
action. Every change goes through Hermes's own CLI for that profile, after a dated backup of its
config.yaml. A change whose outcome is unknown is never repeated by itself: the next status read
says what happened.

Reads never start anything: they talk to an already running Cua daemon only.
"""
from __future__ import annotations

import datetime
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import subprocess
import threading
import time

PLUGIN_NAME = "cua-spaces"
PLUGIN_URL = "https://github.com/trycua/hermes-cua-spaces"
# v0.2.0 of the MIT plugin. Hermes's scanner rates this exact commit "caution" (17 findings in its
# README, CI workflow and byte-order-mark handling), so the install passes --force for it. A
# "dangerous" verdict is never overridable, and only this commit is ever installed.
PLUGIN_REF = "fcf30603cfe1cc8dca61582cddc9b66f1b018134"
# The plugin needs the cua Python package >=0.5.0,<0.6, which pairs with this CLI.
MIN_CUA = (0, 5, 0)
SETTINGS = "plugins.entries.cua-spaces.settings"
# Each value the switch sets, so turning it off can put back exactly what was there.
MANAGED_KEYS = ("terminal.backend", SETTINGS + ".space", SETTINGS + ".on", SETTINGS + ".image",
                SETTINGS + ".delete_on_exit")
PROFILE_NAME = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")
SPACE_TARGET = re.compile(r"(local|cloud):([A-Za-z0-9][A-Za-z0-9_.-]{0,127})\Z")
STATE_VERSION = 1
CREATE_TIMEOUT = 1800
CLI_TIMEOUT = 120
MAKE_FAILED = "Cua couldn't make its computer. Try again in a moment."
LINUX_BACKENDS = {"managed", "container", "lume", "qemu"}


def space_name(profile):
    return "nollie-" + profile


def parse_version(text):
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", text or "")
    return tuple(int(part) for part in match.groups()) if match else None


def default_run(argv, timeout, env=None):
    """Runs a command with output kept in memory; stderr is dropped so no secret travels on."""
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                              env={**os.environ, "CUA_TELEMETRY": "0", "NO_COLOR": "1", **(env or {})})
        return done.returncode, done.stdout
    except (OSError, subprocess.TimeoutExpired):
        return None, ""


CUA_APP = "Cua Spaces.app"
CUA_TOOL = CUA_APP + "/Contents/MacOS/cua"


def cua_candidates(home, environ=None):
    """Where Cua's command-line tool may be, in order. Nollie Runtime names the copy in use in
    NOLLIE_CUA_CLI. Otherwise: the person's own Cua Spaces in Applications, then the copy Nollie keeps
    in its own folder, then a cua the person put on their PATH. Never a link Nollie made: there is none."""
    environ = os.environ if environ is None else environ
    named = environ.get("NOLLIE_CUA_CLI")
    candidates = []
    # Only the tool inside a Cua Spaces app, by absolute path: never another program by that name.
    if named and os.path.isabs(named) and named.endswith("/" + CUA_TOOL) and ".." not in Path(named).parts:
        candidates.append(Path(named))
    candidates += [Path("/Applications") / CUA_TOOL, home / "Applications" / CUA_TOOL,
                   home / "Library/Application Support/Nollie/Cua" / CUA_TOOL]
    which = shutil.which("cua")
    candidates += [Path(which)] if which else []
    candidates += [home / ".local/bin/cua", Path("/opt/homebrew/bin/cua"), Path("/usr/local/bin/cua")]
    return candidates


def find_cua(home, environ=None):
    """Cua's CLI by full path. A launchd PATH may lack the person's own folders, so these are named."""
    for candidate in cua_candidates(Path(home), environ):
        if os.access(candidate, os.X_OK) and not os.path.isdir(candidate):
            return str(candidate)
    return None


def find_hermes():
    """This Hermes's own launcher, so a profile change lands in the Hermes that is running."""
    try:
        import hermes_cli
        own = Path(hermes_cli.__file__).resolve().parents[1] / ".hermes/bin/hermes"
        if os.access(own, os.X_OK):
            return str(own)
    except ImportError:
        pass
    return shutil.which("hermes")


def account_home():
    """The person's real home. Nollie's own runtime gives Hermes a private HOME, but Cua lives in theirs."""
    try:
        return Path(pwd.getpwuid(os.getuid()).pw_dir)
    except (KeyError, OSError):
        return Path.home()


def profile_home(profile):
    from hermes_cli.profiles import get_profile_dir
    return Path(get_profile_dir(profile))


TAILSCALE_TOOLS = ("/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale",
                   "/usr/local/bin/tailscale")
EXIT_NODE_TTL = 15


def exit_node_from_status(text):
    """`tailscale status --json`: True while this Mac uses an exit node, False when it doesn't,
    None when the text isn't Tailscale's status."""
    try:
        data = json.loads(text or "")
    except ValueError:
        return None
    if not isinstance(data, dict) or "BackendState" not in data:
        return None
    return data.get("BackendState") == "Running" and bool(data.get("ExitNodeStatus"))


def tailnet_ipv4(address):
    parts = address.split(".")
    return len(parts) == 4 and parts[0] == "100" and parts[1].isdigit() and 64 <= int(parts[1]) <= 127


class ExitNodeCheck:
    """Whether this Mac sends everything through a Tailscale exit node. Apple's VM networking
    then gets no internet at all, so a helper's computer can't browse. Asks Tailscale's own
    command line, or failing that sees whether the default route leaves on Tailscale's interface.
    Reads only: it never changes Tailscale."""

    def __init__(self, run=default_run, exists=lambda path: os.access(path, os.X_OK), clock=time.time):
        self.run, self.exists, self.clock = run, exists, clock
        self.cached = None

    def __call__(self):
        now = self.clock()
        if self.cached and now - self.cached[1] < EXIT_NODE_TTL:
            return self.cached[0]
        value = self.check()
        self.cached = (value, now)
        return value

    def check(self):
        routed = self.routed()
        for tool in TAILSCALE_TOOLS:
            if not self.exists(tool):
                continue
            code, out = self.run([tool, "status", "--json"], 5)
            verdict = exit_node_from_status(out) if code == 0 else None
            if verdict is not None:
                return verdict or routed
        return routed

    def routed(self):
        code, out = self.run(["/sbin/route", "-n", "get", "default"], 5)
        found = re.search(r"interface:\s*(utun\d+)", out or "") if code == 0 else None
        if not found:
            return False
        code, out = self.run(["/sbin/ifconfig", found.group(1)], 5)
        return code == 0 and any(tailnet_ipv4(a) for a in re.findall(r"inet (\d+\.\d+\.\d+\.\d+)", out or ""))


# Nollie Runtime's exit relay: whenever a helper's computer runs, it reaches the internet through
# the relay, from the Mac, so a VPN or Tailscale exit node carries its traffic too. The runtime
# writes only its state and port to this file; with an exit node on, the app's card follows it.
RELAY_STATE = "Library/Application Support/Nollie/RuntimeService/exit-relay.json"
RELAY_STATES = {"off", "idle", "on", "failed"}
RELAY_MARKER = "nollie-relay-ready"
# ExitRelayPolicy.port in Nollie Runtime.
RELAY_PORT = 47610


def relay_state_path(environ=None, home=None):
    """Where Nollie Runtime keeps the relay's state: named in NOLLIE_EXIT_RELAY under the runtime,
    else in the person's own Nollie folder."""
    environ = os.environ if environ is None else environ
    named = environ.get("NOLLIE_EXIT_RELAY")
    if named and os.path.isabs(named) and named.endswith("/exit-relay.json") and ".." not in Path(named).parts:
        return Path(named)
    return Path(home or account_home()) / RELAY_STATE


def read_relay_state(path=None):
    """{"state": ..., "port": ...} as Nollie Runtime last wrote it, or None when there is no
    relay, or the file isn't exactly what the runtime writes."""
    path = Path(path) if path else relay_state_path()
    try:
        if path.is_symlink() or path.stat().st_size > 4096:
            return None
        document = json.loads(path.read_text())
    except (OSError, ValueError, UnicodeDecodeError):
        return None
    if (not isinstance(document, dict) or document.get("version") != 1 or document.get("state") not in RELAY_STATES
            or type(document.get("port")) is not int or not 1024 <= document["port"] <= 65535):
        return None
    return {"state": document["state"], "port": document["port"]}


def relay_snippet(port):
    """A login-shell snippet: it finds the Mac (the computer's default gateway), checks within a
    second that the relay answers, and only then sets the usual proxy variables. The relay runs
    whenever the computer does; if it is ever down, the check fails at once and nothing changes.
    Fixed text: only the port is filled in."""
    port = int(port)
    if not 1024 <= port <= 65535:
        raise ValueError("port")
    return f"""# Added by Nollie. While Nollie's relay on your Mac answers, web traffic from here goes
# through your Mac, so it follows your Mac's VPN or Tailscale exit node. Otherwise nothing changes.
nollie_relay=$(ip route show default 2>/dev/null | awk '{{print $3; exit}}')
if [ -n "$nollie_relay" ] && command -v bash >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 \\
   && timeout 1 bash -c 'exec 3<>"/dev/tcp/$0/{port}"' "$nollie_relay" 2>/dev/null; then
  export http_proxy="http://$nollie_relay:{port}" https_proxy="http://$nollie_relay:{port}"
  export all_proxy="socks5h://$nollie_relay:{port}" no_proxy="localhost,127.0.0.1,::1"
  export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy" ALL_PROXY="$all_proxy" NO_PROXY="$no_proxy"
fi
unset nollie_relay
"""


def relay_script(port):
    """What Nollie runs once in a helper's computer so its programs use the relay while it answers:
    the snippet goes in /etc/profile.d when the computer allows that, else in the person's own
    profile."""
    quoted = relay_snippet(port).replace("'", "'\\''")
    return f"""set -e
snippet='{quoted}'
if [ -w /etc/profile.d ]; then
  printf '%s' "$snippet" > /etc/profile.d/nollie-relay.sh
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  printf '%s' "$snippet" | sudo -n tee /etc/profile.d/nollie-relay.sh >/dev/null
else
  mkdir -p "$HOME/.config/nollie"
  printf '%s' "$snippet" > "$HOME/.config/nollie/relay.sh"
  for profile in "$HOME/.profile" "$HOME/.bash_profile"; do
    [ "$profile" = "$HOME/.bash_profile" ] && [ ! -e "$profile" ] && continue
    grep -qs 'nollie/relay.sh' "$profile" || printf '\\n[ -r "$HOME/.config/nollie/relay.sh" ] && . "$HOME/.config/nollie/relay.sh"\\n' >> "$profile"
  done
fi
echo {RELAY_MARKER}
"""


def default_space_bash(cua, socket, env, space, command, timeout=60):
    """Runs one command in a Space through Cua's own MCP server (`space_bash`, the only tool this
    child may use), connected to the running daemon only. True when it finished and printed
    Nollie's marker. Its output stays in memory."""
    request = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "nollie-computer", "version": "0.1.0"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
            "name": "space_bash", "arguments": {"space": space, "command": command, "timeout": 30}}},
    ]
    try:
        process = subprocess.Popen([cua, "--daemon", str(socket), "mcp", "--permissions", "spaces:space_bash"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   text=True, env={**os.environ, "CUA_TELEMETRY": "0", **(env or {})})
    except OSError:
        return False
    timer = threading.Timer(timeout, process.kill)
    timer.start()
    try:
        process.stdin.write(json.dumps(request[0]) + "\n")
        process.stdin.flush()
        if not _mcp_reply(process, 1):
            return False
        for message in request[1:]:
            process.stdin.write(json.dumps(message) + "\n")
        process.stdin.flush()
        result = _mcp_reply(process, 2)
        if not isinstance(result, dict) or result.get("isError"):
            return False
        texts = [part.get("text", "") for part in result.get("content", []) if isinstance(part, dict)]
        return any(isinstance(text, str) and RELAY_MARKER in text for text in texts)
    except (OSError, ValueError):
        return False
    finally:
        timer.cancel()
        if process.poll() is None:
            process.kill()
        process.wait()


def _mcp_reply(process, request_id):
    for _ in range(32):
        line = process.stdout.readline()
        if not line or len(line) > 1024 * 1024:
            return None
        try:
            reply = json.loads(line)
        except ValueError:
            return None
        if isinstance(reply, dict) and reply.get("id") == request_id:
            return None if reply.get("error") else reply.get("result")
    return None


class Refused(Exception):
    """An expected refusal, with words a person can read."""

    def __init__(self, message, status=409):
        super().__init__(message)
        self.status = status


class OwnComputers:
    def __init__(self, home=None, run=default_run, hermes=None, cua=None, homes=profile_home,
                 private=None, spawn=None, clock=time.time, yaml_load=None, cua_home=None, exit_node=None,
                 relay=None, space_bash=None):
        self.home = Path(home) if home else Path.home()
        # Where Cua keeps its socket and CLI link; the same as home except under Nollie's runtime.
        self.cua_home = Path(cua_home) if cua_home else (self.home if home else account_home())
        self.run = run
        # A Tailscale exit node on this Mac: the status says so, so the app can show why.
        # A test that fakes the commands it expects gets no extra ones unless it asks for this.
        self.exit_node = exit_node or (ExitNodeCheck() if run is default_run else (lambda: False))
        # Nollie Runtime's relay, and a way to point a computer at it. Same rule for tests.
        self.relay = relay or (read_relay_state if run is default_run else (lambda: None))
        self.space_bash = space_bash or (default_space_bash if run is default_run else (lambda *a, **k: False))
        self.hermes = hermes
        self.cua = cua
        self.homes = homes
        self.private = private or (lambda profile: False)
        self.spawn = spawn or (lambda work: threading.Thread(target=work, daemon=True).start())
        self.clock = clock
        self.yaml_load = yaml_load
        self.find = find_cua
        self.lock = threading.RLock()
        self.jobs = {}
        self.answered = {}

    # MARK: Files

    @property
    def folder(self):
        return self.home / ".hermes/nollie-computer"

    @property
    def state_path(self):
        return self.folder / "own-computers.json"

    @property
    def owned_path(self):
        return self.folder / "owned-spaces.json"

    def read_json(self, path, empty):
        try:
            if path.is_symlink() or path.stat().st_size > 65536:
                raise Refused("A Nollie record on this Mac can't be read safely.", 500)
            document = json.loads(path.read_text())
        except FileNotFoundError:
            return empty
        except (OSError, ValueError, UnicodeDecodeError):
            raise Refused("A Nollie record on this Mac can't be read safely.", 500) from None
        if (not isinstance(document, dict) or document.get("version") != 1
                or not isinstance(document.get("profiles"), dict)):
            raise Refused("A Nollie record on this Mac can't be read safely.", 500)
        return document

    def write_json(self, path, document, backup=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        if backup and path.exists():
            copy = path.with_name(path.name + ".bak-nollie-computer-" + stamp)
            shutil.copy2(path, copy)
            copy.chmod(0o600)
        temporary = path.with_name(path.name + ".tmp-" + stamp)
        temporary.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
        temporary.chmod(0o600)
        temporary.replace(path)

    def record(self, profile):
        return self.read_json(self.state_path, {"version": STATE_VERSION, "profiles": {}})["profiles"].get(profile)

    def save_record(self, profile, entry):
        with self.lock:
            document = self.read_json(self.state_path, {"version": STATE_VERSION, "profiles": {}})
            if entry is None:
                document["profiles"].pop(profile, None)
            else:
                document["profiles"][profile] = entry
            self.write_json(self.state_path, document)

    def set_owned(self, profile, target):
        """Adds or drops this profile's entry in the preview's ownership record, others untouched."""
        with self.lock:
            document = self.read_json(self.owned_path, {"version": 1, "profiles": {}})
            if target is None:
                if profile not in document["profiles"]:
                    return
                document["profiles"].pop(profile)
            else:
                document["profiles"][profile] = target
            self.write_json(self.owned_path, document, backup=True)

    def owned(self, profile):
        target = self.read_json(self.owned_path, {"version": 1, "profiles": {}})["profiles"].get(profile)
        return target if isinstance(target, str) and SPACE_TARGET.fullmatch(target) else None

    def config(self, profile):
        path = self.homes(profile) / "config.yaml"
        try:
            text = path.read_text()
        except FileNotFoundError:
            return {}
        except (OSError, UnicodeDecodeError):
            raise Refused("This helper's settings can't be read right now.", 500) from None
        load = self.yaml_load
        if load is None:
            import yaml
            load = yaml.safe_load
        try:
            document = load(text)
        except Exception:
            raise Refused("This helper's settings can't be read right now.", 500) from None
        return document if isinstance(document, dict) else {}

    @staticmethod
    def lookup(document, dotted):
        current = document
        for part in dotted.split("."):
            if not isinstance(current, dict) or part not in current:
                return None
            current = current[part]
        return current

    def backup_config(self, profile):
        path = self.homes(profile) / "config.yaml"
        if path.exists():
            stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
            copy = path.with_name("config.yaml.bak-nollie-computer-" + stamp)
            shutil.copy2(path, copy)
            copy.chmod(0o600)

    # MARK: Cua

    def cua_path(self):
        return self.cua or self.find(self.cua_home)

    @property
    def socket(self):
        return self.cua_home / ".cua/cua.sock"

    @property
    def cua_env(self):
        return {"HOME": str(self.cua_home)}

    def cua_json(self, *arguments, timeout=20):
        """A read from the running daemon only. None when it can't answer."""
        cua = self.cua_path()
        if not cua or not self.socket.exists():
            return None
        code, out = self.run([cua, "--daemon", str(self.socket), "--json", *arguments], timeout, self.cua_env)
        if code != 0:
            return None
        try:
            return json.loads(out)
        except ValueError:
            return None

    def setup(self):
        """What Cua on this Mac still needs before a helper can have a computer."""
        cua = self.cua_path()
        if not cua:
            return "no_cua", None
        code, out = self.run([cua, "--version"], 15, self.cua_env)
        version = parse_version(out) if code == 0 else None
        shown = ".".join(map(str, version)) if version else None
        if version is None or version < MIN_CUA:
            return "old_cua", shown
        if not self.socket.exists():
            return "cua_not_running", shown
        doctor = self.cua_json("runtime", "doctor")
        if doctor is None:
            return "cua_not_running", shown
        backends = doctor.get("backends") if isinstance(doctor, dict) else None
        ready = any(isinstance(b, dict) and b.get("backend") in LINUX_BACKENDS and b.get("ready") is True
                    for b in backends or [])
        return ("ready" if ready else "no_runtime"), shown

    def space(self, profile):
        """This helper's Space as Cua lists it: None when missing, False when Cua can't say."""
        listing = self.cua_json("spaces", "ls")
        if not isinstance(listing, dict) or not isinstance(listing.get("spaces"), list):
            return False
        wanted = "local:" + space_name(profile)
        for entry in listing["spaces"]:
            if isinstance(entry, dict) and entry.get("id") == wanted:
                return entry
        return None

    def cua_change(self, *arguments, timeout=CLI_TIMEOUT, failure="Cua couldn't finish that. Try again in a moment."):
        cua = self.cua_path()
        if not cua:
            raise Refused("Cua isn't on this Mac.")
        code, out = self.run([cua, *arguments], timeout, self.cua_env)
        if code != 0:
            raise Refused(failure)
        return out

    # MARK: Hermes

    def hermes_change(self, profile, *arguments, timeout=CLI_TIMEOUT):
        hermes = self.hermes or find_hermes()
        if not hermes:
            raise Refused("Hermes can't be found on this Mac.", 500)
        # Pin the profile: a sticky active profile must never redirect this change.
        code, _ = self.run([hermes, "--profile", profile, *arguments], timeout)
        if code != 0:
            raise Refused("Hermes didn't accept that change. Its settings were backed up first.")

    def plugin_installed(self, profile):
        return (self.homes(profile) / "plugins" / PLUGIN_NAME / "plugin.yaml").exists()

    def plugin_enabled(self, config):
        enabled = self.lookup(config, "plugins.enabled")
        return isinstance(enabled, list) and PLUGIN_NAME in enabled

    def is_on(self, config, profile):
        return (self.lookup(config, "terminal.backend") == "cua" and self.plugin_enabled(config)
                and self.lookup(config, SETTINGS + ".space") == space_name(profile))

    # MARK: Status

    def check(self, profile):
        if not isinstance(profile, str) or not PROFILE_NAME.fullmatch(profile):
            raise Refused("That isn't a helper on this Mac.", 422)
        try:
            refused = self.private(profile)
        except Exception:
            refused = True
        if refused:
            raise Refused("That isn't a helper on this Mac.", 404)

    def status(self, profile):
        self.check(profile)
        setup, version = self.setup()
        config = self.config(profile)
        on = self.is_on(config, profile)
        job = self.jobs.get(profile)
        entry = self.record(profile) or {}
        result = {"profile": profile, "on": on, "setup": setup, "cua_version": version,
                  "computer_name": None, "has_computer": False, "busy": job is not None,
                  "state": "off", "message": None, "step": job["step"] if job else None,
                  "internet": self.internet(entry)}
        found = self.space(profile) if setup == "ready" else False
        if found:
            result["has_computer"] = True
            result["computer_name"] = space_name(profile)
        elif entry.get("space"):
            result["computer_name"] = space_name(profile)
            # Cua can't list right now: say there is one rather than offering to make another.
            result["has_computer"] = found is False
        if job:
            result["on"] = job["action"] in ("on", "reset")
            result["state"] = {"on": "getting_ready", "reset": "getting_ready", "off": "turning_off",
                               "remove": "removing"}[job["action"]]
            result["computer_name"] = space_name(profile)
            return result
        if entry.get("wanted") and (entry.get("failed") or not on):
            result.update(on=True, state="needs_you", message=entry.get("failed")
                          or "Setting up its computer stopped partway. Try again.")
            return result
        if not on:
            return result
        if setup != "ready":
            result.update(state="needs_you", message={
                "no_cua": "Cua isn't on this Mac anymore.",
                "old_cua": "Cua needs an update.",
                "cua_not_running": "Cua isn't running on your Mac.",
                "no_runtime": "Cua can't run computers on this Mac yet."}[setup])
        elif found is None:
            result.update(state="needs_you", message="Its computer is missing. Turn the switch off and on to make a new one.")
        elif found is False:
            result.update(state="needs_you", message="Cua didn't answer just now.")
        else:
            running = found.get("power_state") == "running" or found.get("status") == "ready"
            result["state"] = "ready" if running else "asleep"
        return result

    def internet(self, entry):
        """None without an exit node. "relay" when Nollie Runtime's relay carries this computer's
        traffic (or will once it runs) and the computer was pointed at it; else "exit_node", and
        the app shows the card."""
        if not self.exit_node():
            return None
        relay = self.relay()
        pointed = entry.get("relay")
        if relay and relay["state"] in ("on", "idle") and type(pointed) is int and pointed == relay["port"]:
            return "relay"
        return "exit_node"

    # MARK: Changes

    def change(self, profile, action, request_id):
        """Starts one change. The same request ID never runs twice: a client that lost the
        answer gets the current status instead."""
        self.check(profile)
        if not isinstance(request_id, str) or not re.fullmatch(r"[A-Za-z0-9-]{8,64}", request_id):
            raise Refused("Send a request ID.", 422)
        if action not in ("on", "off", "reset", "remove"):
            raise Refused("Unknown action.", 422)
        with self.lock:
            if request_id in self.answered:
                return self.status(profile)
            if profile in self.jobs:
                raise Refused("Still working on the last change.")
            setup, _ = self.setup()
            config = self.config(profile)
            on = self.is_on(config, profile)
            entry = self.record(profile) or {}
            if action in ("on", "reset", "remove") and setup != "ready":
                raise Refused("Cua needs setting up on your Mac first.")
            if action == "reset" and not (on or entry.get("wanted")):
                raise Refused("Its computer is off.")
            if action == "remove" and (on or entry.get("wanted")):
                raise Refused("Turn its computer off first.")
            self.answered[request_id] = self.clock()
            if len(self.answered) > 256:
                oldest = sorted(self.answered, key=self.answered.get)[:128]
                for key in oldest:
                    self.answered.pop(key, None)
            self.jobs[profile] = {"action": action, "step": None}
        work = {"on": self.turn_on, "off": self.turn_off, "reset": self.reset, "remove": self.remove}[action]

        def run():
            try:
                work(profile)
            except Refused as refusal:
                if action in ("on", "reset"):
                    entry = self.record(profile) or {}
                    self.save_record(profile, {**entry, "wanted": True, "failed": str(refusal)})
            except Exception:
                if action in ("on", "reset"):
                    entry = self.record(profile) or {}
                    self.save_record(profile, {**entry, "wanted": True,
                                               "failed": "Something went wrong. Try again in a moment."})
            finally:
                with self.lock:
                    self.jobs.pop(profile, None)
        self.spawn(run)
        return self.status(profile)

    def step(self, profile, name):
        with self.lock:
            if profile in self.jobs:
                self.jobs[profile]["step"] = name

    def turn_on(self, profile):
        config = self.config(profile)
        entry = self.record(profile) or {}
        if "previous" not in entry:
            # Saved once, before the first change: what turning it off puts back.
            entry = {"previous": {key: self.lookup(config, key) for key in MANAGED_KEYS},
                     "plugin_was_enabled": self.plugin_enabled(config)}
        entry.update(wanted=True, failed=None, space="local:" + space_name(profile))
        self.save_record(profile, entry)
        self.backup_config(profile)
        self.step(profile, "add_on")
        if not self.plugin_installed(profile):
            self.hermes_change(profile, "plugins", "install", PLUGIN_URL, "--ref", PLUGIN_REF,
                               "--force", "--enable", "--yes-deps", timeout=600)
        elif not self.plugin_enabled(config):
            self.hermes_change(profile, "plugins", "enable", PLUGIN_NAME)
        name = space_name(profile)
        for key, value in ((".space", name), (".on", "local"), (".image", "linux"), (".delete_on_exit", "false")):
            self.hermes_change(profile, "config", "set", SETTINGS + key, value)
        self.step(profile, "computer")
        found = self.space(profile)
        if found is None:
            self.cua_change("spaces", "create", "linux", "--on", "local", "--name", name, timeout=CREATE_TIMEOUT,
                            failure=MAKE_FAILED)
            if not self.space(profile):
                raise Refused(MAKE_FAILED)
        elif found is False:
            raise Refused("Cua didn't answer just now.")
        self.set_owned(profile, "local:" + name)
        self.point_at_relay(profile)
        # Last: the helper's commands move to its computer only once it exists.
        self.step(profile, "switching")
        self.hermes_change(profile, "config", "set", "terminal.backend", "cua")
        self.save_record(profile, {**(self.record(profile) or entry), "wanted": True, "failed": None})

    def point_at_relay(self, profile):
        """Once per computer: its programs use Nollie Runtime's relay whenever it answers. Never
        fails the switch: if Cua can't run it, the computer simply keeps its own network and the
        exit node card stays."""
        port = (self.relay() or {}).get("port", RELAY_PORT)
        cua = self.cua_path()
        done = False
        if cua and self.socket.exists():
            try:
                done = bool(self.space_bash(cua, self.socket, self.cua_env, "local:" + space_name(profile),
                                            relay_script(port)))
            except Exception:
                done = False
        entry = self.record(profile) or {}
        self.save_record(profile, {**entry, "relay": port if done else None})

    def turn_off(self, profile):
        entry = self.record(profile) or {}
        previous = entry.get("previous")
        self.backup_config(profile)
        if isinstance(previous, dict):
            # The terminal first, so the helper's next command already runs where it used to.
            for key in MANAGED_KEYS:
                value = previous.get(key)
                if value is None:
                    if self.lookup(self.config(profile), key) is not None:
                        self.hermes_change(profile, "config", "unset", key)
                else:
                    self.hermes_change(profile, "config", "set", key,
                                       ("true" if value else "false") if isinstance(value, bool) else str(value))
            if not entry.get("plugin_was_enabled") and self.plugin_enabled(self.config(profile)):
                self.hermes_change(profile, "plugins", "disable", PLUGIN_NAME)
        elif self.lookup(self.config(profile), "terminal.backend") == "cua":
            # No saved values (an older or hand-made setup): Hermes's own default terminal.
            self.hermes_change(profile, "config", "unset", "terminal.backend")
        keep = {"space": entry["space"]} if entry.get("space") else None
        self.save_record(profile, keep)

    def reset(self, profile):
        self.step(profile, "computer")
        name = space_name(profile)
        if self.space(profile):
            self.cua_change("spaces", "delete", "local:" + name, "--force")
        self.cua_change("spaces", "create", "linux", "--on", "local", "--name", name, timeout=CREATE_TIMEOUT,
                            failure=MAKE_FAILED)
        if not self.space(profile):
            raise Refused(MAKE_FAILED)
        self.point_at_relay(profile)
        entry = self.record(profile) or {}
        self.save_record(profile, {**entry, "failed": None})

    def remove(self, profile):
        name = space_name(profile)
        if self.space(profile):
            self.cua_change("spaces", "delete", "local:" + name, "--force")
        if self.owned(profile) == "local:" + name:
            self.set_owned(profile, None)
        self.save_record(profile, None)

    # MARK: Removing Nollie

    def release(self, spaces_only=False):
        """Before Nollie is removed: every computer Nollie made for a helper goes.

        For each helper Nollie gave a computer, its terminal and plugin settings go back to what
        they were (the same steps as turning it off), then its computer is deleted, but only one
        Nollie named itself (nollie-<profile>) and recorded. With spaces_only (a managed setup that
        is deleted next anyway) settings are left. A computer whose helper could not be switched
        back is kept, so the helper never points at a computer that is gone. Never raises for one
        helper's trouble: each one is reported in plain words."""
        empty = {"version": STATE_VERSION, "profiles": {}}
        with self.lock:
            state = self.read_json(self.state_path, empty)["profiles"]
            owned = self.read_json(self.owned_path, {"version": 1, "profiles": {}})["profiles"]
        report = {}
        for profile in sorted(p for p in set(state) | set(owned) if isinstance(p, str) and PROFILE_NAME.fullmatch(p)):
            entry = state.get(profile) if isinstance(state.get(profile), dict) else {}
            result = {"turned_off": False, "computer": "none", "message": None}
            switched_back = True
            if not spaces_only:
                try:
                    config = self.config(profile)
                    if isinstance(entry.get("previous"), dict) or entry.get("wanted") or self.is_on(config, profile):
                        self.turn_off(profile)
                        result["turned_off"] = True
                except Refused as refusal:
                    switched_back = False
                    result["message"] = str(refusal)
                except Exception:
                    switched_back = False
                    result["message"] = "Its settings couldn't be put back."
            target = "local:" + space_name(profile)
            if owned.get(profile) == target or entry.get("space") == target:
                if not switched_back:
                    result["computer"] = "kept"
                else:
                    found = self.space(profile)
                    if found is False:
                        result["computer"] = "kept"
                        result["message"] = result["message"] or "Cua didn't answer, so its computer is still there."
                    else:
                        try:
                            if found:
                                self.cua_change("spaces", "delete", target, "--force")
                            result["computer"] = "deleted" if found else "gone"
                        except Refused as refusal:
                            result["computer"] = "kept"
                            result["message"] = result["message"] or str(refusal)
                if result["computer"] in ("deleted", "gone"):
                    if owned.get(profile) == target:
                        self.set_owned(profile, None)
                    self.save_record(profile, None)
            report[profile] = result
        return {"version": 1, "profiles": report}


def main(argv=None):
    """`own_computer.py release --home <home> --cua-home <person's home> [--spaces-only]`: run by
    Nollie's Remove step with the Hermes's own Python. Prints one JSON report."""
    import argparse
    parser = argparse.ArgumentParser(prog="own_computer.py")
    commands = parser.add_subparsers(dest="command", required=True)
    release = commands.add_parser("release")
    release.add_argument("--home", required=True)
    release.add_argument("--cua-home", required=True)
    release.add_argument("--spaces-only", action="store_true")
    args = parser.parse_args(argv)
    computers = OwnComputers(home=args.home, cua_home=args.cua_home)
    try:
        report = computers.release(spaces_only=args.spaces_only)
    except Refused as refusal:
        report = {"version": 1, "profiles": {}, "message": str(refusal)}
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
