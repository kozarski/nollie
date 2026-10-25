#!/usr/bin/env python3
"""Status of the shared limits, and a way to empty the reader's cache."""
import argparse
import importlib.util
import json
from pathlib import Path
import sys


def package():
    here = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location("nollie_reader_control", here / "__init__.py",
                                                  submodule_search_locations=[str(here)])
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    import importlib as loader
    return loader.import_module(f"{spec.name}.limits"), loader.import_module(f"{spec.name}.cache"), \
        loader.import_module(f"{spec.name}.state")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("status", "clear-cache"))
    args = parser.parse_args()
    limits, cache, state = package()
    root = state.shared_root()
    if args.action == "clear-cache":
        print(f"Removed {cache.Cache(root).clear()} cached entries.")
        return
    handoffs = state.read_json(root / "handoffs.json", {})
    helper = (root / "venv" / "bin" / "python").is_file()
    print(json.dumps({"state": str(root), "extractors_installed": helper,
                      "services": limits.ServiceLimits(root).status(),
                      "sites_waiting_for_a_person": sorted(handoffs)}, indent=2))


if __name__ == "__main__":
    main()
