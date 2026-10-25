"""The service's Night shift duties, once per tick in the main home, and the two card actions.

Each tick (15 seconds, or at once when a run created a schedule) while rehearsals are on, every
followed bot's schedules are swept: a new or edited one is held (delivery saved and set to
``local``), a check job is paused with a card, and a finished rehearsal is reported and paused.
While Night shift is on, the morning card is built on the first tick at or after the morning hour.
Receipts older than 14 days, and every receipt of a bot marked Private, are deleted.
"""
from __future__ import annotations

from datetime import datetime
import json
import logging
from pathlib import Path
import shutil
import time

from . import private_bots, rehearsals
from .night_shift import (RECEIPTS, RECORDERS, GrantLog, OutcomeLog, Settings, assemble, check_post, day_files,
                          local_day, night_card, parse_time, read_lines, read_unrecorded, rehearsal_post)
from .posts import PostStore
from .receipts import hermes_redactor
from .recorder import WAKE_FLAG
from .workflow_core import atomic_write, file_lock

log = logging.getLogger("nollie-workflow")
KEEP_DAYS = 14
HOUSEKEEPING_SECONDS = 600
REHEARSED = "Rehearsed. Turn it on in Nollie when you're happy."
CHECK = "Nollie needs you to look at this first. Turn it on in Nollie when you're happy."
STATUS_NAME = "night-shift-status.json"
FOLLOWUPS_NAME = "followups.json"
FOLLOWUPS_MAX_BYTES = 4_000_000


class Conflict(Exception):
    """The card's schedule changed, or is not in a state this action takes."""

    def __init__(self, post):
        super().__init__("conflict")
        self.post = post


def watched(root, profile):
    """True when this bot's recorder said it loaded. ``NightService.watching`` also checks it is still there."""
    path = Path(root) / RECORDERS / (profile + ".json")
    try:
        if path.is_symlink():
            return False
        document = json.loads(path.read_text())
    except (OSError, ValueError):
        return False
    return isinstance(document, dict) and document.get("version") == 1 and type(document.get("at")) is int


def watching(root, profile, jobs):
    """A recorder said it loaded for this bot, and the bot still has the add-on installed and enabled.

    A heartbeat is not required to be recent: a bot's plugins load only when something runs for it.
    """
    if not watched(root, profile):
        return False
    check = getattr(jobs, "recorder_installed", None)
    try:
        return check is None or bool(check(profile))
    except Exception:
        return False


def bot_name(jobs, profile):
    try:
        name = jobs.display_name(profile)
    except Exception:
        name = ""
    if not name:
        # The app's own fallback for a bot with no display name: "work" reads "Work".
        name = profile[:1].upper() + profile[1:]
    return str(name)[:80]


def bound_jobs(root):
    """Job ids a Board follow-through watch holds (binding or active), or None when its file is unreadable.

    Their own gate checks them, and it compares the job's delivery: holding one would break it.
    """
    path = Path(root) / FOLLOWUPS_NAME
    try:
        if path.is_symlink() or path.stat().st_size > FOLLOWUPS_MAX_BYTES:
            return None
        document = json.loads(path.read_text())
    except FileNotFoundError:
        return frozenset()
    except (OSError, ValueError):
        return None
    tasks = document.get("tasks") if isinstance(document, dict) and document.get("version") == 1 else None
    if not isinstance(tasks, dict):
        return None
    found = set()
    for entry in tasks.values():
        watch = entry.get("watch") if isinstance(entry, dict) else None
        if (isinstance(watch, dict) and watch.get("state") in ("binding", "active")
                and isinstance(watch.get("job_id"), str)):
            found.add(watch["job_id"])
    return frozenset(found)


def wait_for_wake(root, stop, seconds):
    """Wait up to ``seconds``, waking early when a run created a schedule."""
    flag = Path(root) / WAKE_FLAG
    for _ in range(int(seconds)):
        if stop.wait(1):
            return
        try:
            flag.unlink()
            return
        except FileNotFoundError:
            continue
        except OSError:
            return


class NightService:
    def __init__(self, home, jobs=None, *, now=time.time, private=None, redactor=None):
        self.home = Path(home)
        self.root = self.home / "nollie-workflow"
        if jobs is None:
            from .hermes_adapter import ProfileJobs
            jobs = ProfileJobs(self.home)
        self.jobs, self.now = jobs, now
        self.private = private or (lambda: private_bots.names(self.home) | private_bots.carried_over_names())
        self.redactor = redactor if redactor is not None else hermes_redactor()
        self.settings = Settings(self.root, interval=0.0)
        self.posts = PostStore(self.root, now)
        self.outcomes = OutcomeLog(self.root)
        self.grants = GrantLog(self.root)
        self.housekept = None
        self.folded = {}
        self.status = {"version": 1, "last_tick_at": None, "last_error": None}
        self.status_written = None
        self.trouble = None

    # One tick ----------------------------------------------------------------------------

    def tick(self):
        self.trouble = None
        settings = self.settings.get()
        try:
            private = frozenset(self.private())
        except (OSError, ValueError):
            # Without the Private list nobody can be told apart: do nothing until it is repaired.
            return
        bots = [p for p in self.jobs.profiles() if isinstance(p, str) and not private_bots.excluded(p, private)]
        now = int(self.now())
        if self.housekept is None or now - self.housekept >= HOUSEKEEPING_SECONDS:
            self.housekeeping(bots, private, now)
        if settings.get("rehearsals"):
            self.sweep(bots, private, settings, now)
        elif not settings.get("damaged"):
            self.release(bots, now)
        if settings.get("night_shift"):
            self.morning(bots, private, settings, now)

    def note(self, error=None):
        """Status holds the time of the last tick and an error type name, never details.

        Without a raised error it shows what the tick noted, such as a bot whose schedules can't be read.
        """
        error = error or self.trouble
        now = int(self.now())
        self.status["last_tick_at"] = now
        changed = self.status.get("last_error") != error
        self.status["last_error"] = error
        if changed or self.status_written is None or now - self.status_written >= 60:
            atomic_write(self.root / STATUS_NAME, self.status)
            self.status_written = now

    # Rehearsals --------------------------------------------------------------------------

    def sweep(self, bots, private, settings, now):
        with file_lock(self.root / rehearsals.LOCK_NAME):
            registry = rehearsals.read(self.root)  # A damaged registry raises and is kept for repair.
            since = settings.get("rehearsals_since")
            if registry is None or (not settings.get("damaged") and registry.get("since") != since):
                registry = self.baseline(registry or rehearsals.empty(), bots, now)
                registry["since"] = since
                rehearsals.write(self.root, registry)
                return
            changed = False
            if registry.get("pending"):
                self.baseline(registry, [p for p in registry["pending"] if p in bots], now)
                changed = True
            bound = bound_jobs(self.root)  # Read once per tick.
            for profile in bots:
                if profile in registry.get("pending", ()) or (profile == "default" and bound is None):
                    continue  # Not recorded yet, or follow-through can't be told apart: leave it as it is.
                try:
                    jobs = self.jobs.jobs(profile)
                except Exception as exc:
                    self.trouble = type(exc).__name__
                    continue
                hasher = self.jobs.file_hash(profile)
                seen = self.watching(profile)
                live = set()
                for job in jobs:
                    if not isinstance(job.get("id"), str):
                        continue
                    live.add(job["id"])
                    try:
                        if profile == "default" and job["id"] in bound:
                            changed |= self.keep_on(registry, profile, job, hasher, now)
                        else:
                            changed |= self.sweep_job(registry, profile, job, hasher, seen, private, now)
                    except Exception as exc:
                        log.warning("Rehearsal sweep skipped a schedule: %s", type(exc).__name__)
                for name, entry in list(registry["jobs"].items()):
                    if entry["profile"] == profile and entry["job_id"] not in live:
                        del registry["jobs"][name]
                        changed = True
            if changed:
                rehearsals.write(self.root, registry)

    def release(self, bots, now):
        """Rehearsals are off: schedules still waiting get their delivery back and run for real.

        Paused ones (a report or a check card waiting for the person) stay paused.
        """
        with file_lock(self.root / rehearsals.LOCK_NAME):
            try:
                registry = rehearsals.read(self.root)
            except ValueError:
                return
            waiting = [e for e in (registry or {}).get("jobs", {}).values()
                       if e["state"] == "waiting" and e["profile"] in bots]
            if not waiting:
                return
            for entry in waiting:
                job = self.jobs.get(entry["profile"], entry["job_id"])
                if job is None:
                    continue
                saved = entry.get("saved") or {}
                restore = {f: saved.get(f) for f in rehearsals.DELIVERY if job.get(f) == "local" and saved.get(f) != "local"}
                if restore:
                    job = self.jobs.update(entry["profile"], entry["job_id"], restore)
                    if job is None:
                        continue
                entry.update(state="on", saved=None, updated_at=now,
                             signature=rehearsals.signature(job, self.jobs.file_hash(entry["profile"])))
            rehearsals.write(self.root, registry)

    def baseline(self, registry, bots, now):
        """Every schedule that exists when rehearsals turn on keeps running for real.

        A bot whose schedules can't be read now stays in ``pending`` and is recorded on a later tick.
        Until then its runs rehearse, and the status file names the error.
        """
        pending = []
        for profile in bots:
            try:
                jobs = self.jobs.jobs(profile)
            except Exception as exc:
                pending.append(profile)
                self.trouble = type(exc).__name__
                continue
            hasher = self.jobs.file_hash(profile)
            for job in jobs:
                if not isinstance(job.get("id"), str):
                    continue
                name = rehearsals.key(profile, job["id"])
                entry = registry["jobs"].get(name)
                if entry is None or entry["state"] == "on":
                    registry["jobs"][name] = self.entry(profile, job, "on", rehearsals.signature(job, hasher), now)
        if pending:
            registry["pending"] = sorted(pending)
        else:
            registry.pop("pending", None)
        return registry

    def watching(self, profile):
        return watching(self.root, profile, self.jobs)

    def keep_on(self, registry, profile, job, hasher, now):
        """A job a follow-through watch holds runs as the watch set it: never held, never paused."""
        name = rehearsals.key(profile, job["id"])
        current = rehearsals.signature(job, hasher)
        entry = registry["jobs"].get(name)
        if entry is not None and entry["state"] == "on" and entry["signature"] == current:
            return False
        registry["jobs"][name] = self.entry(profile, job, "on", current, now)
        return True

    @staticmethod
    def entry(profile, job, state, signature, now, *, kind="rehearse", saved=None, since=None):
        return {"profile": profile, "job_id": job["id"], "title": str(job.get("name") or "")[:240], "state": state,
                "signature": signature, "kind": kind, "saved": saved, "execution_id": None, "post_id": None,
                "updated_at": now, "since": now if since is None else since}

    def hold(self, registry, profile, job, hasher, seen, private, now, *, saved=None, since=None):
        """Save the delivery and set it to local; a job Nollie can't rehearse is paused with a card."""
        saved = saved or {"deliver": job.get("deliver"), "failure_deliver": job.get("failure_deliver")}
        updates = {field: "local" for field in rehearsals.DELIVERY if job.get(field) != "local"}
        reason = rehearsals.check_reason(job) or (None if seen else "unwatched")
        name = rehearsals.key(profile, job["id"])
        if updates:
            # Write ahead: the delivery the person set is on disk before Hermes is changed, so a
            # restart in between can't lose it. A waiting check entry is finished on the next tick.
            registry["jobs"][name] = self.entry(profile, job, "waiting", rehearsals.signature(job, hasher, saved),
                                                now, kind="check" if reason else "rehearse", saved=saved, since=since)
            rehearsals.write(self.root, registry)
            updated = self.jobs.update(profile, job["id"], updates)
            if updated is None:
                return True
            job = updated
        current = rehearsals.signature(job, hasher, saved)
        if reason is None:
            registry["jobs"][name] = self.entry(profile, job, "waiting", current, now, saved=saved, since=since)
            return True
        self.jobs.pause(profile, job["id"], CHECK)
        script = job.get("script") or job.get("monitor_script")
        post = check_post(profile=profile, bot_name=bot_name(self.jobs, profile), job=job, reason=reason,
                          script_hash=hasher(script) if script else None, signature=current, now=now,
                          private=private, redactor=self.redactor)
        self.posts.put(post)
        entry = self.entry(profile, job, "ready", current, now, kind="check", saved=saved, since=since)
        entry["post_id"] = post["id"]
        registry["jobs"][name] = entry
        return True

    def sweep_job(self, registry, profile, job, hasher, seen, private, now):
        name = rehearsals.key(profile, job["id"])
        entry = registry["jobs"].get(name)
        if entry is None and job.get("enabled") is False:
            # A paused job can't run, so it is left exactly as it is. Board follow-through makes its
            # job paused and binds it seconds later; holding it in between would bind the local route.
            # If it is resumed unbound, its runs rehearse silently until a sweep holds it.
            return False
        if entry is None:
            # A job made a moment ago may already have rehearsed: look back to when it was made.
            created = parse_time(job.get("created_at"))
            since = min(now, created) if created else now - 60
            return self.hold(registry, profile, job, hasher, seen, private, now, since=since)
        if entry["state"] == "on":
            if entry["signature"] == rehearsals.signature(job, hasher):
                return False
            return self.hold(registry, profile, job, hasher, seen, private, now)
        saved = entry.get("saved") or {"deliver": job.get("deliver"), "failure_deliver": job.get("failure_deliver")}
        for field in rehearsals.DELIVERY:
            if job.get(field) != "local":
                # Someone set a delivery while it was held: that is the one to restore later.
                saved = dict(saved, **{field: job.get(field)})
        current = rehearsals.signature(job, hasher, saved)
        if entry["state"] in ("ready", "kept_off"):
            if current == entry["signature"]:
                return False
            if entry.get("post_id"):
                self.posts.update(entry["post_id"], state="changed")
            # Held again like a new one: the entry is written first, then the delivery goes back to local.
            return self.hold(registry, profile, job, hasher, seen, private, now, saved=saved)
        # Waiting: keep it held, then look for a finished rehearsal.
        if entry["kind"] == "check":
            # Its hold was cut short before the pause and the card: finish it now.
            return self.hold(registry, profile, job, hasher, seen, private, now, saved=saved,
                             since=entry.get("since", now))
        if current != entry["signature"] or saved != entry.get("saved"):
            return self.hold(registry, profile, job, hasher, seen, private, now, saved=saved,
                             since=now if current != entry["signature"] else entry.get("since", now))
        if not seen:
            return self.hold(registry, profile, job, hasher, seen, private, now, saved=saved,
                             since=entry.get("since", now))
        return self.finish(registry, entry, profile, job, hasher, private, now)

    def finish(self, registry, entry, profile, job, hasher, private, now):
        """Report a rehearsal run that ended, and pause its schedule until the person decides."""
        since = int(entry.get("since") or entry["updated_at"])
        runs = assemble(read_lines(self.root, profile, since - 5, now + 1))
        tried = sorted((r for r in runs.values() if (r["start"] or {}).get("rehearsal")
                        and r["start"].get("job_id") == job["id"]), key=lambda r: r["start"]["at"])
        last_run = parse_time(job.get("last_run_at"))
        for run in tried:
            finished = run["end"] is not None
            stopped = (not finished and last_run is not None and last_run > run["start"]["at"]
                       and job.get("state") != "running")
            if not (finished or stopped):
                continue
            post = rehearsal_post(profile=profile, bot_name=bot_name(self.jobs, profile), job=job, run=run,
                                  now=now, finished=finished, private=private, redactor=self.redactor)
            self.posts.put(post)
            self.jobs.pause(profile, job["id"], REHEARSED)
            entry.update(state="ready", execution_id=run["start"].get("execution_id"), post_id=post["id"],
                         updated_at=now)
            return True
        if not tried and last_run is not None and last_run > since:
            # It ran without a recorder watching, so nothing was held. Stop it and ask.
            return self.hold(registry, profile, job, hasher, False, private, now,
                             saved=entry.get("saved"), since=entry.get("since"))
        return False

    # Morning card ------------------------------------------------------------------------

    def morning(self, bots, private, settings, now):
        local = datetime.fromtimestamp(now)
        if local.hour < settings.get("morning_hour", 7):
            return
        day = local.date().isoformat()
        if self.posts.get("night-" + day) is not None:
            return
        earlier = [p for p in self.posts.all() if p["kind"] == "night_shift"]
        start = earlier[-1]["window"]["to"] if earlier and isinstance(earlier[-1].get("window"), dict) else now - 43200
        start = max(int(start), now - 86400)
        self.fold(bots, now)
        info = {}
        for profile in bots:
            try:
                jobs = self.jobs.jobs(profile)
            except Exception:
                jobs = []
            info[profile] = {"name": bot_name(self.jobs, profile), "lines": read_lines(self.root, profile, start, now + 1),
                             "jobs": jobs, "unrecorded": read_unrecorded(self.root, profile, start, now + 1),
                             "watched": self.watching(profile)}
        unwatched = [info[p]["name"] for p in bots if not info[p]["watched"]]
        post = night_card(day=day, window=(start, now), bots=info, outcomes=self.outcomes.read(),
                          grants=self.grants.read(), unwatched=unwatched, private=private, redactor=self.redactor)
        self.posts.put(post)

    # Housekeeping ------------------------------------------------------------------------

    def fold(self, bots, now):
        """Copy Always answers out of the day files before those are pruned."""
        for profile in bots:
            start = self.folded.get(profile, now - KEEP_DAYS * 86400)
            lines = [line for line in read_lines(self.root, profile, start, now + 1) if line["event"] == "always"]
            if lines:
                self.grants.merge([GrantLog.from_line(profile, line) for line in lines])
            self.folded[profile] = now + 1

    def housekeeping(self, bots, private, now):
        self.fold(bots, now)
        oldest = local_day(now - KEEP_DAYS * 86400)
        folder = self.root / RECEIPTS
        try:
            names = [p.name for p in folder.iterdir()] if folder.is_dir() and not folder.is_symlink() else []
        except OSError:
            names = []
        for name in names:
            path = folder / name
            if private_bots.excluded(name, private) or not private_bots.PROFILE_NAME.match(name):
                if path.is_symlink() or path.is_file():
                    path.unlink(missing_ok=True)
                else:
                    shutil.rmtree(path, ignore_errors=True)
                continue
            for day, file in day_files(self.root, name):
                if day < oldest:
                    file.unlink(missing_ok=True)
        for profile in private | private_bots.carried_over_names():
            (self.root / RECORDERS / (profile + ".json")).unlink(missing_ok=True)
        self.housekept = now


# The two card actions ---------------------------------------------------------------------

def _entry_for(registry, post_id):
    return next((e for e in registry["jobs"].values() if e.get("post_id") == post_id), None)


def _one_off_passed(job, now):
    schedule = job.get("schedule") or {}
    if schedule.get("kind") != "once":
        return False
    at = parse_time(schedule.get("run_at"))
    return at is None or at <= now


def turn_on(home, post_id, jobs, *, now=time.time):
    """Run the schedule for real from now on. LookupError: unknown. Conflict: changed or wrong state."""
    root = Path(home) / "nollie-workflow"
    store = PostStore(root, now)
    with file_lock(root / rehearsals.LOCK_NAME):
        registry = rehearsals.read(root)
        post = store.get(post_id)
        entry = _entry_for(registry or rehearsals.empty(), post_id)
        if post is None or entry is None:
            raise LookupError(post_id)
        if entry["state"] not in ("ready", "kept_off"):
            raise Conflict(post)
        profile, job_id = entry["profile"], entry["job_id"]
        job = jobs.get(profile, job_id)
        if job is None:
            raise LookupError(post_id)
        hasher = jobs.file_hash(profile)
        current = rehearsals.signature(job, hasher, entry.get("saved"))
        stamp = int(now())
        if current != entry["signature"]:
            if entry["kind"] == "rehearse":
                _rehearse_again(root, registry, entry, jobs, job, hasher, stamp)
            raise Conflict(store.update(post_id, state="changed"))
        if _one_off_passed(job, stamp):
            raise Conflict(post)
        saved = entry.get("saved") or {}
        restore = {field: saved.get(field) for field in rehearsals.DELIVERY if job.get(field) == "local"
                   and saved.get(field) != "local"}
        if restore and jobs.update(profile, job_id, restore) is None:
            raise RuntimeError("delivery was not restored")
        try:
            resumed = jobs.resume(profile, job_id)
        except Exception:
            resumed = None
        if resumed is None:
            if restore:
                try:
                    jobs.update(profile, job_id, {field: "local" for field in restore})
                except Exception:
                    pass
            raise RuntimeError("schedule was not resumed")  # The card stays as it was: a tap can try again.
        entry.update(state="on", saved=None, updated_at=stamp)
        rehearsals.write(root, registry)
        return store.update(post_id, state="on")


def _rehearse_again(root, registry, entry, jobs, job, hasher, stamp):
    """The person asked to turn on a schedule that changed: hold it again, then let it run once more.

    A delivery set since is saved and set to ``local`` before the resume, so the next run is a
    rehearsal that can't reach the chat.
    """
    profile, job_id = entry["profile"], entry["job_id"]
    if rehearsals.check_reason(job) or not watching(root, profile, jobs):
        # It now needs a look first (a script, a one-off) or nothing would watch it: it stays paused,
        # and with its old signature the sweep holds it again and posts a check card.
        entry.update(state="waiting", since=stamp, updated_at=stamp, execution_id=None)
        rehearsals.write(root, registry)
        return
    saved = dict(entry.get("saved") or {})
    for field in rehearsals.DELIVERY:
        if job.get(field) != "local":
            saved[field] = job.get(field)
    entry.update(state="waiting", signature=rehearsals.signature(job, hasher, saved), saved=saved, since=stamp,
                 updated_at=stamp, execution_id=None)
    rehearsals.write(root, registry)
    updates = {field: "local" for field in rehearsals.DELIVERY if job.get(field) != "local"}
    try:
        if updates and jobs.update(profile, job_id, updates) is None:
            return
        jobs.resume(profile, job_id)
    except Exception:
        pass  # Still held and paused: the sweep keeps it so.


def keep_off(home, post_id, jobs, *, now=time.time):
    """Leave the schedule paused. LookupError: unknown. Conflict: wrong state."""
    root = Path(home) / "nollie-workflow"
    store = PostStore(root, now)
    with file_lock(root / rehearsals.LOCK_NAME):
        registry = rehearsals.read(root)
        post = store.get(post_id)
        entry = _entry_for(registry or rehearsals.empty(), post_id)
        if post is None or entry is None:
            raise LookupError(post_id)
        if entry["state"] not in ("ready", "kept_off"):
            raise Conflict(post)
        entry.update(state="kept_off", updated_at=int(now()))
        rehearsals.write(root, registry)
        try:
            jobs.pause(entry["profile"], entry["job_id"], REHEARSED)
        except Exception:
            pass
        return store.update(post_id, state="kept_off")
