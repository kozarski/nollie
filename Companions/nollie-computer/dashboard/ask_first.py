"""A per-bot Ask first switch, available even while the workflow add-on is off."""
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import tempfile

WORKFLOW = "nollie-workflow"
MARKER = "ask-first-initialized"
PROFILE_NAME = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")


class Refused(Exception):
    def __init__(self, status, message):
        self.status = status
        super().__init__(message)


def profile_home(profile):
    from hermes_cli.profiles import get_profile_dir, profile_exists
    if not profile_exists(profile):
        raise Refused(404, "There is no such bot.")
    return Path(get_profile_dir(profile))


def refresh_plugin(profile, home, enabled):
    from hermes_cli.plugins_activation import activate_plugin_now
    from hermes_cli.web_server_profiles import _config_profile_scope
    from hermes_constants import get_hermes_home
    with _config_profile_scope(profile):
        if Path(get_hermes_home()).resolve() != home.resolve():
            raise Refused(503, "Ask first could not be changed for this bot.")
        result = activate_plugin_now(WORKFLOW)
    activation = result.get("activation") or {}
    hooks = activation.get("activated_now", {}).get("hooks", [])
    if enabled and ("pre_tool_call" not in hooks or result.get("gateway_reloaded") is not True):
        raise Refused(503, "Ask first is saved, but could not start. Try again in a moment.")


def unlinked(path, root):
    path, root = Path(path), Path(root)
    if not path.is_relative_to(root):
        return False
    while True:
        if path.is_symlink():
            return False
        if path == root:
            return True
        path = path.parent


def read_config(path):
    original = path.read_bytes()
    try:
        document, yaml = json.loads(original), None
    except ValueError:
        from ruamel.yaml import YAML
        yaml = YAML()
        yaml.preserve_quotes = True
        document = yaml.load(original.decode("utf-8"))
    if not isinstance(document, dict):
        raise ValueError("config must be a mapping")
    plugins = document.get("plugins", {})
    if not isinstance(plugins, dict):
        raise ValueError("plugins must be a mapping")
    enabled, disabled = plugins.get("enabled", []), plugins.get("disabled", [])
    if not all(isinstance(values, list) and all(isinstance(value, str) for value in values)
               for values in (enabled, disabled)):
        raise ValueError("plugin selections must be lists")
    return document, yaml


def matches(name):
    return name.rsplit("/", 1)[-1] == WORKFLOW


def is_enabled(document):
    plugins = document.get("plugins", {})
    return (any(matches(name) for name in plugins.get("enabled", []))
            and not any(matches(name) for name in plugins.get("disabled", [])))


def atomic_write(path, write):
    descriptor, temporary = tempfile.mkstemp(prefix=".ask-first-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as handle:
            os.fchmod(handle.fileno(), 0o600)
            write(handle)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class AskFirst:
    def __init__(self, main_home, private_reader, home_for=profile_home, refresh=refresh_plugin):
        self.main_home, self.private_reader = main_home, private_reader
        self.home_for, self.refresh = home_for, refresh

    def _home(self, profile):
        if not isinstance(profile, str) or not PROFILE_NAME.fullmatch(profile):
            raise Refused(422, "Choose a bot first.")
        try:
            private = self.private_reader() | {"private", "moss"}
        except Exception:
            raise Refused(503, "The Private list cannot be read.") from None
        if ({profile} | set(re.split(r"[^a-z0-9]+", profile))) & private:
            raise Refused(403, "Ask first is not changed for private bots.")
        root, home = Path(self.main_home()), Path(self.home_for(profile))
        expected = root if profile == "default" else root / "profiles" / profile
        if home != expected or not unlinked(home / "config.yaml", root) or not home.is_dir():
            raise Refused(503, "This bot's settings cannot be read.")
        return root, home

    def status(self, profile):
        _, home = self._home(profile)
        try:
            document, _ = read_config(home / "config.yaml")
        except Exception:
            raise Refused(503, "Ask first cannot be read right now.") from None
        return {"profile": profile, "enabled": is_enabled(document)}

    @contextmanager
    def _locked(self, root, home):
        state = home / WORKFLOW
        marker = state / MARKER
        if not unlinked(marker, root):
            raise ValueError("linked Ask first state")
        state.mkdir(mode=0o700, exist_ok=True)
        # Managed setup/startup takes this same lock before its one-time default.
        lock = root.parent / ".nollie-addons.lock" if root.name == "home" else state / "ask-first.lock"
        descriptor = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            if (not unlinked(marker, root)
                    or marker.exists() and (not marker.is_file() or marker.read_text() != "1\n")):
                raise ValueError("invalid Ask first marker")
            yield marker
        finally:
            os.close(descriptor)

    def change(self, profile, enabled):
        if type(enabled) is not bool:
            raise Refused(422, "Choose on or off for Ask first.")
        root, home = self._home(profile)
        try:
            with self._locked(root, home) as marker:
                self._home(profile)
                config = home / "config.yaml"
                document, yaml = read_config(config)
                plugins = document.setdefault("plugins", {})
                on = [name for name in plugins.get("enabled", []) if not matches(name)]
                off = [name for name in plugins.get("disabled", []) if not matches(name)]
                (on if enabled else off).append(WORKFLOW)
                if on != plugins.get("enabled", []) or off != plugins.get("disabled", []):
                    plugins.update(enabled=on, disabled=off)
                    def write(handle):
                        if yaml is None:
                            json.dump(document, handle, indent=2)
                            handle.write("\n")
                        else:
                            yaml.dump(document, handle)
                    atomic_write(config, write)
                if not marker.exists():
                    atomic_write(marker, lambda handle: handle.write("1\n"))
                try:
                    self.refresh(profile, home, enabled)
                except Refused:
                    raise
                except Exception:
                    raise Refused(503, "Ask first is saved, but could not be updated. Try again in a moment.") from None
                return self.status(profile)
        except Refused:
            raise
        except Exception:
            raise Refused(503, "Ask first could not be saved. Try again in a moment.") from None
