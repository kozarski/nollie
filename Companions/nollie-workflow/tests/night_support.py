"""Fixtures for the Night shift tests: the add-on loaded as a package, and fake Hermes parts."""
import copy
import hashlib
import importlib.util
from pathlib import Path
import sys
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
NAME = "night_shift_test_package"
if NAME not in sys.modules:
    _spec = importlib.util.spec_from_file_location(NAME, ROOT / "__init__.py", submodule_search_locations=[str(ROOT)])
    _module = importlib.util.module_from_spec(_spec)
    sys.modules[NAME] = _module
    _spec.loader.exec_module(_module)


def load(name):
    return __import__(NAME + "." + name, fromlist=["_"])


def job(job_id="3f2a9c", **fields):
    value = {"id": job_id, "name": "Morning prices", "prompt": "Check the SSD price.",
             "schedule": {"kind": "cron", "expr": "0 7 * * 1-5", "display": "0 7 * * 1-5"},
             "deliver": "bot-chat", "failure_deliver": None, "enabled": True, "state": "scheduled",
             "enabled_toolsets": ["web"], "created_at": "2026-10-20T06:00:00+00:00"}
    value.update(fields)
    return value


class FakeJobs:
    """A cron store per profile, with the same id checks as the real adapter."""

    def __init__(self, jobs=None, names=None, scripts=None):
        self.store = {profile: {j["id"]: copy.deepcopy(j) for j in items} for profile, items in (jobs or {}).items()}
        self.names = names or {}
        self.scripts = scripts or {}
        self.calls = []
        self.fail_list = set()
        self.uninstalled = set()

    def profiles(self):
        return ["default"] + sorted(p for p in self.store if p != "default")

    def display_name(self, profile):
        if profile in ("private", "moss"):
            raise AssertionError("a private bot was read")
        return self.names.get(profile, "")

    def jobs(self, profile):
        if profile in ("private", "moss"):
            raise AssertionError("a private bot's schedules were read")
        if profile in self.fail_list:
            raise OSError("store unavailable")
        return [copy.deepcopy(j) for j in self.store.get(profile, {}).values()]

    def get(self, profile, job_id):
        found = self.store.get(profile, {}).get(job_id)
        return copy.deepcopy(found) if found else None

    def update(self, profile, job_id, updates):
        self.calls.append(("update", profile, job_id, dict(updates)))
        found = self.store.get(profile, {}).get(job_id)
        if not found:
            return None
        found.update(updates)
        return copy.deepcopy(found)

    def pause(self, profile, job_id, reason):
        self.calls.append(("pause", profile, job_id, reason))
        return self.update(profile, job_id, {"enabled": False, "state": "paused", "paused_reason": reason})

    def resume(self, profile, job_id):
        self.calls.append(("resume", profile, job_id))
        found = self.store.get(profile, {}).get(job_id)
        if not found:
            return None
        if found.get("schedule", {}).get("kind") == "once" and found.get("past"):
            raise ValueError("Cannot resume: one-shot time is in the past")
        found.update(enabled=True, state="scheduled", paused_reason=None)
        return copy.deepcopy(found)

    def recorder_installed(self, profile):
        return profile not in self.uninstalled

    def file_hash(self, profile):
        def digest(name):
            content = self.scripts.get((profile, name))
            return hashlib.sha256(content.encode()).hexdigest() if content is not None else "missing"
        return digest


class Checks:
    """Hermes's approval predicates, faked. Each answer can be set or made to raise."""

    def __init__(self, **answers):
        self.answers = {"hardline": (False, None), "runtime_delete": False, "sudo_guard": (False, None),
                        "deny_rule": None, "allowlist_entry": None, "dangerous": (False, None, None),
                        "permanently_approved": False}
        self.answers.update(answers)
        self.asked = []

    def __getattr__(self, name):
        if name not in self.answers:
            raise AttributeError(name)

        def ask(*args):
            self.asked.append(name)
            answer = self.answers[name]
            if isinstance(answer, Exception):
                raise answer
            return answer(*args) if callable(answer) else answer
        return ask


def execution(job_id="3f2a9c", execution_id="e-81", name="Morning prices", scheduled_instant=None):
    return SimpleNamespace(job_id=job_id, execution_id=execution_id, job_name=name, scheduled_instant=scheduled_instant)


class Clock:
    def __init__(self, value=1792560000.0):
        self.value = value

    def __call__(self):
        return self.value
