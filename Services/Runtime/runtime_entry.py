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
    "agent/models_dev.py": "13b873684a16fe8c67149071ca7ab3a173001476d496e35b0ad27bac65b127d5",
    "hermes_cli/model_catalog.py": "466859b7339c84f88e065baff9872108a04e93e7f26f632d233e066afd06c627",
    "hermes_cli/model_switch_providers.py": "54b1eb1984487a7dd0c6da07f35401c6d4abdeaaf9cf916ddcc5f7a1ab48d24f",
    "hermes_cli/inventory.py": "e752a4a0f0f292878ab39c9791d12705dac5d6d7b6b08dd1bc5d47886b3b4235",
}


MODEL_PROBE_SOURCE_HASHES = {
    'hermes_cli/web_routers/local_models.py': 'ca7335f1022547241ba4f3cf301dd0fbb992fbf66f7e2974ec284590fb9f60b3',
    'hermes_cli/local_runtime/endpoint.py': '92263833b5b107e2ac11405328fdc3b31a94f97052ba1f8e56e6e710ed0a1406',
    'hermes_cli/local_runtime/recovery.py': '8446fb9e257d8461a84859592c6bc9940cce39315635c03ca7a9b9136679fb2f',
    'hermes_cli/local_runtime/bootstrap.py': '64df9225e84ce1c0bcfef8575f4336bc9bdaa57ea9b2b949d1700bcd82eb33bd',
    'hermes_cli/web_server.py': '450289d43bb48e0df8906881ca4760fc8e4d92cf6e9b63e8fc5890a7231ce047',
}

PROFILE_SOURCE_HASHES = {
    "hermes_cli/profiles.py": "88112265f41b1393cc518f74856488d22af88fad11600330f2f83ee9d990a19c",
    "hermes_cli/profiles_initialization.py": "31f2d005acf3f01b4e8997855b7a6dea35e11c017cedc686116ace631d2dd59e",
    "tui_gateway/methods_profiles.py": "646041d3d812d71d5db718b33bf5d5cb0d98a5e9e15ccc18894368982aeed511",
    "hermes_cli/web_routers/profiles.py": "9f9dfead957a023ac4e76af0c43050dcb66b00547ee9baf64122fc779ae25c50",
    "hermes_constants.py": "74d849629c176703d48f9aa43a245fd8819545ac908c805e347db7d691976510",
}

KEY_SOURCE_HASHES = {
    "hermes_cli/env_loader.py": "b4ba716b5e9d73ccbbc16f507b366ffad0c02bbf12d164568ca32461bf858e11",
    "agent/secret_sources/registry.py": "01048f385823494590b8868d1b70136bf943af336e0ce77041f96677cd124424",
    "agent/secret_sources/base.py": "49b39c137a57691030966101313becfb455b6ea5f89d160808ff3bee601b3cee",
    "agent/secret_scope.py": "b1e9033c6b456e517a31ea3115da9f90475f535fd87d64ceece9b14b241e105f",
    "hermes_cli/profile_channels.py": "06bc290992c2a2ae8ebb822dcd4fd5815bcfcc996c8ac739ede0f12900f44862",
}

KEY_SOURCE = "nollie_keychain"
# Names Hermes 0.23 reads only from the process environment (plugins/config_backends/remote/credentials.py).
NEVER_FROM_KEYCHAIN = frozenset({"HERMES_CONFIG_BACKEND", "HERMES_CONFIG_REMOTE_URL", "HERMES_CONFIG_INSTANCE_ID"})
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
            # Hermes refuses to start when a secret source names its config backend or plane credentials.
            found = own(home_path)
            return base.FetchResult(secrets={name: value for name, value in found.items()
                                             if name not in NEVER_FROM_KEYCHAIN and not name.startswith("HERMES_CONFIG_")})

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
        # A full copy brings the source's own note along; this copy's note says only what it took.
        copied = Path(folder) / CLONE_NOTE
        try:
            if stat.S_ISREG(os.lstat(copied).st_mode):
                os.unlink(copied)
        except FileNotFoundError:
            pass
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


def _current_home():
    from hermes_constants import get_hermes_home
    return Path(get_hermes_home())


def _scope_profile_workflow(profiles, layout, addons, home, clone_keys=None, current_home=None):
    """Finish Ask first inside Hermes's hidden staging folder, before a bot can be served.

    ``layout`` is ``hermes_cli.profiles_initialization``: ``create_profile`` imports its
    ``finish_profile_layout`` when it runs, so the wrapped one is the one it calls."""
    if hasattr(profiles, "finish_profile_layout") or hasattr(profiles, "_finish_profile_layout"):
        raise SystemExit(78)  # a copy bound at import would skip the wrapped step
    original_create = profiles.create_profile
    original_finish = layout.finish_profile_layout
    original_import = profiles.import_profile
    original_export = profiles.export_profile
    original_rename = profiles.rename_profile
    creating = contextvars.ContextVar("nollie_creating_profile", default=None)

    def require_public(name):
        policy, private = addons.workflow_privacy(home / "plugins" / addons.WORKFLOW, home)
        if policy.excluded(name, private):
            raise ValueError("Private bots cannot be copied or created here.")

    def require_public_chat():
        # Hermes's chat screen copies the open chat's bot's .env and sign-ins into a bot made there
        # (tui_gateway/methods_profiles.py, _mirror_launch_credentials), after the bot is created.
        if current_home is None:
            return
        try:
            bound = Path(current_home()).absolute()
        except Exception:
            raise ValueError("The new bot's setup could not be checked.") from None
        if bound == home:
            return
        if bound.parent != home / "profiles":
            raise ValueError("The new bot's setup could not be checked.")
        require_public(profiles._canon_valid(bound.name))

    @functools.wraps(original_create)
    def create(name, *args, **kwargs):
        canon = profiles._canon_valid(name)
        require_public(canon)
        require_public_chat()
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

    @functools.wraps(original_import)
    def import_bot(archive_path, name=None, *args, **kwargs):
        # Nollie restores its own archives under a name it gives; an import that names itself
        # from inside the archive could be a private bot's copy.
        if not name:
            raise ValueError("Name the bot to import.")
        canon = profiles._canon_valid(name)
        require_public(canon)
        path = original_import(archive_path, name, *args, **kwargs)
        addons.ensure_profile_workflow(home, canon, Path(path))
        return path

    @functools.wraps(original_export)
    def export_bot(name, *args, **kwargs):
        require_public(profiles._canon_valid(name))
        return original_export(name, *args, **kwargs)

    @functools.wraps(original_rename)
    def rename_bot(old_name, new_name, *args, **kwargs):
        require_public(profiles._canon_valid(old_name))
        if (new_name or "").strip():
            require_public(profiles._canon_valid(new_name))
        return original_rename(old_name, new_name, *args, **kwargs)

    profiles.create_profile = create
    profiles.import_profile = import_bot
    profiles.export_profile = export_bot
    profiles.rename_profile = rename_bot
    layout.finish_profile_layout = finish


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
    from hermes_cli import profiles, profiles_initialization
    root = Path(source).resolve(strict=True)
    for module, relative in ((profiles, "hermes_cli/profiles.py"),
                             (profiles_initialization, "hermes_cli/profiles_initialization.py")):
        if Path(module.__file__).resolve(strict=True) != root / relative:
            raise SystemExit(78)
    _scope_profile_workflow(profiles, profiles_initialization, addons, home, _note_cloned_keys(keys, home),
                            current_home=_current_home)


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
