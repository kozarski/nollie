"""Run the owned Hermes role and stop it if its native supervisor disappears."""
import argparse
import contextvars
import functools
import hashlib
import http.client
import importlib.util
import json
import re
import time
import urllib.parse
import os
from pathlib import Path
import runpy
import signal
import socket
import stat
import subprocess
import sys
import threading
import urllib.request


# This compatibility scope is only valid for the source archived by the native installer.
CATALOG_SOURCE_HASHES = {
    "agent/models_dev.py": "92bab26726beae0259989c75316167134b0f67a243a5faa4a29c5f6e4ac9f30d",
    "hermes_cli/model_catalog.py": "80dd5e199de1dc5cac7eab22bf3030d1ad659645fbf01c1ef9c106384451e832",
    "hermes_cli/model_switch_providers.py": "462ecb18bd015dc6dd5e48990e2248d07d2200c61610f887f81afc450208ea0d",
    "hermes_cli/inventory.py": "ef4280ca5abc210e4ef273015d04debf5b5582375af272b52822b56a8c03d04a",
}


MODEL_PROBE_SOURCE_HASHES = {
    'hermes_cli/web_routers/local_models.py': '381c8db2a27d7d60809a8e93f2a57efb663aed7d1b461235d077bad6659d2f2c',
    'hermes_cli/local_runtime/endpoint.py': '58e36eaede25d34e438fa874fd6866e2a3fe37b1a58a74eb139240fc3491425a',
    'hermes_cli/local_runtime/recovery.py': '8446fb9e257d8461a84859592c6bc9940cce39315635c03ca7a9b9136679fb2f',
    'hermes_cli/local_runtime/bootstrap.py': 'c48dd0d0a90f9f66de15928ff3d5545e6eaa80bbce26b50d37790f82da71e87b',
    'hermes_cli/web_server.py': 'bd14c619166da6534b94d0a6e802c6da3711f9738dc80747c17f85af2e71af0b',
}

PROFILE_SOURCE_HASHES = {
    "hermes_cli/profiles.py": "f65320d57dfe6bd670c139b5b2c394eb6150cf67b9536b8a82e95f0ea0180f14",
}

KEY_SOURCE_HASHES = {
    "hermes_cli/env_loader.py": "da921984d4cd690bbb9813c6431ecc88b18b46307800d155c86e25c8e45ccee1",
    "agent/secret_sources/registry.py": "d3cde03a36e77b8ce342549acc4d684d28071baa619c5e6b7b00c1f97650e08f",
    "agent/secret_sources/base.py": "49b39c137a57691030966101313becfb455b6ea5f89d160808ff3bee601b3cee",
    "agent/secret_scope.py": "e641d7e811d988cb25140005b61d44a82829f0957dd52b8a79c3c9915da80cf2",
    "hermes_cli/profile_channels.py": "dca712fdcb9176e3d20e49b254d0d97b2340c289c84b7f883239b8f659a4f0eb",
}

KEY_SOURCE = "nollie_keychain"
CLONE_NOTE = ".nollie-keys-from"
_ENV_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]{0,127}")
_PROFILE_NAME = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}")


def _validate_catalog_source(source, hashes=None):
    root = Path(source).resolve(strict=True)
    for relative, expected in (CATALOG_SOURCE_HASHES if hashes is None else hashes).items():
        path = root / relative
        if path.resolve(strict=True) != path or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise SystemExit(78)


def _scope_model_inventory(models_dev, catalog, inventory):
    """Keep normal picker metadata reads offline without changing provider or model readiness."""
    cache_only = contextvars.ContextVar("nollie_picker_cache_only", default=False)
    original_fetch = models_dev.fetch_models_dev
    original_catalog = catalog.get_catalog
    original_override = catalog._fetch_provider_override
    original_options = inventory.build_model_options_payload

    @functools.wraps(original_fetch)
    def fetch(*args, **kwargs):
        if cache_only.get():
            return original_fetch(allow_network=False)
        return original_fetch(*args, **kwargs)

    @functools.wraps(original_catalog)
    def read_catalog(*args, **kwargs):
        if not cache_only.get():
            return original_catalog(*args, **kwargs)
        if not catalog._load_catalog_config()["enabled"]:
            return {}
        data, _ = catalog._read_disk_cache()
        return data if data is not None else (catalog._in_process_catalog() or {})

    @functools.wraps(original_override)
    def provider_override(*args, **kwargs):
        if cache_only.get():
            return None
        return original_override(*args, **kwargs)

    @functools.wraps(original_options)
    def options(*args, **kwargs):
        token = cache_only.set(not bool(kwargs.get("refresh", False)))
        try:
            return original_options(*args, **kwargs)
        finally:
            cache_only.reset(token)

    models_dev.fetch_models_dev = fetch
    catalog.get_catalog = read_catalog
    catalog._fetch_provider_override = provider_override
    inventory.build_model_options_payload = options


def _install_model_inventory_compatibility(source):
    _validate_catalog_source(source)
    from agent import models_dev
    from hermes_cli import inventory, model_catalog

    root = Path(source).resolve(strict=True)
    for module, relative in ((models_dev, "agent/models_dev.py"),
                             (inventory, "hermes_cli/inventory.py"),
                             (model_catalog, "hermes_cli/model_catalog.py")):
        if Path(module.__file__).resolve(strict=True) != root / relative:
            raise SystemExit(78)
    _scope_model_inventory(models_dev, model_catalog, inventory)
    _install_local_reply_probe(source)


class LocalReplyFailure(Exception):
    pass


def _local_reply_target(endpoint, model, staged):
    if not isinstance(model, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,200}", model) or model not in staged:
        raise LocalReplyFailure()
    if not isinstance(endpoint, tuple) or len(endpoint) != 2:
        raise LocalReplyFailure()
    base, key = endpoint
    if not isinstance(base, str) or not isinstance(key, str) or not key or len(key) > 1024:
        raise LocalReplyFailure()
    try:
        parsed = urllib.parse.urlsplit(base)
        port = parsed.port
    except ValueError:
        raise LocalReplyFailure() from None
    if (parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or not port or
            parsed.username is not None or parsed.password is not None or
            parsed.path not in ("", "/") or parsed.query or parsed.fragment):
        raise LocalReplyFailure()
    return port, key


def _local_reply_request(port, key, model, connection_factory=http.client.HTTPConnection):
    """One fixed inference on the owned router. No proxy, redirect, tools or agent turn."""
    body = json.dumps({"model": model,
                       "messages": [{"role": "user", "content": "Reply with one short friendly greeting."}],
                       "max_tokens": 512, "temperature": 0, "stream": False,
                       "tools": [], "tool_choice": "none"}).encode()
    connection = connection_factory("127.0.0.1", port, timeout=3)
    deadline = time.monotonic() + 180
    active_socket = None

    def expire():
        try:
            if active_socket is not None:
                active_socket.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    timer = threading.Timer(180, expire)
    timer.daemon = True
    timer.start()
    try:
        connection.connect()
        active_socket = connection.sock
        active_socket.settimeout(180)
        connection.request("POST", "/v1/chat/completions", body=body,
                           headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
        response = connection.getresponse()
        if response.status != 200:
            raise LocalReplyFailure()
        length = response.getheader("Content-Length")
        if length is not None and (not length.isdigit() or int(length) > 65_536):
            raise LocalReplyFailure()
        raw = bytearray()
        while len(raw) <= 65_536:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise LocalReplyFailure()
            active_socket.settimeout(remaining)
            chunk = response.read1(min(4096, 65_537 - len(raw)))
            if not chunk:
                break
            raw.extend(chunk)
        if len(raw) > 65_536:
            raise LocalReplyFailure()
        result = json.loads(raw)
        choice = result["choices"][0]
        message = choice["message"]
        text = message.get("content")
        if (result.get("model") != model or choice.get("finish_reason") != "stop" or
                message.get("tool_calls") or message.get("function_call") or
                not isinstance(text, str) or not text.strip() or len(text) > 4096):
            raise LocalReplyFailure()
        return {"provider": "llamacpp", "model": result["model"], "text": text.strip()}
    except Exception:
        raise LocalReplyFailure() from None
    finally:
        timer.cancel()
        connection.close()


def _perform_local_reply(profile, authenticated, current_model, staged_models, managed_endpoint,
                         lock, request=_local_reply_request):
    # Reject before any model/config access. This route exists only in the isolated API child.
    if profile != "default" or not authenticated:
        raise LocalReplyFailure()
    if not lock.acquire(blocking=False):
        raise LocalReplyFailure()
    try:
        model = current_model()
        endpoint = managed_endpoint()
        port, key = _local_reply_target(endpoint, model, staged_models())
        result = request(port, key, model)
        if managed_endpoint() != endpoint or current_model() != model:
            raise LocalReplyFailure()
        return result
    finally:
        lock.release()


def _install_local_reply_probe(source):
    _validate_catalog_source(source, MODEL_PROBE_SOURCE_HASHES)
    from fastapi import HTTPException, Request
    from hermes_cli.web_routers import local_models
    from hermes_cli.local_runtime import bootstrap, endpoint
    root = Path(source).resolve(strict=True)
    for module, relative in ((local_models, "hermes_cli/web_routers/local_models.py"),
                             (bootstrap, "hermes_cli/local_runtime/bootstrap.py"),
                             (endpoint, "hermes_cli/local_runtime/endpoint.py")):
        if Path(module.__file__).resolve(strict=True) != root / relative:
            raise SystemExit(78)
    lock = threading.Lock()

    def reply_check(request: Request, profile: str = "default"):
        from hermes_cli import web_server
        # Require the native session credential even if other dashboard auth modes change.
        if not web_server._has_valid_session_token(request):
            raise HTTPException(status_code=401, detail="Unauthorized")
        if profile != "default":
            raise HTTPException(status_code=403, detail="Local check is unavailable for this profile")
        try:
            return _perform_local_reply(profile, True, local_models._active_llamacpp_model_id,
                                        bootstrap.staged_model_ids, endpoint.managed_root, lock)
        except Exception:
            raise HTTPException(status_code=503, detail="The local model reply was not verified") from None

    local_models.router.add_api_route("/api/nollie/local-model/reply-check", reply_check, methods=["POST"])


def _read_keys(descriptor):
    """The API keys the native helper took from the Keychain for this start, read once from a
    private pipe: ``{bot: {NAME: value}}``. They never pass through argv, files or logs."""
    if descriptor < 3 or not stat.S_ISFIFO(os.fstat(descriptor).st_mode):
        raise SystemExit(78)
    os.set_inheritable(descriptor, False)
    chunks, size = [], 0
    try:
        while chunk := os.read(descriptor, 65536):
            size += len(chunk)
            if size > 1 << 22:
                raise SystemExit(78)
            chunks.append(chunk)
    finally:
        os.close(descriptor)
    try:
        body = json.loads(b"".join(chunks))
    except ValueError:
        raise SystemExit(78) from None
    profiles = body.get("profiles") if isinstance(body, dict) and body.get("version") == 1 else None
    if not isinstance(profiles, dict):
        raise SystemExit(78)
    keys = {}
    for profile, values in profiles.items():
        if not (profile == "default" or _PROFILE_NAME.fullmatch(profile)) or not isinstance(values, dict):
            raise SystemExit(78)
        for name, value in values.items():
            if (not _ENV_NAME.fullmatch(name) or not isinstance(value, str) or not value
                    or "\0" in value or len(value) > 65536):
                raise SystemExit(78)
        keys[profile] = dict(values)
    return keys


def _clone_note(folder):
    """The bot this one was copied from and the key names it took along, or None."""
    try:
        descriptor = os.open(folder / CLONE_NOTE, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 16384:
            return None
        note = json.loads(os.read(descriptor, 16385))
    except (OSError, ValueError):
        return None
    finally:
        os.close(descriptor)
    if not isinstance(note, dict) or note.get("version") != 1:
        return None
    source, names = note.get("from"), note.get("names")
    if not isinstance(source, str) or not (source == "default" or _PROFILE_NAME.fullmatch(source)):
        return None
    if not isinstance(names, list) or not all(isinstance(n, str) and _ENV_NAME.fullmatch(n) for n in names):
        return None
    return source, names


def _profile_keys(keys, home, folder):
    """One bot's keys: ``default`` is the home itself, any other bot is ``profiles/<id>``. A bot
    copied from another since this start also gets the keys its copy took along."""
    try:
        target, launch = Path(folder).resolve(), Path(home).resolve()
    except (OSError, RuntimeError):
        return {}
    if target == launch:
        profile = "default"
    elif target.parent == launch / "profiles" and target.name != "default" and _PROFILE_NAME.fullmatch(target.name):
        profile = target.name
    else:
        return {}
    found = dict(keys.get(profile, {}))
    note = _clone_note(target) if profile != "default" else None
    if note:
        source, names = note
        for name in names:
            if name not in found and name in keys.get(source, {}):
                found[name] = keys[source][name]
    return found


def _scope_keychain_source(base, registry, env_loader, home, keys, read_env):
    """Hand the Keychain's keys to Hermes through its own secret-source contract.

    Each bot's keys stay its own: Hermes resolves the launch bot into this process's environment
    and every other bot into that bot's own secret scope, never into the shared environment.
    Whatever a bot's ``.env`` says about a name wins, in every process, as it did before keys
    moved: a key Hermes writes there is a newer value (the next start moves it into the
    Keychain), and an empty one means Hermes cleared it.
    """
    def written(folder):
        try:
            return read_env(Path(folder) / ".env")
        except Exception:
            return {}

    def own(folder):
        on_disk = written(folder)
        return {name: value for name, value in _profile_keys(keys, home, folder).items() if name not in on_disk}

    class KeychainSource(base.SecretSource):
        name = KEY_SOURCE
        label = "your Mac's Keychain"
        shape = "bulk"

        def is_enabled(self, cfg):
            return True

        def fetch(self, cfg, home_path):
            return base.FetchResult(secrets=own(home_path))

    if not registry.register_source(KeychainSource(), replace=True, builtin=True):
        raise SystemExit(78)
    original = env_loader._load_secrets_config

    @functools.wraps(original)
    def load_secrets_config(home_path):
        # A copy, so Hermes's cached config.yaml never gains this section or writes it back.
        loaded = original(home_path)
        sections = dict(loaded) if isinstance(loaded, dict) else {}
        sections[KEY_SOURCE] = {"enabled": True}
        return sections

    original_values = env_loader.get_secret_source_values

    @functools.wraps(original_values)
    def source_values(hermes_home):
        # The values snapshot is taken once per bot and process; a later .env edit still wins.
        found = original_values(hermes_home)
        ours = _profile_keys(keys, home, hermes_home)
        on_disk = written(hermes_home) if ours else {}
        return {name: value for name, value in found.items() if not (name in ours and name in on_disk)}

    env_loader._load_secrets_config = load_secrets_config
    env_loader.get_secret_source_values = source_values


def _install_keychain_source(source, keys):
    _validate_catalog_source(source, KEY_SOURCE_HASHES)
    from agent import secret_scope
    from agent.secret_sources import base, registry
    from hermes_cli import env_loader
    root = Path(source).resolve(strict=True)
    for module, relative in ((base, "agent/secret_sources/base.py"), (registry, "agent/secret_sources/registry.py"),
                             (env_loader, "hermes_cli/env_loader.py"), (secret_scope, "agent/secret_scope.py")):
        if Path(module.__file__).resolve(strict=True) != root / relative:
            raise SystemExit(78)
    try:
        home = Path(os.environ["HERMES_HOME"]).absolute()
    except KeyError:
        raise SystemExit(78) from None
    _scope_keychain_source(base, registry, env_loader, home, keys, secret_scope.load_env_file)


def _note_cloned_keys(keys, home):
    """A copied bot used to get its source's ``.env``, keys included. Keys now live in the
    Keychain, so the copy records which names it takes along (never values) for this start's
    secret source and for the helper to copy at the next start. Messaging bot tokens stay
    behind, as Hermes's own copy leaves them."""
    def note(folder, source, keep_channels):
        names = sorted(keys.get(source, {}))
        if names and not keep_channels:
            try:
                from hermes_cli.profile_channels import ChannelKeyIndex
                index = ChannelKeyIndex(home if source == "default" else home / "profiles" / source)
                names = [name for name in names if index.platform_for(name) is None]
            except Exception:
                names = []
        if not names:
            return
        descriptor = os.open(Path(folder) / CLONE_NOTE, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump({"version": 1, "from": source, "names": names}, handle)
    return note


def _scope_profile_workflow(profiles, addons, home, clone_keys=None):
    """Finish Ask first inside Hermes's hidden staging folder, before a bot can be served."""
    original_create = profiles.create_profile
    original_finish = profiles._finish_profile_layout
    creating = contextvars.ContextVar("nollie_creating_profile", default=None)

    def require_public(name):
        policy, private = addons.workflow_privacy(home / "plugins" / addons.WORKFLOW, home)
        if policy.excluded(name, private):
            raise ValueError("Private bots cannot be copied or created here.")

    @functools.wraps(original_create)
    def create(name, *args, **kwargs):
        canon = profiles._canon_valid(name)
        require_public(canon)
        clone_from = args[0] if args else kwargs.get("clone_from")
        clone_all = args[1] if len(args) > 1 else kwargs.get("clone_all", False)
        clone_config = args[2] if len(args) > 2 else kwargs.get("clone_config", False)
        clone_channels = args[6] if len(args) > 6 else kwargs.get("clone_channels", False)
        source = None
        if clone_from is not None or clone_all or clone_config:
            source = profiles._canon_valid(clone_from or profiles.get_active_profile_name() or "default")
            require_public(source)
        token = creating.set((canon, source, bool(clone_channels)))
        try:
            return original_create(name, *args, **kwargs)
        finally:
            creating.reset(token)

    @functools.wraps(original_finish)
    def finish(profile_dir, *args, **kwargs):
        name, source, clone_channels = creating.get() or (None, None, False)
        expected = home / "profiles" / f".{name}.staging-{os.getpid()}"
        if name is None or Path(profile_dir) != expected:
            raise ValueError("The new bot's setup could not be checked.")
        require_public(name)
        result = original_finish(profile_dir, *args, **kwargs)
        addons.ensure_profile_workflow(home, name, profile_dir)
        if source is not None and clone_keys is not None:
            clone_keys(profile_dir, source, clone_channels)
        return result

    profiles.create_profile = create
    profiles._finish_profile_layout = finish


def _prepare_profile_workflow(source, keys):
    _validate_catalog_source(source, PROFILE_SOURCE_HASHES)
    helper = Path(__file__).with_name("managed_addons.py")
    if helper.is_symlink() or not helper.is_file():
        raise SystemExit(78)
    spec = importlib.util.spec_from_file_location("nollie_runtime_addons", helper)
    addons = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(addons)
    try:
        home = Path(os.environ["HERMES_HOME"]).absolute()
        addons.ensure_workflow(home)
    except (KeyError, addons.Refused, OSError, ValueError):
        raise SystemExit(78) from None
    from hermes_cli import profiles
    if Path(profiles.__file__).resolve(strict=True) != Path(source).resolve(strict=True) / "hermes_cli/profiles.py":
        raise SystemExit(78)
    _scope_profile_workflow(profiles, addons, home, _note_cloned_keys(keys, home))


# Papertrail's door. Nollie Runtime starts Hermes with every proxy variable pointing at its door on
# loopback, labelled "unplaced.program". Here the label says which bot and which kind of program, so
# each connection lands in that bot's own Papertrail. A program that can't be placed keeps the
# "unplaced" label: the door passes it on and writes nothing, rather than guess at a private bot.
DOOR_URL = re.compile(r"\Ahttp://unplaced\.program:([0-9a-f]{64})@127\.0\.0\.1:([0-9]{1,5})\Z")
PROXY_NAMES = ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy")
DIRECT = "localhost,127.0.0.1,::1"
BOT_NAME = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")
# The innermost Hermes module on the stack names the kind of program a child process is.
CHILD_KINDS = (
    ("tools.code_execution_tool", "code"),
    ("tools.terminal_tool", "terminal"), ("tools.environments", "terminal"), ("tools.process_registry", "terminal"),
    ("tools.mcp_tool", "mcp"), ("mcp.", "mcp"),
    ("nollie_reader", "reader"), ("nollie-reader", "reader"),
    ("agent.transports", "model"), ("agent.codex", "model"), ("claude", "model"),
)


def _door(environ):
    """(secret, port) of the door Hermes was started with, or None."""
    found = DOOR_URL.match(environ.get("HTTPS_PROXY", ""))
    if found is None or any(environ.get(name) != found.group(0) for name in PROXY_NAMES):
        return None
    port = int(found.group(2))
    return (found.group(1), port) if 0 < port < 65536 else None


def _bot_of(home, default_home):
    """The bot a Hermes home belongs to: "default", a profile's name, or "unplaced"."""
    try:
        home = Path(home).absolute()
    except (TypeError, ValueError):
        return "unplaced"
    if home == default_home:
        return "default"
    if home.parent == default_home / "profiles" and BOT_NAME.match(home.name) and home.name != "unplaced":
        return home.name
    return "unplaced"


def _child_kind(frame):
    for _ in range(80):
        if frame is None:
            break
        module = str(frame.f_globals.get("__name__") or "")
        for prefix, kind in CHILD_KINDS:
            if module.startswith(prefix) or (prefix in ("nollie_reader", "nollie-reader", "claude") and prefix in module):
                return kind
        frame = frame.f_back
    return "program"


def _label_door(environ=os.environ, bot=None):
    """Label this process's own requests and every child it starts. Returns False without a door."""
    door = _door(environ)
    if door is None:
        return False
    secret, port = door
    unplaced = f"http://unplaced.program:{secret}@127.0.0.1:{port}"
    default_home = Path(environ.get("HERMES_HOME") or ".").absolute()

    def current_bot():
        if bot is not None:
            return bot()
        try:
            from hermes_constants import get_hermes_home
            return _bot_of(get_hermes_home(), default_home)
        except Exception:
            return "unplaced"

    def url(kind):
        return f"http://{current_bot()}.{kind}:{secret}@127.0.0.1:{port}"

    original_proxies = urllib.request.getproxies_environment

    @functools.wraps(original_proxies)
    def proxies_environment():
        # Read at each request (requests, urllib, aiohttp) or client (httpx): the bot whose work it is now.
        found = original_proxies()
        if not any(value == unplaced for value in found.values()):
            return found
        label = url("hermes")
        return {scheme: label if value == unplaced else value for scheme, value in found.items()}

    urllib.request.getproxies_environment = proxies_environment

    original_child = subprocess.Popen._execute_child

    @functools.wraps(original_child)
    def execute_child(self, args, executable, preexec_fn, close_fds, pass_fds, cwd, env, *rest):
        try:
            source = os.environ if env is None else env
            if all(isinstance(key, str) for key in source):
                env = dict(source)
                label = url(_child_kind(sys._getframe(1)))
                for name in PROXY_NAMES:
                    # A proxy the program chose itself is left alone; one Hermes left out is put back.
                    if env.get(name) in (None, "", unplaced):
                        env[name] = label
                env.setdefault("NO_PROXY", DIRECT)
                env.setdefault("no_proxy", DIRECT)
                env.setdefault("NODE_USE_ENV_PROXY", "1")
        except Exception:
            pass
        return original_child(self, args, executable, preexec_fn, close_fds, pass_fds, cwd, env, *rest)

    subprocess.Popen._execute_child = execute_child
    return True


def main(prepare_api=_install_model_inventory_compatibility, prepare_profiles=_prepare_profile_workflow,
         prepare_keys=_install_keychain_source):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--source", required=True)
    parser.add_argument("--role", choices=("api", "gateway"), required=True)
    args = parser.parse_args()
    descriptor = int(os.environ.pop("NOLLIE_OWNER_FD"))
    if descriptor < 3 or not stat.S_ISFIFO(os.fstat(descriptor).st_mode):
        raise SystemExit(78)
    os.set_inheritable(descriptor, False)
    try:
        keys = _read_keys(int(os.environ.pop("NOLLIE_KEYS_FD")))
    except (KeyError, ValueError, OSError):
        raise SystemExit(78) from None

    def owner_watch():
        try:
            while os.read(descriptor, 1):
                pass
        except OSError:
            pass
        # A bounded graceful exit, even if a startup import or shutdown handler stalls.
        timer = threading.Timer(10, lambda: os._exit(75))
        timer.daemon = True
        timer.start()
        os.kill(os.getpid(), signal.SIGTERM)

    threading.Thread(target=owner_watch, daemon=True, name="nollie-owner").start()
    # Before Hermes or any HTTP library is imported, so every client reads the labelled door.
    _label_door()
    sys.path.insert(0, args.source)
    prepare_keys(args.source, keys)
    prepare_profiles(args.source, keys)
    if args.role == "api":
        prepare_api(args.source)
        command = ["serve", "--host", "127.0.0.1", "--port", "0", "--isolated"]
    else:
        command = ["gateway", "run", "--external-supervisor"]
    sys.argv = ["hermes", "--profile", "default", *command]
    runpy.run_module("hermes_cli.main", run_name="__main__", alter_sys=True)


if __name__ == "__main__":
    main()
