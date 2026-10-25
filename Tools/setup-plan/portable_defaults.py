"""Read the same versioned fresh-install contract bundled with Nollie. No writes."""

import json
from pathlib import Path
import unicodedata


RESOURCE = Path(__file__).resolve().parents[2] / "Apps/Nollie/Resources/nollie-starter.json"
_NAME = "{{assistant_name}}"

# These are validation boundaries, not a second source used to generate defaults.
_SAFE_V1 = {
    "plugins": {"enabled": ["nollie-workflow"]},
    "approvals": {"mode": "manual", "cron_mode": "deny", "single_query_mode": "deny", "unattended_mode": "deny"},
    "kanban": {"auto_decompose": False, "max_in_progress": 1, "max_in_progress_per_profile": 1},
    "delegation": {"max_concurrent_children": 1},
    "cron": {"allow_agent_scheduling": False},
    "telemetry": {"shared_metrics": {"enabled": False, "send": False}},
}


def _matches(value, expected):
    if type(value) is not type(expected):
        return False
    if isinstance(expected, dict):
        return value.keys() == expected.keys() and all(_matches(value[k], v) for k, v in expected.items())
    return value == expected


def load_contract(resource=RESOURCE):
    data = Path(resource).read_bytes()
    if not 0 < len(data) <= 8192:
        raise ValueError("Invalid starter settings")
    contract = json.loads(data)
    if (not isinstance(contract, dict) or set(contract) != {"version", "soul", "config"}
            or type(contract["version"]) is not int or contract["version"] != 1
            or not _matches(contract["config"], _SAFE_V1)):
        raise ValueError("Invalid starter settings")
    soul = contract["soul"]
    if (not isinstance(soul, str) or not soul.startswith("# " + _NAME + "\n")
            or soul.count(_NAME) != 1 or not 0 < len(soul.encode("utf-8")) <= 4096):
        raise ValueError("Invalid starter settings")
    return contract


def portable_soul(name: str, *, resource=RESOURCE) -> str:
    template = load_contract(resource)["soul"]
    name = " ".join(name.split()) or "Nollie"
    if len(name.encode("utf-8")) > 256 or any(unicodedata.category(c) == "Cc" for c in name):
        raise ValueError("Invalid assistant name")
    return template.replace(_NAME, name)


def portable_config(*, resource=RESOURCE) -> dict:
    return load_contract(resource)["config"]

