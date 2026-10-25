#!/usr/bin/env python3
"""Show the local install plan, or apply it when explicitly requested."""
import argparse
import datetime
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def private_names(home):
    """The Private list in the main Hermes home, read with the companion's own reader."""
    spec = importlib.util.spec_from_file_location("nollie_computer_install_private",
                                                  Path(__file__).resolve().parent / "dashboard/private_bots.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    try:
        return module.read(home)[0]
    except (OSError, ValueError):
        raise SystemExit("The Private list cannot be read. Nothing was installed.") from None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true", help="copy the plugin and enable it in Hermes")
    parser.add_argument("--files-only", action="store_true", help="stage files without enabling or reloading Hermes")
    parser.add_argument("--owned-space", action="append", default=[], metavar="PROFILE=LOCATION:NAME",
                        help="record one already verified owned Space; never creates or starts it")
    args = parser.parse_args()
    owners = {}
    private = private_names(Path.home() / ".hermes") if args.owned_space else frozenset()
    for entry in args.owned_space:
        profile, separator, target_name = entry.partition("=")
        if (not separator or not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", profile) or profile in private
                or not re.fullmatch(r"(?:local|cloud):[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", target_name)):
            parser.error("Owned Spaces require a nonprivate profile name and a qualified local/cloud name.")
        owners[profile] = target_name
    source = Path(__file__).resolve().parent
    target = Path.home() / ".hermes/plugins/nollie-computer"
    print(f"Copy {source} to {target}")
    print("Keep a dated backup if the companion is already installed.")
    print("Back up the default Hermes config before enabling the companion.")
    print("Files only; Hermes activation stays unchanged." if args.files_only else
          "Enable with: hermes --profile default plugins enable nollie-computer")
    print("No VM, daemon, gateway restart, input permission, or network exposure is requested.")
    if not args.apply:
        print("Plan only. Pass --apply after approving the installation.")
        return
    hermes = shutil.which("hermes")
    if not hermes:
        raise SystemExit("Hermes is not on PATH. Nothing was installed.")
    if target.is_symlink():
        raise SystemExit("The destination is a symlink. Nothing was installed.")
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    owned_path = target.parent.parent / "nollie-computer/owned-spaces.json"
    owned_document = {"version": 1, "profiles": {}}
    if owners and owned_path.exists():
        if owned_path.is_symlink() or owned_path.stat().st_size > 16384:
            raise SystemExit("The existing ownership record cannot be safely updated.")
        try:
            owned_document = json.loads(owned_path.read_text())
            if (not isinstance(owned_document, dict) or owned_document.get("version") != 1
                    or not isinstance(owned_document.get("profiles"), dict)):
                raise ValueError()
        except (ValueError, UnicodeDecodeError):
            raise SystemExit("The existing ownership record cannot be safely updated.") from None
    config = target.parent.parent / "config.yaml"
    if config.exists() and not args.files_only:
        backup = config.with_name(config.name + ".bak-nollie-computer-" + stamp)
        shutil.copy2(config, backup)
        backup.chmod(0o600)
        print(f"Hermes config backed up at {backup}")
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="nollie-computer-", dir=target.parent) as directory:
        staged = Path(directory) / "nollie-computer"
        staged.mkdir()
        for name in ("__init__.py", "plugin.yaml"):
            shutil.copy2(source / name, staged / name)
        shutil.copytree(source / "dashboard", staged / "dashboard", ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        if target.exists():
            backup = target.parent.parent / "plugin-backups" / ("nollie-computer-" + stamp)
            backup.parent.mkdir(parents=True, exist_ok=True)
            target.rename(backup)
            print(f"Previous companion saved at {backup}")
        staged.rename(target)
    if owners:
        owned_path.parent.mkdir(parents=True, exist_ok=True)
        if owned_path.exists():
            backup = owned_path.with_name(owned_path.name + ".bak-nollie-computer-" + stamp)
            shutil.copy2(owned_path, backup)
            backup.chmod(0o600)
            print(f"Ownership record backed up at {backup}")
        owned_document["profiles"].update(owners)
        temporary = owned_path.with_name(owned_path.name + ".tmp-" + stamp)
        temporary.write_text(json.dumps(owned_document, indent=2) + "\n")
        temporary.chmod(0o600)
        temporary.replace(owned_path)
        print(f"Verified owned Spaces recorded at {owned_path}")
    if args.files_only:
        print("Companion files staged. No enable, reload, or restart was requested.")
        return
    # Pin the intended profile; a sticky active profile must not redirect this config change.
    # Keep plugin/CLI diagnostics in memory so unrelated plugin output cannot expose secrets.
    result = subprocess.run([hermes, "--profile", "default", "plugins", "enable", "nollie-computer"],
                            capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(f"Plugin files installed; Hermes enable failed (exit {result.returncode}). The config backup is intact.")
    if "Gateway reloaded plugins" in result.stdout or "active in the running gateway" in result.stdout:
        print("Hermes reloaded its plugins without a service restart.")
    print("Companion installed and enabled. Check a Space preview in Nollie.")


if __name__ == "__main__":
    main()
