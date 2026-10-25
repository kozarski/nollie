#!/usr/bin/env python3
"""Show the install plan for one bot, or apply it when explicitly asked.

Applying copies the plugin (hook and MCP server) to <Hermes home>/plugins/nollie-mac, keeping a
dated backup of an older copy, and enables the plugin for that bot through Hermes. Adding the MCP
server is Hermes's own interactive step, printed for the person to run. Nothing is restarted.
"""
import argparse
import datetime
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

FILES = ("__init__.py", "plugin.yaml", "server.py")


def plan(profile, target):
    server = target / "server.py"
    return [
        f"Copy {', '.join(FILES)} to {target} (an older copy is kept in plugin-backups).",
        f"Enable with: hermes --profile {profile} plugins enable nollie-mac",
        f"Then add the server (Hermes asks to confirm): hermes --profile {profile} mcp add nollie-mac "
        f"--command /usr/bin/python3 --args -I {server}",
        "No restart, no config edit by this script, and nothing runs on the Mac until the person approves a task in Nollie.",
    ]


def main(argv=None, home=None, run=subprocess.run, which=shutil.which):
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", default="default", help="the bot (Hermes profile) to give the add-on")
    parser.add_argument("--apply", action="store_true", help="copy the files and enable the plugin")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", args.profile):
        parser.error("A Hermes profile name is lowercase letters, digits, - and _.")
    if args.profile == "private":
        parser.error("The private bot stays out of this. Nothing was installed.")
    root = Path(home or Path.home()) / ".hermes"
    hermes_home = root if args.profile == "default" else root / "profiles" / args.profile
    target = hermes_home / "plugins" / "nollie-mac"
    for line in plan(args.profile, target):
        print(line)
    if not args.apply:
        print("Plan only. Pass --apply after approving the installation.")
        return 0
    hermes = which("hermes")
    if not hermes:
        print("Hermes is not on PATH. Nothing was installed.", file=sys.stderr)
        return 1
    if not hermes_home.is_dir() or target.is_symlink():
        print("That bot's Hermes home is missing or unsafe. Nothing was installed.", file=sys.stderr)
        return 1
    source = Path(__file__).resolve().parent
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="nollie-mac-", dir=target.parent) as folder:
        staged = Path(folder) / "nollie-mac"
        staged.mkdir()
        for name in FILES:
            shutil.copy2(source / name, staged / name)
        if target.exists():
            backup = hermes_home / "plugin-backups" / f"nollie-mac-{stamp}"
            backup.parent.mkdir(parents=True, exist_ok=True)
            target.rename(backup)
            print(f"Previous add-on saved at {backup}")
        staged.rename(target)
    result = run([hermes, "--profile", args.profile, "plugins", "enable", "nollie-mac"], capture_output=True, text=True)
    if result.returncode:
        print(f"Files installed; Hermes enable failed (exit {result.returncode}).", file=sys.stderr)
        return 1
    print("Add-on installed and enabled. Add the server with the command above.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
