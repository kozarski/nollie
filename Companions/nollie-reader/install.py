#!/usr/bin/env python3
"""Install the reader for every bot except the private one, with dated backups.

Plan only by default. --apply copies the add-on into each bot's plugins folder and creates the
shared state folder. --with-extractors builds the add-on's own Python environment (Trafilatura
and pypdf) beside that state. --enable asks Hermes to load the add-on in each bot. Hermes
config is never edited here; the printed commands do that when Corey is ready.
"""
import argparse
from datetime import datetime
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

NAME = "nollie-reader"
BOT_PROFILES = ("career", "nowhere", "forager")
_PRIVATE = {"private", "moss"}


def backup(source, target):
    shutil.copy2(source, target)
    target.chmod(0o600)
    if hashlib.sha256(source.read_bytes()).digest() != hashlib.sha256(target.read_bytes()).digest():
        raise RuntimeError("backup verification failed")


def is_private(name):
    return bool(set(re.split(r"[^a-z0-9]+", name.lower())) & _PRIVATE)


def bot_homes(home):
    homes = [("default", home)]
    for name in BOT_PROFILES:
        path = home / "profiles" / name
        if path.is_dir() and not is_private(name):
            homes.append((name, path))
    return homes


def install_into(source, profile_home, stamp):
    target = profile_home / "plugins" / NAME
    if target.is_symlink() or (profile_home / "plugins").is_symlink():
        raise SystemExit(f"Refusing a linked plugin folder in {profile_home}.")
    config = profile_home / "config.yaml"
    if config.exists():
        backup(config, profile_home / f"config.yaml.bak-{NAME}-{stamp}")
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f"{NAME}-stage-", dir=target.parent) as temporary:
        staged = Path(temporary) / NAME
        shutil.copytree(source, staged, ignore=shutil.ignore_patterns("tests", "__pycache__", "*.pyc"))
        if target.exists():
            old = profile_home / "plugin-backups" / f"{NAME}-{stamp}"
            old.parent.mkdir(parents=True, exist_ok=True)
            target.rename(old)
            print(f"  previous copy kept at {old}")
        staged.rename(target)
    return target


def build_environment(state, python, requirements, stamp):
    """A fresh environment is built beside the old one and swapped in only when it works."""
    venv, fresh = state / "venv", state / f"venv.new-{stamp}"
    subprocess.run([python, "-m", "venv", str(fresh)], check=True)
    pip = fresh / "bin" / "python"
    subprocess.run([str(pip), "-m", "pip", "install", "--quiet", "--disable-pip-version-check",
                    "--only-binary", ":all:", "--require-hashes", "-r", str(requirements)], check=True)
    check = subprocess.run([str(pip), "-I", "-c", "import trafilatura, pypdf"], capture_output=True)
    if check.returncode:
        shutil.rmtree(fresh, ignore_errors=True)
        raise SystemExit("The reader environment did not import Trafilatura and pypdf; nothing was swapped.")
    if venv.exists():
        venv.rename(state / f"venv.bak-{stamp}")
    fresh.rename(venv)
    return venv


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--with-extractors", action="store_true",
                        help="build the reader's own environment with Trafilatura and pypdf")
    parser.add_argument("--python", default=sys.executable, help="Python used to build that environment")
    parser.add_argument("--enable", action="store_true", help="ask Hermes to load the add-on in each bot")
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    home = Path.home() / ".hermes"
    homes = bot_homes(home)
    state = home / NAME
    print(f"Install {NAME} for: {', '.join(name for name, _ in homes)}. The private bot is never touched.")
    print(f"Shared state: {state}")
    if not args.apply:
        print("Plan only. --apply writes files; --with-extractors builds the reader's Python environment; "
              "--enable asks Hermes to load it.")
        return
    if state.is_symlink():
        raise SystemExit("Refusing a linked state folder.")
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    for name, profile_home in homes:
        target = install_into(source, profile_home, stamp)
        print(f"Installed for {name}: {target}")
    if args.with_extractors:
        venv = build_environment(state, args.python, source / "requirements.txt", stamp)
        print(f"Reader environment ready: {venv}")
    if args.enable:
        hermes = shutil.which("hermes")
        if not hermes:
            raise SystemExit("Files installed. Hermes is not on PATH, so nothing was enabled.")
        for name, _ in homes:
            result = subprocess.run([hermes, "--profile", name, "plugins", "enable", NAME],
                                    capture_output=True, text=True)
            if result.returncode:
                raise SystemExit(f"Files installed. Enabling for {name} returned {result.returncode}.")
            print(f"Enabled for {name}.")
    print("To read pages with it, for each bot:")
    for name, _ in homes:
        print(f"  hermes --profile {name} config set web.extract_backend {NAME}")
        print(f"  hermes --profile {name} config set web.keyless_rescue false")


if __name__ == "__main__":
    main()
