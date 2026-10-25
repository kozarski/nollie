#!/usr/bin/env python3
"""Show the install plan, or apply it when asked. Backups are dated; nothing restarts."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

PLUGIN = "nollie-crew"
FILES = ("__init__.py", "plugin.yaml", "crew.py", "handoffs.py", "hermes_profiles.py", "policy.py",
         "profiles.py", "store.py", "tools.py", "workflow.py")


def backup(source, target):
    shutil.copy2(source, target)
    target.chmod(0o600)
    if hashlib.sha256(source.read_bytes()).digest() != hashlib.sha256(target.read_bytes()).digest():
        raise RuntimeError("backup verification failed")


def local_model(value):
    provider, separator, model = (value or "").partition(":")
    if not separator or not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,63}", provider) or not model.strip() \
            or len(model) > 200:
        raise argparse.ArgumentTypeError("use PROVIDER:MODEL, for example llamacpp:qwen3-8b")
    return {"provider": provider, "default": model.strip()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true", help="copy the add-on into Hermes")
    parser.add_argument("--enable", action="store_true", help="also enable it for Nollie's profile")
    parser.add_argument("--local-model", type=local_model, metavar="PROVIDER:MODEL",
                        help="the local model new crew members use")
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    home = Path.home() / ".hermes"
    target = home / "plugins" / PLUGIN
    print(f"Copy the crew add-on to {target}, keeping a dated copy of any previous version.")
    print("Back up Hermes's main config before enabling it.")
    if args.local_model:
        print(f"Record {args.local_model['provider']}:{args.local_model['default']} as the crew's local model.")
    print("Enable with: hermes --profile default plugins enable nollie-crew" if args.enable else
          "Files only; Hermes's plugin list stays as it is.")
    print("No profile is created or changed, and no service restarts.")
    if not args.apply:
        print("Plan only. Pass --apply after approving the installation.")
        return
    for path in (target, home / "nollie-crew"):
        if path.is_symlink():
            raise SystemExit("A destination is a link. Nothing was installed.")
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    config = home / "config.yaml"
    if config.exists() and args.enable:
        saved = home / f"config.yaml.bak-{PLUGIN}-{stamp}"
        backup(config, saved)
        print(f"Hermes config backed up at {saved}")
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f"{PLUGIN}-stage-", dir=target.parent) as temporary:
        staged = Path(temporary) / PLUGIN
        staged.mkdir()
        for name in FILES:
            shutil.copy2(source / name, staged / name)
        shutil.copytree(source / "dashboard", staged / "dashboard",
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        if target.exists():
            old = home / "plugin-backups" / f"{PLUGIN}-{stamp}"
            old.parent.mkdir(parents=True, exist_ok=True)
            target.rename(old)
            print(f"Previous add-on saved at {old}")
        staged.rename(target)
    if args.local_model:
        settings_path = home / "nollie-crew" / "settings.json"
        settings_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        settings = {}
        if settings_path.exists():
            backup(settings_path, settings_path.with_name(f"settings.json.bak-{stamp}"))
            settings = json.loads(settings_path.read_text())
        settings["local_model"] = args.local_model
        temporary = settings_path.with_name(f".settings-{stamp}")
        temporary.write_text(json.dumps(settings, indent=1, sort_keys=True) + "\n")
        temporary.chmod(0o600)
        temporary.replace(settings_path)
        print(f"Crew settings saved at {settings_path}")
    if args.enable:
        hermes = shutil.which("hermes")
        if not hermes:
            raise SystemExit("Files installed. Hermes is not on PATH, so it was not enabled.")
        # Pin the profile so a sticky active profile cannot redirect this change. Keep output in memory.
        result = subprocess.run([hermes, "--profile", "default", "plugins", "enable", PLUGIN],
                                capture_output=True, text=True)
        if result.returncode:
            raise SystemExit(f"Files installed; Hermes enable failed (exit {result.returncode}). The config backup is intact.")
        print("Enabled for Nollie. No gateway restart was requested.")
    print("Installed.")


if __name__ == "__main__":
    main()
