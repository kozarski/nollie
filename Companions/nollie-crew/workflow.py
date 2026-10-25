"""Carry the main bot's Ask first hooks into a new member before Hermes serves it."""
import importlib.util
from datetime import datetime
from pathlib import Path
import shutil
import sys
import tempfile

from . import store
from .policy import CrewError, MAIN, WORKFLOW

INITIALIZED = "ask-first-initialized"


class Workflow:
    def __init__(self, home):
        self.home = Path(home)
        self.source = self.home / "plugins" / WORKFLOW
        self._private = None

    def initialized(self, home):
        root = Path(home) / WORKFLOW
        marker = root / INITIALIZED
        if root.is_symlink() or marker.is_symlink() or (root.exists() and not root.is_dir()):
            raise CrewError("The bot's Ask first settings need repair.")
        if not marker.exists():
            return False
        if not marker.is_file() or marker.read_text() != "1\n":
            raise CrewError("The bot's Ask first settings need repair.")
        return True

    def mark_initialized(self, home):
        if not self.initialized(home):
            store.write_text(Path(home) / WORKFLOW / INITIALIZED, "1\n")

    def source_ready(self):
        for path in (self.home, self.source.parent, self.source):
            if path.is_symlink() or not path.is_dir():
                raise CrewError("Ask first needs repair before adding a crew member.")
        for name in ("__init__.py", "plugin.yaml", "private_bots.py", "workflow_core.py", "ask_first.py"):
            path = self.source / name
            if path.is_symlink() or not path.is_file():
                raise CrewError("Ask first needs repair before adding a crew member.")

    def private_names(self):
        self.source_ready()
        if self._private is None:
            name = "nollie_crew_workflow_" + str(id(self))
            spec = importlib.util.spec_from_file_location(name, self.source / "__init__.py",
                                                          submodule_search_locations=[str(self.source)])
            module = importlib.util.module_from_spec(spec)
            sys.modules[name] = module
            spec.loader.exec_module(module)
            self._private = __import__(name + ".private_bots", fromlist=["read"])
        try:
            return self._private.read(self.home)[0] | self._private.carried_over_names()
        except (OSError, ValueError):
            raise CrewError("The Private list needs repair before changing the crew.") from None

    def is_private(self, profile_id):
        private = self.private_names()
        return self._private.excluded(profile_id, private)

    def prepare(self, profile_id):
        if self.is_private(profile_id) or self.is_private(MAIN):
            raise CrewError("That bot is private, so I leave it alone.")
        for path in self.source.rglob("*"):
            if path.is_symlink():
                raise CrewError("Ask first needs repair before adding a crew member.")

    def copy_into(self, profile_id, home, *, restoring=False):
        self.prepare(profile_id)
        self.check_home(profile_id, home)
        target = Path(home) / "plugins" / WORKFLOW
        if (target.exists() and not restoring) or target.is_symlink() or target.parent.is_symlink():
            raise CrewError("The new bot's add-on folder needs repair.")
        recorder_only = not restoring or not target.is_dir() or (target / "recorder-only").exists()
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(self.source, target,
                        ignore=shutil.ignore_patterns("tests", "__pycache__", "*.pyc", "recorder-only"))
        if recorder_only:
            marker = target / "recorder-only"
            marker.write_text("Papertrail is off in this bot. A copy made with --papertrail-bots turns it on.\n")
            marker.chmod(0o600)

    def ensure_into(self, profile_id, home):
        self.prepare(profile_id)
        self.check_home(profile_id, home)
        home = Path(home)
        target = home / "plugins" / WORKFLOW
        if home.is_symlink() or home.parent.is_symlink() or target.parent.is_symlink() or target.is_symlink():
            raise CrewError("The bot's add-on folder needs repair.")
        if not target.exists():
            self.copy_into(profile_id, home)
            return
        if any(path.is_symlink() for path in target.rglob("*")):
            raise CrewError("The bot's add-on folder needs repair.")
        expected = {p.relative_to(self.source): p for p in self.source.rglob("*")
                    if p.is_file() and "__pycache__" not in p.parts and "tests" not in p.parts
                    and p.suffix != ".pyc" and p.name != "recorder-only"}
        if all(not (target / name).is_symlink() and (target / name).is_file()
               and (target / name).read_bytes() == source.read_bytes() for name, source in expected.items()):
            return
        backups = home / "plugin-backups"
        if backups.is_symlink():
            raise CrewError("The bot's add-on backup folder needs repair.")
        with tempfile.TemporaryDirectory(prefix=".crew-workflow-", dir=home) as temporary:
            staged_home = Path(temporary)
            self.copy_into(profile_id, staged_home)
            staged = staged_home / "plugins" / WORKFLOW
            if not (target / "recorder-only").exists():
                (staged / "recorder-only").unlink()
            backups.mkdir(mode=0o700, exist_ok=True)
            target.rename(backups / f"{WORKFLOW}-{datetime.now().strftime('%Y%m%d-%H%M%S-%f')}")
            staged.rename(target)

    def check_home(self, profile_id, home):
        home = Path(home)
        try:
            relative = home.relative_to(self.home / "profiles")
        except ValueError:
            raise CrewError("The bot's folder needs repair.") from None
        parts = relative.parts
        if (not parts or ".." in parts or not (parts[0] == profile_id
                or parts[0].startswith(f".{profile_id}.staging-")
                or parts[0].startswith(f".{profile_id}.restore-"))):
            raise CrewError("The bot's folder needs repair.")
        for path in (home, *home.parents):
            if path.is_symlink():
                raise CrewError("The bot's folder needs repair.")
            if path == self.home:
                break
