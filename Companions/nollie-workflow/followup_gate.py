"""Native cron pre-check. Output is data; errors never wake a model."""
import importlib.util
import json
from pathlib import Path
import re
import sys


def main(key):
    if not isinstance(key, str) or not re.fullmatch(r"[a-f0-9]{64}", key):
        raise ValueError("invalid watch key")
    root = Path(__file__).resolve().parent
    name = "nollie_workflow_gate"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, root / "__init__.py", submodule_search_locations=[str(root)])
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    from hermes_constants import get_hermes_home
    tools = __import__(name + ".followup_tools", fromlist=["manager"])
    core = __import__(name + ".workflow_core", fromlist=["read_state"])
    home = root.parents[1]
    if Path(get_hermes_home()).resolve() != home or not core.read_state(home / "nollie-workflow")["enabled"]:
        return {"wakeAgent": False, "reason": "disabled"}
    return tools.manager(home).gate(key)


if __name__ == "__main__":
    try:
        result = main(globals().get("WATCH_KEY"))
    except Exception:
        result = {"wakeAgent": False, "reason": "followup_unavailable"}
    print(json.dumps(result, allow_nan=False))
