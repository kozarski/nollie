"""Keep skills as they are: one switch per helper, so it can't rewrite its own skills.

Hermes 0.23 locks one skill at a time (``PUT /api/skills/lock``, the same record as ``hermes curator lock``): while a
skill is locked the agent can't change it through ``skill_manage``, ``write_file``, ``patch`` or ``terminal``, and the
curator won't archive it. It can still read and use it. Hermes has no switch for every skill at once, and a skill the
agent makes is never locked by Hermes (``create`` is exempt from the lock guard).

So this keeps the helpers whose switch is on, in the main home, and locks each new skill the moment Hermes says one was
made or installed (``on_skill_lifecycle``), in that helper's own process. The app locks the skills a helper already has
through Hermes's own route when the switch goes on, and unlocks them when it goes off.
"""

import contextlib
import json
import logging
from pathlib import Path

from .workflow_core import atomic_write, file_lock

FOLDER = "keep-skills"
LOG = logging.getLogger("nollie-workflow")


class Store:
    """Which helpers keep their skills, shared by the hook (in the gateway) and the routes (in the dashboard)."""

    def __init__(self, main_home):
        self.root = Path(main_home) / "nollie-workflow" / FOLDER

    @contextlib.contextmanager
    def _locked(self):
        for path in (self.root.parent, self.root):
            if path.is_symlink():
                raise ValueError("a keep-skills folder is a link")
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        with file_lock(self.root / "bots.lock"):
            yield

    def bots(self):
        """The helpers whose switch is on. A damaged file raises, so the routes say so instead of guessing."""
        path = self.root / "bots.json"
        try:
            if self.root.parent.is_symlink() or self.root.is_symlink() or path.is_symlink() or path.stat().st_size > 64 * 1024:
                raise ValueError("bots.json is not readable")
            document = json.loads(path.read_text())
        except FileNotFoundError:
            return []
        except UnicodeDecodeError:
            raise ValueError("bots.json is not readable") from None
        bots = document.get("bots") if isinstance(document, dict) and document.get("version") == 1 else None
        if not isinstance(bots, list) or not all(isinstance(b, str) for b in bots):
            raise ValueError("bots.json is not valid")
        return sorted(set(bots))

    def keeps(self, bot):
        try:
            return bot in self.bots()
        except (OSError, ValueError):
            return False

    def set_bot(self, bot, on):
        if not isinstance(on, bool):
            raise ValueError("Send on as true or false.")
        with self._locked():
            bots = set(self.bots())
            (bots.add if on else bots.discard)(bot)
            atomic_write(self.root / "bots.json", {"version": 1, "bots": sorted(bots)})
        return on


# Hermes's lifecycle actions for a skill that is new in this helper.
NEW = frozenset(("created", "installed"))


class NewSkillLock:
    """``on_skill_lifecycle``: a skill this helper just made or installed is locked at once while its switch is on.
    It runs in the helper's own process, after Hermes has written the skill's record (a create resets that record,
    so a lock set any earlier would be wiped). Anything unexpected leaves the skill as Hermes made it and logs why."""

    def __init__(self, store, bot, bot_home, lock=None, home=None):
        self.store, self.bot, self.bot_home = store, bot, Path(bot_home).resolve()
        self._lock, self._home = lock or hermes_lock, home or hermes_home

    def __call__(self, action=None, skill_name=None, **_):
        if action not in NEW or not isinstance(skill_name, str) or not skill_name.strip():
            return None
        try:
            if not self.store.keeps(self.bot):
                return None
            # Only in this helper's own scope: never lock a skill in another helper's home.
            if Path(self._home()).resolve() != self.bot_home:
                return None
            if not self._lock(skill_name):
                LOG.warning("A new skill could not be locked.")
        except Exception as exc:
            LOG.warning("A new skill could not be locked: %s", type(exc).__name__)
        return None


def hermes_home():
    from hermes_constants import get_hermes_home
    return get_hermes_home()


def hermes_lock(name):
    """Hermes's own lock, keyed by the skill's folder name as ``hermes curator lock`` and the lock route do."""
    from tools import skill_usage
    from tools.skill_manager_tool import _find_skill
    found = _find_skill(name)
    if found is None:
        return False
    return bool(skill_usage.set_locked(found["path"].name, True))


def register(ctx, default_home, profile, bot_home):
    hook = NewSkillLock(Store(default_home), profile, bot_home)
    ctx.register_hook("on_skill_lifecycle", hook)
    return hook
