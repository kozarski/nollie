#!/usr/bin/env python3
"""Install a stopped companion with dated backups; activation is separate.

--papertrail-bots also copies the add-on into those bots so Papertrail records there; --recorder
copies it into every followed bot for the Night shift recorder. A bot that gets the recorder but is
not named in --papertrail-bots gets a ``recorder-only`` marker in its copy, so Papertrail stays off
there. Only the default bot runs Board follow-through. Private bots are refused.
"""
import argparse
from datetime import datetime
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

NAME = "nollie-workflow"
RECORDER_ONLY = "recorder-only"  # In a bot's copy: the recorder loads there, Papertrail does not.
IGNORED = shutil.ignore_patterns("tests", "__pycache__", "*.pyc", RECORDER_ONLY)


def backup(source, target):
    shutil.copy2(source, target)
    target.chmod(0o600)
    if hashlib.sha256(source.read_bytes()).digest() != hashlib.sha256(target.read_bytes()).digest():
        raise RuntimeError("backup verification failed")


def load_package(source):
    name = "nollie_workflow_installer_source"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, source / "__init__.py",
                                                      submodule_search_locations=[str(source)])
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return (__import__(name + ".private_bots", fromlist=["read"]),
            __import__(name + ".workflow_core", fromlist=["private_identity"]))


def papertrail_bots(value, source, home):
    """(name, home) for each named bot; refuses private, unknown and malformed names."""
    private_bots, core = load_package(source)
    try:
        private = private_bots.read(home)[0] | private_bots.carried_over_names()
    except (OSError, ValueError):
        raise SystemExit("The Private list cannot be read, so no other bot was chosen.") from None
    bots = []
    for raw in (value or "").split(","):
        name = raw.strip().lower()
        if not name or name == "default" or name in (bot for bot, _ in bots):
            continue
        if not private_bots.PROFILE_NAME.match(name):
            raise SystemExit(f"Not a Hermes profile name: {name}")
        if core.private_identity(name, private):
            raise SystemExit(f"Papertrail is never kept for private bots, so {name} was refused.")
        profile_home = home / "profiles" / name
        if profile_home.is_symlink() or not profile_home.is_dir():
            raise SystemExit(f"No such bot: {name}")
        bots.append((name, profile_home))
    return bots


def copy_into(source, profile_home, stamp, *, recorder_only=False):
    """Copy the add-on into a bot. ``recorder_only`` marks the copy so Papertrail stays off there."""
    target = profile_home / "plugins" / NAME
    if target.is_symlink() or (profile_home / "plugins").is_symlink():
        raise SystemExit(f"Refusing a linked plugin folder in {profile_home}.")
    if (profile_home / "config.yaml").exists():
        backup(profile_home / "config.yaml", profile_home / f"config.yaml.bak-{NAME}-{stamp}")
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f"{NAME}-stage-", dir=target.parent) as temporary:
        staged = Path(temporary) / NAME
        shutil.copytree(source, staged, ignore=IGNORED)
        if recorder_only:
            marker = os.open(staged / RECORDER_ONLY, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(marker, "w") as handle:
                handle.write("Papertrail is off in this bot. A copy made with --papertrail-bots turns it on.\n")
            (staged / RECORDER_ONLY).chmod(0o600)
        if target.exists():
            old = profile_home / "plugin-backups" / f"{NAME}-{stamp}"
            old.parent.mkdir(parents=True, exist_ok=True)
            target.rename(old)
            print(f"Previous plugin backed up: {old}")
        staged.rename(target)
    return target


def followed_profiles(source, home):
    """Named profiles that get the recorder: none that names a Private bot, never private or moss."""
    private_bots, _ = load_package(source)
    private = private_bots.read(home)[0] | private_bots.carried_over_names()  # Damaged: raises, no recorder.
    folder = home / "profiles"
    if not folder.is_dir() or folder.is_symlink():
        return []
    names = []
    for entry in sorted(folder.iterdir()):
        name = entry.name
        if (entry.is_dir() and not entry.is_symlink() and private_bots.PROFILE_NAME.match(name)
                and (entry / "config.yaml").is_file() and not private_bots.excluded(name, private)):
            names.append(name)
    return names


def stage(source, target, backups):
    """Copy the add-on into place, moving any previous copy to the dated backups."""
    if target.is_symlink() or target.parent.is_symlink():
        raise SystemExit("Refusing a symlink destination.")
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="nollie-workflow-stage-", dir=target.parent) as temporary:
        staged = Path(temporary) / "nollie-workflow"
        shutil.copytree(source, staged, ignore=IGNORED)
        if target.exists():
            backups.parent.mkdir(parents=True, exist_ok=True)
            target.rename(backups)
            print(f"Previous plugin backed up: {backups}")
        staged.rename(target)


def install_recorders(source, home, stamp, skip=()):
    """Copy the add-on into each followed profile and enable it there; returns their names.

    ``skip`` holds the bots that just got a Papertrail copy. Every other one gets a recorder-only copy,
    unless it already has Papertrail: an upgrade never turns Papertrail off.
    """
    profiles = followed_profiles(source, home)
    hermes = shutil.which("hermes")
    for profile in profiles:
        if profile not in skip:
            installed = home / "profiles" / profile / "plugins" / NAME
            keeps = installed.is_dir() and not (installed / RECORDER_ONLY).exists()
            target = copy_into(source, home / "profiles" / profile, stamp, recorder_only=not keeps)
            print(f"Recorder installed for {profile}, Papertrail {'kept on' if keeps else 'off'}: {target}")
        if not hermes:
            print("Hermes is not on PATH, so the recorder was not enabled there.")
            continue
        result = subprocess.run([hermes, "--profile", profile, "plugins", "enable", NAME], capture_output=True, text=True)
        if result.returncode:
            print(f"Hermes enable for {profile} returned {result.returncode}.")
        else:
            print(f"Recorder enabled for {profile}.")
    return profiles


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--enable", action="store_true", help="enable the stopped plugin using Hermes")
    parser.add_argument("--papertrail-bots", default="", metavar="A,B,C",
                        help="also copy the add-on into these bots so Papertrail records there")
    parser.add_argument("--recorder", action="store_true",
                        help="also install and enable the Night shift recorder in each followed profile")
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    home = Path.home() / ".hermes"
    private_bots, _ = load_package(source)
    try:
        private = private_bots.names(home)
    except (OSError, ValueError):
        raise SystemExit("The Private list cannot be read, so nothing was installed.") from None
    if private_bots.excluded("default", private):
        raise SystemExit("The main bot is Private, so nothing was installed.")
    target = home / "plugins" / "nollie-workflow"
    bots = papertrail_bots(args.papertrail_bots, source, home) if args.papertrail_bots else []
    print(f"Install {target}; keep observation stopped until control.py activate.")
    for name, profile_home in bots:
        print(f"Papertrail for {name}: {profile_home / 'plugins' / NAME}")
    if args.recorder:
        try:
            names = followed_profiles(source, home)
        except ValueError:
            raise SystemExit("The Private list is damaged. Repair it before installing the recorder.")
        print("Recorder for: " + (", ".join(names) if names else "no other profile") + ". Never a private one.")
        chosen = {name for name, _ in bots}
        has = {name for name in names if (home / "profiles" / name / "plugins" / NAME).is_dir()
               and not (home / "profiles" / name / "plugins" / NAME / RECORDER_ONLY).exists()}
        only = [name for name in names if name not in chosen and name not in has]
        both = [name for name in names if name in chosen or name in has]
        print("Recorder only, Papertrail off: " + (", ".join(only) if only else "none") + ".")
        print("Recorder and Papertrail: " + (", ".join(both) if both else "none") + ".")
    if not args.apply:
        print("Plan only. --apply writes files; --enable asks Hermes to load the stopped companion; "
              "--recorder also installs and enables the recorder in each followed profile.")
        return
    if target.is_symlink() or (home / "nollie-workflow").is_symlink():
        raise SystemExit("Refusing a symlink destination.")
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    if (home / "config.yaml").exists():
        backup(home / "config.yaml", home / ("config.yaml.bak-nollie-workflow-" + stamp))
    stage(source, target, home / "plugin-backups" / ("nollie-workflow-" + stamp))
    spec = importlib.util.spec_from_file_location("nollie_workflow_install_core", target / "workflow_core.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    root = home / "nollie-workflow"
    with module.file_lock(root / "state.lock"):
        if (root / "state.json").exists():
            backup(root / "state.json", root / ("state.json.bak-install-" + stamp))
            state = module.read_state(root)
            state["enabled"] = False
        else:
            state = module.initial_state()
        module.atomic_write(root / "state.json", state)
    for name, profile_home in bots:
        print(f"Papertrail copy installed for {name}: {copy_into(source, profile_home, stamp)}")
    if args.enable:
        hermes = shutil.which("hermes")
        if not hermes:
            raise SystemExit("Files installed, stopped. Hermes is not on PATH.")
        result = subprocess.run([hermes, "--profile", "default", "plugins", "enable", "nollie-workflow"],
                                capture_output=True, text=True)
        if result.returncode:
            raise SystemExit(f"Files installed, stopped. Hermes enable returned {result.returncode}.")
        for name, _ in bots:
            result = subprocess.run([hermes, "--profile", name, "plugins", "enable", NAME],
                                    capture_output=True, text=True)
            if result.returncode:
                raise SystemExit(f"Files installed, stopped. Enabling for {name} returned {result.returncode}.")
            print(f"Papertrail enabled for {name}.")
        print("Plugin enabled. Restart the gateway and the dashboard so Nollie's own bot records Papertrail"
              " and the Papertrail route answers; an add-on already loaded is not reloaded.")
    if args.recorder:
        try:
            install_recorders(source, home, stamp, skip={name for name, _ in bots})
        except ValueError:
            raise SystemExit("The Private list is damaged. Repair it before installing the recorder.")
    print("Installed, stopped. Use the installed control.py to inspect status, activate, or pause.")


if __name__ == "__main__":
    main()
