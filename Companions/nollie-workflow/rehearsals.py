"""Which schedule runs rehearse, and the registry of schedules Nollie has seen.

``<main home>/nollie-workflow/rehearsals.json`` (0600, lock ``rehearsals.lock``). Only the main
home's service and the routes write it; recorders only read it. ``pending`` lists the bots whose
schedules could not be read when rehearsals turned on; they are recorded on a later tick.
"""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
from pathlib import Path
import time

from .followup_policy import route_signature
from .workflow_core import atomic_write

FILE_NAME = "rehearsals.json"
LOCK_NAME = "rehearsals.lock"
MAX_BYTES = 4_000_000
MAX_JOBS = 2000
STATES = frozenset(("on", "waiting", "ready", "kept_off"))
KINDS = frozenset(("rehearse", "check"))
DELIVERY = ("deliver", "failure_deliver")
REAL, REHEARSAL = "real", "rehearsal"


def key(profile, job_id):
    return f"{profile}/{job_id}"


def empty(since=None):
    return {"version": 1, "since": since, "jobs": {}}


def validate(document):
    """The registry if it is whole, else ValueError."""
    jobs = document.get("jobs") if isinstance(document, dict) and document.get("version") == 1 else None
    since = document.get("since") if isinstance(document, dict) else None
    pending = document.get("pending", []) if isinstance(document, dict) else None
    if (not isinstance(jobs, dict) or len(jobs) > MAX_JOBS or not (since is None or type(since) is int)
            or not isinstance(pending, list) or not all(isinstance(name, str) for name in pending)):
        raise ValueError("invalid rehearsal registry")
    for name, entry in jobs.items():
        if (not isinstance(entry, dict) or entry.get("state") not in STATES or entry.get("kind") not in KINDS
                or not isinstance(entry.get("profile"), str) or not isinstance(entry.get("job_id"), str)
                or name != key(entry["profile"], entry["job_id"]) or not isinstance(entry.get("signature"), str)
                or not isinstance(entry.get("saved"), (dict, type(None)))):
            raise ValueError("invalid rehearsal registry")
    return document


def read(root, *, wait=None):
    """The registry, None when there is none yet, or ValueError when it is damaged.

    ``wait`` bounds how long a reader waits for a writer's lock (the guard uses 0.5 seconds);
    writes are atomic, so after that it reads what is there. A reader never creates the lock.
    """
    root = Path(root)
    path = root / FILE_NAME
    if wait is not None:
        _wait_for_lock(root / LOCK_NAME, wait)
    try:
        if path.is_symlink():
            raise ValueError("linked rehearsal registry")
        if path.stat().st_size > MAX_BYTES:
            raise ValueError("oversized rehearsal registry")
        document = json.loads(path.read_text())
    except FileNotFoundError:
        return None
    except UnicodeDecodeError:
        raise ValueError("unreadable rehearsal registry") from None
    return validate(document)


def _wait_for_lock(path, wait):
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        deadline = time.monotonic() + wait
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
                fcntl.flock(fd, fcntl.LOCK_UN)
                return
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    return
                time.sleep(0.05)
    finally:
        os.close(fd)


def write(root, document):
    atomic_write(Path(root) / FILE_NAME, validate(document))


def effective(job, saved):
    """The job as the person set it: while held, delivery comes from what Nollie saved."""
    job = dict(job)
    if isinstance(saved, dict):
        for field in DELIVERY:
            if job.get(field) == "local":
                job[field] = saved.get(field)
    return job


def signature(job, file_hash, saved=None):
    """Changes when the job or its script changes; pausing and resuming leave it alone."""
    job = effective(job, saved)
    body = {"route": route_signature(job), "script": job.get("script"), "no_agent": bool(job.get("no_agent")),
            "precheck_fail_closed": job.get("precheck_fail_closed"), "monitor_script": job.get("monitor_script"),
            "monitor_url": job.get("monitor_url"),
            "script_hash": file_hash(job["script"]) if job.get("script") else None,
            "monitor_hash": file_hash(job["monitor_script"]) if job.get("monitor_script") else None}
    return hashlib.sha256(json.dumps(body, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def file_hash(home):
    """A hasher for script names as Hermes resolves them: inside ``<home>/scripts`` only."""
    scripts = (Path(home) / "scripts").resolve()

    def digest(value):
        try:
            raw = Path(str(value)).expanduser()
            path = raw.resolve() if raw.is_absolute() else (scripts / raw).resolve()
            path.relative_to(scripts)
            return hashlib.sha256(path.read_bytes()).hexdigest()
        except (OSError, ValueError, RuntimeError):
            return "missing"
    return digest


def check_reason(job):
    """Why Nollie can't rehearse a job, or None when it can."""
    if job.get("script") or job.get("no_agent") or job.get("monitor_script") or job.get("monitor_url"):
        return "script"
    if (job.get("schedule") or {}).get("kind") == "once":
        return "once"
    if (job.get("repeat") or {}).get("times") is not None:
        return "repeat"
    return None


def bound_followup(profile, job, followups):
    """A Board follow-through check that its own gate guards: the watch matches the job exactly."""
    if profile != "default" or not isinstance(followups, dict):
        return False
    tasks = followups.get("tasks") if followups.get("version") == 1 else None
    for entry in (tasks or {}).values():
        watch = entry.get("watch") if isinstance(entry, dict) else None
        if (isinstance(watch, dict) and watch.get("state") == "active" and watch.get("job_id") == job.get("id")
                and watch.get("route") == route_signature(job) and watch.get("script") == job.get("script")):
            return True
    return False


def decide(profile, job, hasher, registry, followups):
    """``real`` or ``rehearsal`` for one cron run. ``registry`` None means no good copy: rehearse."""
    entry = (registry or {}).get("jobs", {}).get(key(profile, job.get("id")))
    if entry and entry.get("state") == "on" and entry.get("signature") == signature(job, hasher):
        return REAL
    if bound_followup(profile, job, followups):
        return REAL
    return REHEARSAL
