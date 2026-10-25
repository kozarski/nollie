"""Shared fixtures: a temporary Hermes home with Nollie, two other bots and a private one."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "nollie_crew_under_test"
if PACKAGE not in sys.modules:
    _spec = importlib.util.spec_from_file_location(PACKAGE, ROOT / "__init__.py", submodule_search_locations=[str(ROOT)])
    _module = importlib.util.module_from_spec(_spec)
    sys.modules[PACKAGE] = _module
    _spec.loader.exec_module(_module)

crew_module = importlib.import_module(PACKAGE + ".crew")
policy = importlib.import_module(PACKAGE + ".policy")
profiles_module = importlib.import_module(PACKAGE + ".profiles")
store = importlib.import_module(PACKAGE + ".store")
tools_module = importlib.import_module(PACKAGE + ".tools")
handoffs = importlib.import_module(PACKAGE + ".handoffs")

NOLLIE = {
    "_config_version": 30,
    "model": {"provider": "fixture-plan", "default": "fixture-large"},
    "platform_toolsets": {
        "cli": ["browser", "clarify", "computer_use", "connections", "cronjob", "delegation", "file", "memory",
                "session_search", "skills", "terminal", "todo", "vision", "web"],
        "telegram": ["hermes-telegram"],
        "cron": ["clarify", "cronjob", "file", "memory", "web"],
    },
    "approvals": {"mode": "smart", "timeout": 900, "cron_mode": "deny", "unattended_mode": "approve",
                  "deny": ["sudo *", "hermes *", "*osascript*"]},
    "command_allowlist": ["cua:click:foreground", "plugin_rule:something"],
    "mcp_servers": {"cua": {"command": "cua-driver", "args": ["mcp"]},
                    "notes": {"url": "http://127.0.0.1:9000/mcp", "headers": {"Authorization": "Bearer fixture-not-a-secret"}}},
    "platforms": {"telegram": {"enabled": True}},
    "plugins": {"enabled": ["nollie-guard", "nollie-crew", "nollie-workflow"]},
    "auxiliary": {"title_generation": {"provider": "fixture-plan"}},
    "nous": {"subscription": True},
    "secrets": {"onepassword": {"enabled": False}},
    "gateway": {"bot_loop_guard": {"enabled": True}},
    "agent": {"max_turns": 60},
    "web": {"backend": "fixture"},
    "timezone": "Europe/London",
}

PERSON_ASKED = {"name": "Rover", "role": "check new roles each morning",
                "come_to_me_for": "New job listings and what changed since yesterday.", "asked_by_person": True}


class SpyProfiles(profiles_module.FileProfiles):
    """Records every profile whose files are opened, so tests can prove the private one never is."""

    def __init__(self, root):
        super().__init__(root)
        self.touched = set()

    def home(self, profile_id):
        self.touched.add(profile_id)
        return super().home(profile_id)


def tree_digest(path):
    digest = hashlib.sha256()
    for item in sorted(Path(path).rglob("*")):
        digest.update(str(item.relative_to(path)).encode())
        if item.is_file():
            digest.update(item.read_bytes())
    return digest.hexdigest()


def install_workflow(root):
    shutil.copytree(ROOT.parent / "nollie-workflow", root / "plugins" / "nollie-workflow",
                    ignore=shutil.ignore_patterns("tests", "__pycache__", "*.pyc"))


class Home:
    def __init__(self, nollie=None):
        self.temp = TemporaryDirectory()
        self.root = Path(self.temp.name) / ".hermes"
        self.root.mkdir()
        install_workflow(self.root)
        store.write_yaml(self.root / "config.yaml", nollie or NOLLIE)
        store.write_yaml(self.root / "profile.yaml", {"display_name": "Nollie"})
        career = self.root / "profiles" / "career"
        career.mkdir(parents=True)
        store.write_yaml(career / "config.yaml", {"model": {"provider": "fixture-plan"}})
        store.write_yaml(career / "profile.yaml", {"display_name": "Scout"})
        private = self.root / "profiles" / "private"
        private.mkdir()
        (private / "SOUL.md").write_text("fixture private bot\n")
        store.write_yaml(private / "profile.yaml", {"display_name": "Hidden"})
        self.private_digest = tree_digest(private)
        self.career_digest = tree_digest(career)
        self.profiles = SpyProfiles(self.root)
        self.clock = [1_800_000_000.0]
        counter = iter(range(1, 10_000))
        self.crew = crew_module.Crew(self.profiles, self.root / "nollie-crew", clock=lambda: self.clock[0],
                                     token=lambda: f"t{next(counter):04d}")
        self.who = {"profile": "default", "helper": False, "scheduled": False}
        self.tools = tools_module.CrewTools(self.crew, lambda: dict(self.who))

    def call(self, tool, args):
        return json.loads(self.tools.handle(tool, args))

    def approve(self, tool, args, choice="once"):
        """What Hermes does: run the hook, show the prompt, report the person's answer."""
        directive = self.tools.pre_tool_call(tool_name=tool, args=args, session_id="s1", tool_call_id="c1")
        if directive:
            self.tools.post_approval_response(pattern_key="plugin_rule:" + directive["rule_key"], choice=choice,
                                              session_key="agent:default:fixture")
        return directive

    def member_config(self, profile_id):
        return store.read_yaml(self.root / "profiles" / profile_id / "config.yaml")

    def private_untouched(self):
        return (tree_digest(self.root / "profiles" / "private") == self.private_digest
                and "private" not in self.profiles.touched)

    def cleanup(self):
        self.temp.cleanup()
