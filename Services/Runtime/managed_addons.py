"""Install Nollie's own Hermes add-ons into a managed setup, as part of its one setup consent.

Run by the Mac app with the managed environment's Python (-I -B), from the app's signed Setup Kit:

    python -I -B managed_addons.py --kit <Setup Kit/add-ons> --installation <managed setup>
                                   --uv <setup>/uv/uv --python <Nollie's Python>

Every carried file is checked against kit.json before it is copied. An add-on that is already
current is left alone; an older copy moves to <home>/plugin-backups/<name>-<time> first. The
page reader gets its own environment from a hash-locked requirements file (wheels only). The
add-ons are then listed in Hermes's plugins.enabled, with a dated backup of config.yaml. Ask first
is on in every bot, Private ones too, and stays on: the person's Ask first switch is its own file
(nollie-workflow/ask-first.json) and covers only what Nollie can't read, so an add-on an older Nollie
switched off comes back on with that switch off. Every bot's use of this Mac starts off: a bot with
no desktop lease gets a person's (bot-desktop/lease.json), since Hermes reads no lease as the bot's.
Other disabled add-ons stay disabled. Board follow-through starts on the first install only.
Workflow's Hermes helpers stay inside its plugin folder; this installer never writes Hermes source.
Never touches ~/.hermes, the always-private bots (private, moss), chats, schedules or the Board; a
Private bot gets only Ask first and the lease, and nothing in it is read but its config.yaml.
"""
import argparse
from datetime import datetime
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys
import tempfile
import time

READER = "nollie-reader"
WORKFLOW = "nollie-workflow"
WORKFLOW_INITIALIZED = "ask-first-initialized"
MARKER = "nollie-lock.sha256"
RECORDER_ONLY = "recorder-only"
RECORDER_NOTE = "Papertrail is off in this bot. A copy made with --papertrail-bots turns it on.\n"
SWITCH = "ask-first.json"
LEASE_REASON = "System control is off in the Nollie app"


class Refused(Exception):
    """A check failed; nothing after it ran."""


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def safe_relative(path):
    parts = path.split("/")
    return (bool(path) and not path.startswith("/") and "\\" not in path and len(path) < 512
            and all(part not in ("", ".", "..") for part in parts)
            and not any(ord(c) < 0x20 or ord(c) == 0x7F for c in path))


TRUSTED = None  # The installation folder; the app checked it and everything above it.


def unlinked(path):
    """True when no part of path below the installation folder is a symbolic link."""
    path = Path(path)
    for part in [path, *path.parents]:
        if TRUSTED is not None and part == TRUSTED:
            return True
        if part.is_symlink():
            return False
    return TRUSTED is None


def load_kit(kit):
    data = json.loads((kit / "kit.json").read_bytes())
    if data.get("schema") != 1 or not data.get("items"):
        raise Refused("unknown kit layout")
    for item in data["items"]:
        name = item["name"]
        if not name.startswith("nollie-") or not name[7:].isalpha():
            raise Refused(f"unexpected add-on name {name!r}")
        for entry in item["files"]:
            path = entry["path"]
            source = kit / path
            if (not safe_relative(path) or not path.startswith(name + "/") or source.is_symlink()
                    or not source.is_file() or source.stat().st_size != entry["bytes"] or sha256(source) != entry["sha256"]):
                raise Refused(f"{path} does not match the kit")
    lock = data["readerLock"]
    if sha256(kit / lock["path"]) != lock["sha256"]:
        raise Refused("the reader's lockfile does not match the kit")
    return data


def current(target, files, name, recorder_only=False):
    """True when the installed copy holds exactly the carried files, byte for byte (caches aside)."""
    if not target.is_dir() or target.is_symlink():
        return False
    present = {path.relative_to(target).as_posix() for path in target.rglob("*")
               if "__pycache__" not in path.relative_to(target).parts and not path.is_dir()}
    expected = {entry["path"][len(name) + 1:] for entry in files}
    if recorder_only:
        expected.add(RECORDER_ONLY)
    if present != expected:
        return False
    if recorder_only and ((target / RECORDER_ONLY).is_symlink()
                          or (target / RECORDER_ONLY).read_text() != RECORDER_NOTE):
        return False
    for entry in files:
        path = target / entry["path"][len(name) + 1:]
        if path.is_symlink() or not path.is_file() or sha256(path) != entry["sha256"]:
            return False
    return True


def install_addon(kit, home, item, stamp, recorder_only=False):
    name = item["name"]
    plugins = home / "plugins"
    target = plugins / name
    if not unlinked(target) or (plugins.exists() and not plugins.is_dir()):
        raise Refused(f"refusing a linked plugin folder for {name}")
    if current(target, item["files"], name, recorder_only):
        return "current"
    plugins.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f".{name}-stage-", dir=plugins) as temporary:
        staged = Path(temporary) / name
        for entry in item["files"]:
            destination = staged / entry["path"][len(name) + 1:]
            destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            shutil.copyfile(kit / entry["path"], destination)
            destination.chmod(0o600)
            if sha256(destination) != entry["sha256"]:
                raise Refused(f"{entry['path']} changed while it was copied")
        if recorder_only:
            (staged / RECORDER_ONLY).write_text(RECORDER_NOTE)
            (staged / RECORDER_ONLY).chmod(0o600)
        outcome = "installed"
        if target.exists():
            backups = home / "plugin-backups"
            if not unlinked(backups):
                raise Refused("refusing a linked plugin backup folder")
            backups.mkdir(mode=0o700, parents=True, exist_ok=True)
            target.rename(backups / f"{name}-{stamp}")
            outcome = "updated"
        staged.rename(target)
    return outcome


def load_module(name, path, package=None):
    spec = importlib.util.spec_from_file_location(name, path, submodule_search_locations=package)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def start_workflow(home):
    """First install only: create the state with observation on. A later run keeps the person's choice."""
    core = load_module("nollie_managed_workflow_core", home / "plugins" / WORKFLOW / "workflow_core.py")
    root = home / WORKFLOW
    if root.is_symlink():
        raise Refused("refusing a linked workflow state folder")
    with core.file_lock(root / "state.lock"):
        if (root / "state.json").exists():
            core.read_state(root)  # A damaged state is kept for repair, never replaced.
            return "kept"
        state = core.initial_state()
        state["enabled"] = True
        core.atomic_write(root / "state.json", state)
    return "started"


def reader_environment(kit, home, uv, python, lock_entry, stamp, run=None):
    """Build the reader's hash-locked environment beside the old one and swap it in when it works."""
    run = run or subprocess.run
    state = home / READER
    if not unlinked(state):
        raise Refused("refusing a linked reader state folder")
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    venv = state / "venv"
    marker = venv / MARKER
    if marker.is_file() and not marker.is_symlink() and marker.read_text() == lock_entry["sha256"] + "\n":
        return "current"
    for leftover in state.glob("venv.new-*"):
        if leftover.is_dir() and not leftover.is_symlink():
            shutil.rmtree(leftover)  # An earlier attempt that stopped part way.
    fresh = state / f"venv.new-{stamp}"
    # Wheels only (--no-build), every one checked against the lock's hashes.
    steps = [[str(uv), "--no-config", "venv", "--quiet", "--python", str(python), str(fresh)],
             [str(uv), "--no-config", "pip", "install", "--quiet", "--python", str(fresh / "bin" / "python"),
              "--require-hashes", "--no-build", "-r", str(kit / lock_entry["path"])],
             [str(fresh / "bin" / "python"), "-I", "-B", "-c", "import trafilatura, pypdf"]]
    for step in steps:
        result = run(step, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if result.returncode:
            shutil.rmtree(fresh, ignore_errors=True)
            # Diagnostics stay in the process output, which the app never shows.
            raise Refused("the reader's environment did not build: " + (result.stdout or "")[-2000:])
    (fresh / MARKER).write_text(lock_entry["sha256"] + "\n")
    (fresh / MARKER).chmod(0o600)
    previous = state / "venv.previous"
    if venv.exists():
        if previous.exists():
            shutil.rmtree(previous)  # Rebuildable; one older copy is enough to go back to.
        venv.rename(previous)
    fresh.rename(venv)
    return "built"


def enable(home, names, stamp, required=(), create=False):
    """List the add-ons in plugins.enabled. Returns the names newly listed."""
    config = home / "config.yaml"
    if not unlinked(config) or (not config.is_file() and not (create and not config.exists())):
        raise Refused("the setup's config.yaml is missing or linked")
    original = config.read_bytes() if config.exists() else None
    text = original.decode("utf-8") if original is not None else "{}"
    try:
        document, style = json.loads(text), "json"
    except ValueError:
        try:
            from ruamel.yaml import YAML
            yaml = YAML()
            yaml.preserve_quotes = True
            document, style = yaml.load(text), "yaml"
        except Exception:
            raise Refused("the setup's config.yaml could not be read") from None
    if not isinstance(document, dict):
        raise Refused("the setup's config.yaml is not a mapping")
    plugins = document.setdefault("plugins", {})
    if not isinstance(plugins, dict):
        raise Refused("plugins in config.yaml is not a mapping")
    enabled = plugins.get("enabled", [])
    disabled = plugins.get("disabled", [])
    if not all(isinstance(value, list) and all(isinstance(name, str) for name in value)
               for value in (enabled, disabled)):
        raise Refused("enabled and disabled plugins must be lists of names")
    kept_disabled = [name for name in disabled if name.rsplit("/", 1)[-1] not in required]
    added = [name for name in names if name not in enabled and name not in kept_disabled]
    if not added and kept_disabled == disabled:
        return []
    if added:
        plugins["enabled"] = list(enabled) + added
    if kept_disabled != disabled:
        plugins["disabled"] = kept_disabled
    if original is not None:
        backup = home / f"config.yaml.bak-nollie-addons-{stamp}"
        descriptor = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(original)
        if backup.read_bytes() != original:
            raise Refused("the config backup did not verify")
    descriptor, temporary = tempfile.mkstemp(prefix=".config-", dir=home)
    with os.fdopen(descriptor, "w") as handle:
        os.fchmod(handle.fileno(), 0o600)
        if style == "json":
            json.dump(document, handle, indent=2)
            handle.write("\n")
        else:
            from ruamel.yaml import YAML
            YAML().dump(document, handle)
    os.replace(temporary, config)
    return added + [name for name in required if name not in added
                    and any(value.rsplit("/", 1)[-1] == name for value in disabled)]


def workflow_privacy(source, home):
    """Use the add-on's Private list rules before looking inside any bot."""
    if source.is_symlink() or not source.is_dir():
        raise Refused("Ask first is missing or linked")
    name = "nollie_managed_workflow"
    for relative in ("__init__.py", "workflow_core.py", "private_bots.py"):
        if (source / relative).is_symlink() or not (source / relative).is_file():
            raise Refused("Ask first is incomplete or linked")
    load_module(name, source / "__init__.py", [str(source)])
    load_module(name + ".workflow_core", source / "workflow_core.py")
    policy = load_module(name + ".private_bots", source / "private_bots.py")
    return policy, policy.read(home)[0] | policy.carried_over_names()


def workflow_item(source):
    files = []
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if "__pycache__" in relative.parts or "tests" in relative.parts or path.suffix == ".pyc":
            continue
        if path.is_symlink():
            raise Refused("Ask first contains a linked file")
        if path.is_file() and relative.as_posix() != RECORDER_ONLY:
            files.append({"path": f"{WORKFLOW}/{relative.as_posix()}",
                          "bytes": path.stat().st_size, "sha256": sha256(path)})
    return {"name": WORKFLOW, "files": files}


def workflow_profiles(home, policy, private):
    """Every bot Ask first covers: all of them, Private ones included, but never the always-private names."""
    always = policy.carried_over_names()
    profiles = [] if policy.excluded("default", always) else [("default", home)]
    folder = home / "profiles"
    if not unlinked(folder):
        raise Refused("refusing a linked profiles folder")
    if folder.is_dir():
        for path in sorted(folder.iterdir()):
            if not policy.PROFILE_NAME.fullmatch(path.name) or policy.excluded(path.name, always):
                continue
            if not unlinked(path):
                raise Refused("refusing a linked bot folder")
            if not unlinked(path / "config.yaml"):
                raise Refused("refusing a linked bot config")
            if path.is_dir() and any((path / marker).exists()
                                     for marker in ("config.yaml", ".env", "SOUL.md", "profile.yaml")):
                profiles.append((path.name, path))
    return profiles


def workflow_initialized(home):
    root = home / WORKFLOW
    marker = root / WORKFLOW_INITIALIZED
    if not unlinked(marker) or (root.exists() and not root.is_dir()):
        raise Refused("refusing a linked or invalid Ask first state folder")
    if not marker.exists():
        return False
    if not marker.is_file() or marker.read_text() != "1\n":
        raise Refused("the Ask first setup marker needs repair")
    return True


def mark_workflow_initialized(home):
    if workflow_initialized(home):
        return
    root = home / WORKFLOW
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(root / WORKFLOW_INITIALIZED, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        handle.write("1\n")


def keep_ask_first_on(home, stamp):
    """An add-on switched off by an older Nollie's Ask first switch comes back on, with the switch itself off:
    sending, buying, posting and deleting ask whatever it says. Returns the names newly listed. A config that
    can't be read is left as it is, as Hermes will find it."""
    config = home / "config.yaml"
    if not unlinked(config) or not config.is_file():
        return []
    switch = home / WORKFLOW / SWITCH
    if not unlinked(switch):
        raise Refused("refusing a linked Ask first switch")
    try:
        added = enable(home, [WORKFLOW], stamp, required=(WORKFLOW,))
    except (Refused, ValueError):
        return []
    if added and not switch.exists():
        descriptor = os.open(switch, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            json.dump({"version": 1, "enabled": False}, handle)
    return added


def ensure_human_lease(home):
    """A bot with no desktop lease gets a person's, so it can't use this Mac until the person turns This Mac on.
    An existing lease is the person's choice and stays. Returns True when one was written."""
    folder = home / "bot-desktop"
    lease = folder / "lease.json"
    if not unlinked(lease) or os.path.lexists(lease) or (folder.exists() and not folder.is_dir()):
        return False
    folder.mkdir(mode=0o700, exist_ok=True)
    body = {"holder": "human", "viewer_id": "nollie-app", "since": time.time(), "reason": LEASE_REASON, "epoch": 1}
    descriptor = os.open(lease, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        json.dump(body, handle, sort_keys=True)
    return True


def _ensure_workflow(home, source, stamp, policy, private, profiles=None):
    profiles = workflow_profiles(home, policy, private) if profiles is None else profiles
    item = workflow_item(source)
    changed = []
    for profile, profile_home in profiles:
        initialized = workflow_initialized(profile_home) and not profile_home.name.startswith(f".{profile}.staging-")
        copied = "current"
        if profile != "default":
            # Every helper keeps a Papertrail (private ones still never record: the add-on loads only Ask
            # first there), so an older copy's recorder-only marker goes with the update.
            copied = install_addon(source.parent, profile_home, item, stamp)
        if not initialized:
            added = enable(profile_home, [WORKFLOW], stamp, required=(WORKFLOW,),
                           create=profile != "default")
            mark_workflow_initialized(profile_home)
        else:
            added = keep_ask_first_on(profile_home, stamp)
        leased = ensure_human_lease(profile_home)
        if added or copied != "current" or leased:
            changed.append(profile)
    return changed


def ensure_workflow(home, stamp=None, *, profiles=None):
    """Before Hermes starts, cover every managed bot (never the always-private names) without fetching anything."""
    global TRUSTED
    home = Path(home).absolute()
    TRUSTED = home.parent
    if (home.name != "home" or not home.is_dir() or not unlinked(home)
            or home == Path(pwd.getpwuid(os.getuid()).pw_dir) / ".hermes"):
        raise Refused("the managed setup's home is missing or unsafe")
    source = home / "plugins" / WORKFLOW
    if not unlinked(source):
        raise Refused("Ask first is missing or linked")
    lock = os.open(TRUSTED / ".nollie-addons.lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        policy, private = workflow_privacy(source, home)
        if profiles is not None:
            selected = []
            for profile, path in profiles:
                if not policy.PROFILE_NAME.fullmatch(profile):
                    raise Refused("not a Hermes bot name")
                if policy.excluded(profile, private):
                    continue
                path = Path(path).absolute()
                if (path.parent != home / "profiles" or path.name not in (profile, f".{profile}.staging-{os.getpid()}")
                        or not unlinked(path) or not path.is_dir()):
                    raise Refused("the new bot's folder is missing or unsafe")
                selected.append((profile, path))
            profiles = selected
        return _ensure_workflow(home, source, stamp or datetime.now().strftime("%Y%m%d-%H%M%S-%f"),
                                policy, private, profiles)
    finally:
        os.close(lock)


def ensure_profile_workflow(home, profile, profile_home):
    """Cover a newly staged bot before Hermes publishes it to the gateway."""
    return ensure_workflow(home, profiles=[(profile, profile_home)])


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--kit", type=Path, required=True)
    parser.add_argument("--installation", type=Path, required=True)
    parser.add_argument("--uv", type=Path, required=True)
    parser.add_argument("--python", type=Path, required=True)
    args = parser.parse_args(argv)
    global TRUSTED
    TRUSTED = args.installation.absolute()
    home = TRUSTED / "home"
    if os.environ.get("HERMES_HOME") != str(home):
        print("This installer runs only inside the managed setup it was given.", file=sys.stderr)
        return 2
    if not home.is_dir() or not unlinked(home) or home == Path(pwd.getpwuid(os.getuid()).pw_dir) / ".hermes":
        print("The managed setup's home is missing or unsafe.", file=sys.stderr)
        return 2
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    # One installer at a time: the setup screen and the launch-time update may both start one.
    lock = os.open(TRUSTED / ".nollie-addons.lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(lock)
        print("Another add-on update is running.", file=sys.stderr)
        return 3
    try:
        return install_all(args, home, stamp)
    finally:
        os.close(lock)


def install_all(args, home, stamp):
    try:
        kit = load_kit(args.kit)
        names = [item["name"] for item in kit["items"]]
        if WORKFLOW in names:
            policy, private = workflow_privacy(args.kit / WORKFLOW, home)
            if policy.excluded("default", private):
                raise Refused("the main bot is private")
        for item in kit["items"]:
            print(f"{item['name']} {item['version']}: {install_addon(args.kit, home, item, stamp)}")
        if WORKFLOW in names:
            print(f"Board follow-through: {start_workflow(home)}")
        if READER in names:
            print(f"Reader environment: {reader_environment(args.kit, home, args.uv, args.python, kit['readerLock'], stamp)}")
        first_workflow = WORKFLOW in names and not workflow_initialized(home)
        enabled_names = [name for name in names if name != WORKFLOW or first_workflow]
        added = enable(home, enabled_names, stamp, required=(WORKFLOW,) if first_workflow else ())
        if first_workflow:
            mark_workflow_initialized(home)
        print("Listed in plugins.enabled: " + (", ".join(added) if added else "already listed"))
        if WORKFLOW in names:
            _ensure_workflow(home, home / "plugins" / WORKFLOW, stamp, policy, private)
    except (Refused, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Add-ons were not installed: {type(error).__name__}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
