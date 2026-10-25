#!/usr/bin/env python3
"""Local nonsecret status and reversible observation controls."""
import argparse
import importlib.util
import json
from pathlib import Path
import sys


def core():
    spec = importlib.util.spec_from_file_location("nollie_workflow_control_core", Path(__file__).with_name("workflow_core.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def package():
    """The whole add-on under a private name, for the Night shift settings."""
    root = Path(__file__).resolve().parent
    name = "nollie_workflow_control"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, root / "__init__.py", submodule_search_locations=[str(root)])
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return __import__(name + ".night_shift", fromlist=["write_settings"])


def night_status(root):
    night = package()
    try:
        settings = night.read_settings(root)
    except ValueError:
        return {"settings": "damaged"}
    settings = settings or dict(night.DEFAULTS, rehearsals_since=None)
    return {key: settings[key] for key in ("night_shift", "rehearsals", "morning_hour")}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("status", "activate", "pause", "night-shift", "rehearsals"))
    parser.add_argument("value", nargs="?", choices=("on", "off"))
    args = parser.parse_args()
    root = Path.home() / ".hermes" / "nollie-workflow"
    if args.action in ("night-shift", "rehearsals"):
        if args.value is None:
            parser.error(f"{args.action} needs on or off")
        field = args.action.replace("-", "_")
        package().write_settings(root, **{field: args.value == "on"})
        print(json.dumps(night_status(root), indent=2))
        return
    api = core()
    if args.action != "status":
        with api.file_lock(root / "state.lock"):
            state = api.read_state(root)
            state["enabled"] = args.action == "activate"
            api.atomic_write(root / "state.json", state)
    result = api.status(root)
    result["night_shift"] = night_status(root)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
