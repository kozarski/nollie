"""The morning card and the rehearsal reports, built from receipts, Board outcomes and jobs.

Pure builders plus the small stores they read: the settings file, the receipt day files, the
Board outcome log and the log of Always answers. Every store is versioned JSON checked on read.
"""
from __future__ import annotations

from datetime import date, datetime, timedelta
import json
import os
from pathlib import Path
import re
import time

from .receipts import HIDDEN, RULE_LIMIT, hermes_redactor, scrub, settle
from .workflow_core import atomic_write, file_lock, private_identity

SETTINGS_NAME = "night-shift.json"
SETTINGS_LOCK = "night-shift.lock"
DEFAULTS = {"version": 1, "night_shift": False, "rehearsals": False, "morning_hour": 7}
RECEIPTS = "receipts"
RECORDERS = "recorders"
EVENTS = frozenset(("start", "call", "result", "end", "always", "reply"))
MAX_ACTIONS = 40
ASK_KINDS = frozenset(("send", "buy", "post", "delete", "unsure"))
MAX_RUNS = 100
MAX_CARD_ACTIONS = 200  # Across one morning card, so one card stays far below the post store's bound.
COUNTS = ("runs", "actions", "held", "stopped", "unrecorded")
MAX_REPLY = 4000
MAX_PROMPT = 2000
OUTCOME_LIMIT = 500
GRANT_LIMIT = 500
QUIET = "Quiet night. Nothing ran."
# Hermes counts a run as late past five minutes (cron/jobs.py, _LATE_DISPATCH_TOLERANCE_SECONDS).
LATE_SECONDS = 300
# A schedule's missed times within one gap that the card lists, at most.
MAX_MISSED = 50
UNFINISHED = "The rehearsal did not finish."
BOARD_OUTCOMES = {"completed": "done", "blocked": "stopped", "gave_up": "failed",
                  "block_loop_detected": "failed", "escalated": "failed"}
SAFE_ID = re.compile(r"[^A-Za-z0-9_-]+")
DAY_FILE = re.compile(r"(\d{4}-\d{2}-\d{2})(?:\.jsonl|\.unrecorded\.json)\Z")


# Settings ---------------------------------------------------------------------------------------

def parse_settings(document):
    """Valid settings, or ValueError."""
    if not isinstance(document, dict) or document.get("version") != 1:
        raise ValueError("invalid night shift settings")
    hour = document.get("morning_hour", 7)
    since = document.get("rehearsals_since")
    if (type(document.get("night_shift")) is not bool or type(document.get("rehearsals")) is not bool
            or type(hour) is not int or not 0 <= hour <= 23 or not (since is None or type(since) is int)):
        raise ValueError("invalid night shift settings")
    return {"version": 1, "night_shift": document["night_shift"], "rehearsals": document["rehearsals"],
            "morning_hour": hour, "rehearsals_since": since}


def read_settings(root):
    """The settings, None when there is no file, or ValueError when it is damaged."""
    path = Path(root) / SETTINGS_NAME
    try:
        if path.is_symlink() or path.stat().st_size > 4096:
            raise ValueError("invalid night shift settings")
        return parse_settings(json.loads(path.read_text()))
    except FileNotFoundError:
        return None
    except UnicodeDecodeError:
        raise ValueError("invalid night shift settings") from None


def write_settings(root, **changes):
    """Change the settings under their lock. A damaged file is replaced by a whole new one."""
    root = Path(root)
    with file_lock(root / SETTINGS_LOCK):
        try:
            current = read_settings(root) or dict(DEFAULTS, rehearsals_since=None)
        except ValueError:
            current = dict(DEFAULTS, rehearsals_since=None)
        if changes.get("rehearsals") and not current["rehearsals"]:
            changes.setdefault("rehearsals_since", int(time.time()))
        updated = parse_settings(dict(current, **changes))
        atomic_write(root / SETTINGS_NAME, updated)
        return updated


class Settings:
    """Settings read at most every ``interval`` seconds, and only again when the file changed.

    No file means both features are off. A damaged file means both are on with the last good
    values, so a broken file never turns protection off.
    """

    def __init__(self, root, interval=10.0, clock=time.monotonic):
        self.path = Path(root) / SETTINGS_NAME
        self.root, self.interval, self.clock = Path(root), interval, clock
        self.checked = None
        self.stamp = None
        self.value = None
        self.good = None

    def get(self):
        now = self.clock()
        if self.checked is not None and now - self.checked < self.interval:
            return self.value
        self.checked = now
        try:
            info = self.path.stat()
            stamp = (info.st_mtime_ns, info.st_size, info.st_ino)
        except FileNotFoundError:
            self.stamp, self.value = None, dict(DEFAULTS, rehearsals_since=None, damaged=False)
            return self.value
        except OSError:
            stamp = ("unreadable",)
        if stamp == self.stamp and self.value is not None:
            return self.value
        self.stamp = stamp
        try:
            value = read_settings(self.root)
            if value is None:
                value = dict(DEFAULTS, rehearsals_since=None)
            self.good = value
            self.value = dict(value, damaged=False)
        except (OSError, ValueError):
            good = self.good or dict(DEFAULTS, rehearsals_since=None)
            self.value = dict(good, night_shift=True, rehearsals=True, damaged=True)
        return self.value


# Receipt files ----------------------------------------------------------------------------------

def local_day(at):
    return datetime.fromtimestamp(at).date().isoformat()


def receipts_dir(root, profile):
    return Path(root) / RECEIPTS / profile


def valid_line(line):
    return (isinstance(line, dict) and line.get("v") == 1 and type(line.get("at")) is int
            and isinstance(line.get("run"), str) and line.get("event") in EVENTS)


def _days(start, end):
    day, last = date.fromisoformat(local_day(start)), date.fromisoformat(local_day(max(start, end)))
    while day <= last:
        yield day.isoformat()
        day += timedelta(days=1)


def read_lines(root, profile, start, end):
    """Every whole receipt line of one bot with ``start <= at < end``, oldest first."""
    folder = receipts_dir(root, profile)
    if folder.is_symlink():
        return []
    lines = []
    for day in _days(start, end):
        path = folder / (day + ".jsonl")
        try:
            if path.is_symlink():
                continue
            with path.open("rb") as handle:
                raw = handle.read()
        except OSError:
            continue
        for row in raw.splitlines():
            try:
                line = json.loads(row)
            except ValueError:
                continue
            if valid_line(line) and start <= line["at"] < end:
                lines.append(line)
    lines.sort(key=lambda line: line["at"])
    return lines


def read_unrecorded(root, profile, start, end):
    """Lines the recorder had to drop, per run, for runs that started in the window."""
    folder = receipts_dir(root, profile)
    counts = {}
    for day in _days(start, end):
        try:
            document = json.loads((folder / (day + ".unrecorded.json")).read_text())
        except (OSError, ValueError):
            continue
        runs = document.get("runs") if isinstance(document, dict) and document.get("version") == 1 else None
        for run, item in (runs or {}).items():
            if (isinstance(item, dict) and type(item.get("count")) is int and type(item.get("at")) is int
                    and start <= item["at"] < end):
                counts[run] = counts.get(run, 0) + item["count"]
    return counts


def day_files(root, profile):
    """(day, path) for each day file of one bot."""
    folder = receipts_dir(root, profile)
    try:
        entries = list(os.scandir(folder))
    except OSError:
        return []
    found = []
    for entry in entries:
        match = DAY_FILE.match(entry.name)
        if match:
            found.append((match.group(1), Path(entry.path)))
    return found


# Small logs -------------------------------------------------------------------------------------

class _BoundedLog:
    FILE = LOCK = FIELD = None
    LIMIT = 500

    def __init__(self, root):
        self.root = Path(root)

    def read(self):
        path = self.root / self.FILE
        try:
            if path.is_symlink():
                return []
            document = json.loads(path.read_text())
        except (OSError, ValueError):
            return []
        items = document.get(self.FIELD) if isinstance(document, dict) and document.get("version") == 1 else None
        return [item for item in items or [] if self.valid(item)]

    def merge(self, new):
        with file_lock(self.root / self.LOCK):
            items = self.read()
            seen = {self.identity(item) for item in items}
            added = [item for item in new if self.valid(item) and self.identity(item) not in seen]
            if not added:
                return False
            items = sorted(items + added, key=lambda item: item["at"])[-self.LIMIT:]
            atomic_write(self.root / self.FILE, {"version": 1, self.FIELD: items})
            return True


class OutcomeLog(_BoundedLog):
    """Board outcomes the add-on followed, the newest 500."""
    FILE, LOCK, FIELD, LIMIT = "outcomes.json", "outcomes.lock", "outcomes", OUTCOME_LIMIT

    @staticmethod
    def valid(item):
        return (isinstance(item, dict) and item.get("outcome") in BOARD_OUTCOMES and type(item.get("at")) is int
                and all(isinstance(item.get(k), str) for k in ("board", "task_id", "title", "assignee")))

    @staticmethod
    def identity(item):
        return (item["board"], item["task_id"], item.get("event_id"))

    def add(self, record, kind):
        if kind not in BOARD_OUTCOMES:
            return False
        task, event = record["task"], record["event"]
        return self.merge([{"board": str(record["board"]), "task_id": str(task.get("id")),
                            "title": scrub(task.get("title") or "", hermes_redactor(), 240),
                            "assignee": str(task.get("assignee") or ""),
                            "outcome": kind, "at": int(event.get("created_at") or 0), "event_id": event.get("id")}])


class GrantLog(_BoundedLog):
    """The Always answers the recorders saw, the newest 500, kept past the receipts' 14 days."""
    FILE, LOCK, FIELD, LIMIT = "always.json", "always.lock", "grants", GRANT_LIMIT

    @staticmethod
    def valid(item):
        return (isinstance(item, dict) and isinstance(item.get("bot"), str) and type(item.get("at")) is int
                and isinstance(item.get("keys"), list) and all(isinstance(k, str) for k in item["keys"]))

    @staticmethod
    def identity(item):
        return (item["bot"], item["at"], tuple(item["keys"]))

    @staticmethod
    def from_line(bot, line):
        return {"bot": bot, "at": line["at"], "keys": [k for k in line.get("keys") or [] if isinstance(k, str)][:8],
                "detail": str(line.get("detail") or "")[:300]}


def granted_at(grants, bot, key, before):
    times = [g["at"] for g in grants if g["bot"] == bot and key in g["keys"] and g["at"] <= before]
    return max(times) if times else None


# Builders ---------------------------------------------------------------------------------------

def clean(text, private, limit=None):
    """Stored text again checked for private bots: any text naming one is hidden whole."""
    text = "" if text is None else str(text)
    if private_identity(text, private):
        return HIDDEN
    return text[:limit] if limit else text


PLAIN_FIELDS = frozenset(("id", "kind", "state", "outcome", "status", "tool", "reason", "hash", "job_id", "bot",
                          "ask"))


def without_private(value, private):
    """A post again checked at read time, for bots marked Private after it was made."""
    if isinstance(value, dict):
        return {k: v if k in PLAIN_FIELDS else without_private(v, private) for k, v in value.items()}
    if isinstance(value, list):
        return [without_private(v, private) for v in value]
    if isinstance(value, str) and private_identity(value, private):
        return HIDDEN
    return value


def safe_id(value, limit=64):
    return SAFE_ID.sub("-", str(value or ""))[:limit].strip("-") or "run"


def parse_time(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


def schedule_text(job):
    schedule = job.get("schedule") or {}
    return str(job.get("schedule_display") or schedule.get("display") or schedule.get("expr") or "")[:120]


def assemble(lines):
    """Receipt lines of one bot grouped into runs, each with its raw calls matched to results."""
    runs = {}
    for line in lines:
        event = line["event"]
        if event == "always":
            continue  # A person's Always answer, kept for GrantLog: not a run.
        run = runs.setdefault(line["run"], {"id": line["run"], "start": None, "end": None, "reply": None,
                                            "calls": [], "first": line["at"], "last": line["at"]})
        run["last"] = max(run["last"], line["at"])
        if event == "start" and run["start"] is None:
            run["start"] = line
        elif event == "end":
            run["end"] = line
        elif event == "reply" and run["reply"] is None:
            run["reply"] = line.get("text")
        elif event == "call":
            run["calls"].append({"line": line, "result": None})
        elif event == "result":
            calls = run["calls"]
            match = next((c for c in calls if c["result"] is None and line.get("call")
                          and c["line"].get("call") == line.get("call")), None)
            match = match or next((c for c in reversed(calls) if c["result"] is None
                                   and c["line"].get("tool") == line.get("tool")), None)
            if match:
                match["result"] = line
    return runs


def action(call, bot, grants, private):
    line, result = call["line"], call["result"]
    status = result.get("status") if result and result.get("status") in ("done", "failed", "blocked") else "failed"
    raw = line.get("receipt") if isinstance(line.get("receipt"), dict) else {"kind": "unknown"}
    block = result.get("block") if result else None
    if result is None and raw.get("kind") == "held" and raw.get("detail") == "ask_first":
        # Ask first holds these whatever the screen shows: no result line means not done.
        status, block = "blocked", "ask_first"
    receipt = settle(raw, status, block)
    if receipt.get("kind") == "always":
        at = granted_at(grants, bot, raw.get("key"), line["at"]) if raw.get("key") else None
        if at is not None:
            receipt["granted_at"] = at
    if "detail" in receipt:
        receipt["detail"] = clean(receipt["detail"], private, 300)
    found = reasons(receipt, private)
    for key in ("rule", "ask"):
        receipt.pop(key, None)
    receipt.update(found)
    return {"tool": str(line.get("tool") or "")[:80], "target": clean(line.get("target"), private, 300),
            "status": status, "at": line["at"], "receipt": receipt}


def reasons(receipt, private):
    """The deciding rule's words and what Ask first held a call for, checked again for private bots. A receipt
    from before they were kept has neither, and the app says the reason wasn't kept."""
    found = {}
    if isinstance(receipt.get("rule"), str) and receipt["rule"]:
        found["rule"] = clean(receipt["rule"], private, RULE_LIMIT)
    if receipt.get("ask") in ASK_KINDS:
        found["ask"] = receipt["ask"]
    return found


def run_kind(run_id, start):
    kind = (start or {}).get("kind")
    if kind in ("schedule", "board", "helper"):
        return kind
    return {"cron": "schedule", "board": "board"}.get(run_id.split(":", 1)[0], "helper")


def run_card(run, bot, bot_name, jobs, grants, private, titles=None, redactor=None):
    start, end = run["start"] or {}, run["end"] or {}
    kind = run_kind(run["id"], start)
    job = jobs.get(start.get("job_id")) or {}
    default = {"schedule": "Schedule", "board": "Board task", "helper": "Helper"}[kind]
    title = (start.get("title") or scrub(job.get("name") or "", redactor, 240) or (titles or {}).get(run["id"])
             or default)
    if start.get("rehearsal"):
        outcome = "rehearsal"
    else:
        outcome = end.get("outcome") if end.get("outcome") in ("done", "failed", "stopped") else "failed"
    actions = [action(c, bot, grants, private) for c in run["calls"]]
    card = {"id": run["id"], "kind": kind, "bot": bot, "bot_name": bot_name, "title": clean(title, private, 240),
            "outcome": outcome, "started_at": start.get("at", run["first"]), "finished_at": end.get("at", run["last"]),
            "actions": actions[:MAX_ACTIONS], "more": max(0, len(actions) - MAX_ACTIONS), "_all": actions}
    return with_due(card, start.get("due_at"))


def with_due(card, due):
    """The time a schedule run was due, and whether it started late, as Hermes counts late."""
    if type(due) is int and due > 0:
        card["due_at"] = due
        if card["started_at"] - due > LATE_SECONDS:
            card["late"] = True
    return card


def dispatched_due(job, ran):
    """When Hermes says the job's last run was due, if that run is the one at ``ran``."""
    dispatch = job.get("last_dispatch") if isinstance(job.get("last_dispatch"), dict) else {}
    due, sent = parse_time(dispatch.get("scheduled_at")), parse_time(dispatch.get("dispatched_at"))
    if due is None or sent is None or ran is None or not sent - 60 <= ran:
        return None
    return due


def occurrences(after, start, end, limit=MAX_MISSED):
    """Due times in ``[start, end)``: ``after(t)`` is the schedule's next time after ``t``, or None."""
    times, moment = [], start - 1
    while len(times) < limit:
        try:
            following = after(moment)
        except Exception:
            break
        if following is None or following >= end or following <= moment:
            break
        moment = following
        if moment >= start:
            times.append(moment)
    return times


def missed_times(dues, runs):
    """The due times in a gap that no run stood for, given the runs that were due in a gap. Hermes runs a missed schedule once when the Mac
    wakes, for the first time it missed, and skips the rest."""
    left = sorted(dues)
    for run in sorted(runs, key=lambda r: r["due_at"]):
        if not left:
            break
        # The same time, or for an interval schedule counted from the gap's start, the nearest one.
        left.remove(min(left, key=lambda d: abs(d - run["due_at"])))
    return left


def night_card(*, day, window, bots, outcomes, grants, unwatched, private, redactor=None, sleep=()):
    """The morning card. ``bots`` maps each followed bot to its name, receipt lines, jobs and drops,
    and ``due``: each schedule's due times inside ``sleep``, the gaps when the Mac was asleep or off.

    ``by_bot`` keeps the counts per bot, so the routes can count again without a bot marked
    Private later; they never send it.
    """
    start, end = window
    private = frozenset(private)
    runs = []
    missed = []
    gaps = [dict(g) for g in sleep if start <= g["to"] and g["from"] < end]
    by_bot = {}
    board_runs = {}
    for bot, info in sorted(bots.items()):
        if private_identity(bot, private):
            continue
        jobs = {job.get("id"): job for job in info.get("jobs", []) if isinstance(job, dict)}
        titles = {f"board:{o['task_id']}": scrub(o["title"], redactor, 240) for o in outcomes
                  if o.get("assignee") == bot}
        seen_jobs = set()
        for run in assemble(info.get("lines", [])).values():
            card = run_card(run, bot, info["name"], jobs, grants, private, titles, redactor)
            if (run["start"] or {}).get("job_id"):
                seen_jobs.add(run["start"]["job_id"])
            elif card["id"].startswith("cron:"):
                seen_jobs.add(card["id"].split(":")[1])
            runs.append(card)
            if card["kind"] == "board":
                board_runs[card["id"]] = card
        for job_id, job in jobs.items():
            ran = parse_time(job.get("last_run_at"))
            if ran is None or not start <= ran < end or job_id in seen_jobs:
                continue
            if info.get("watched", True):
                outcome = "skipped"
            else:
                outcome = "done" if job.get("last_status") in ("ok", "delivery_queued") else "failed"
            runs.append(with_due({"id": f"cron:{job_id}:{ran}", "kind": "schedule", "bot": bot,
                                  "bot_name": info["name"],
                                  "title": clean(scrub(job.get("name") or "Schedule", redactor), private, 240),
                                  "outcome": outcome, "started_at": ran, "finished_at": ran, "actions": [],
                                  "more": 0, "_all": []}, dispatched_due(job, ran)))
        for job_id, dues in sorted((info.get("due") or {}).items()):
            job = jobs.get(job_id)
            if job is None or not dues:
                continue
            ran = [r for r in runs if r["bot"] == bot and r["id"].startswith(f"cron:{job_id}:") and "due_at" in r
                   and any(g["from"] <= r["due_at"] < g["to"] for g in gaps)]
            left = missed_times([d for d in dues if start <= d < end], ran)
            if left:
                missed.append({"bot": bot, "bot_name": info["name"], "job_id": job_id,
                               "title": clean(scrub(job.get("name") or "Schedule", redactor), private, 240),
                               "first_due": left[0], "last_due": left[-1], "count": len(left)})
        dropped = sum(info.get("unrecorded", {}).values())
        if dropped:
            by_bot.setdefault(bot, dict.fromkeys(COUNTS, 0))["unrecorded"] += dropped
    for item in outcomes:
        if not start <= item["at"] < end or any(private_identity(item.get(k), private)
                                                for k in ("board", "assignee", "title")):
            continue
        if item["assignee"] not in bots:
            continue
        run_id = f"board:{item['task_id']}"
        card = board_runs.get(run_id)
        title = clean(scrub(item["title"], redactor, 240), private, 240)
        if card is None:
            card = {"id": run_id, "kind": "board", "bot": item["assignee"],
                    "bot_name": bots[item["assignee"]]["name"], "title": title,
                    "started_at": item["at"], "finished_at": item["at"], "actions": [], "more": 0, "_all": []}
            board_runs[run_id] = card
            runs.append(card)
        card["outcome"] = BOARD_OUTCOMES[item["outcome"]]
        card["title"] = title or card["title"]
        card["finished_at"] = max(card["finished_at"], item["at"])
    runs.sort(key=lambda r: (r["started_at"], r["id"]))
    for run in runs:
        every = run.pop("_all")
        slot = by_bot.setdefault(run["bot"], dict.fromkeys(COUNTS, 0))
        slot["runs"] += 1
        slot["actions"] += len(every)
        slot["held"] += sum(a["receipt"]["kind"] == "held" for a in every)
        slot["stopped"] += sum(a["receipt"]["kind"] == "blocked" for a in every)
    counts = {name: sum(slot[name] for slot in by_bot.values()) for name in COUNTS}
    shown = runs[:MAX_RUNS]
    budget = MAX_CARD_ACTIONS
    for run in shown:
        keep = min(len(run["actions"]), budget)
        run["more"] += len(run["actions"]) - keep
        run["actions"] = run["actions"][:keep]
        budget -= keep
    post = {"id": "night-" + day, "kind": "night_shift", "at": end, "window": {"from": start, "to": end},
            "counts": counts, "unwatched": sorted(clean(n, private) for n in unwatched), "runs": shown,
            "by_bot": by_bot}
    if gaps:
        post["sleep"] = [{"from": max(g["from"], start), "to": min(g["to"], end), "kind": g["kind"]} for g in gaps]
    if missed:
        post["missed"] = sorted(missed, key=lambda m: (m["first_due"], m["bot"], m["job_id"]))[:MAX_RUNS]
    if len(runs) > MAX_RUNS:
        post["more_runs"] = len(runs) - MAX_RUNS
    if not runs:
        post["note"] = QUIET
    return post


def rehearsal_id(profile, job_id, execution_id):
    return f"rehearsal-{profile}-{safe_id(job_id)}-{safe_id(execution_id)}"


def rehearsal_post(*, profile, bot_name, job, run, now, finished, private, redactor=None):
    """The report of one rehearsal run: what it would have done, what it looked at, its reply."""
    private = frozenset(private)
    held, looked = [], []
    for call in run["calls"]:
        item = action(call, profile, [], private)
        status, receipt = item["status"], item["receipt"]
        raw = call["line"].get("receipt") if isinstance(call["line"].get("receipt"), dict) else {}
        if call["result"] is None and raw.get("kind") in ("held", "blocked"):
            # No result line, but the guard stopped it before it could run.
            status, receipt = "blocked", {"kind": raw["kind"]}
            if raw["kind"] == "blocked":
                receipt["detail"] = clean(raw.get("detail") or "other", private, 300)
            elif raw.get("detail"):
                receipt["detail"] = clean(raw["detail"], private, 300)
            receipt.update(reasons(raw, private))
        entry = {"tool": item["tool"], "target": item["target"], "at": item["at"], "status": status,
                 "receipt": receipt}
        # Sorted by what stopped it, not by how it ended: a look that failed still ran.
        (held if receipt.get("kind") in ("held", "blocked") else looked).append(entry)
    start = run["start"] or {}
    reply = scrub(run.get("reply") or "", redactor, MAX_REPLY)
    post = {"id": rehearsal_id(profile, job.get("id"), start.get("execution_id") or run["id"].rsplit(":", 1)[-1]),
            "kind": "rehearsal", "at": now, "bot": profile, "bot_name": bot_name, "job_id": job.get("id"),
            "title": clean(scrub(job.get("name") or start.get("title") or "Schedule", redactor), private, 240),
            "schedule": schedule_text(job), "state": "ready", "check": None,
            "outcome": "done" if finished and (run["end"] or {}).get("outcome") == "done" else "failed",
            "held": held[:MAX_ACTIONS], "looked": looked[:MAX_ACTIONS], "reply": clean(reply, private, MAX_REPLY)}
    if not finished:
        post["note"] = UNFINISHED
    return post


def check_post(*, profile, bot_name, job, reason, script_hash, signature, now, private, redactor=None):
    """A card for a job Nollie can't rehearse: what it will do, and Turn on."""
    private = frozenset(private)
    script = job.get("script") or job.get("monitor_script") or job.get("monitor_url")
    return {"id": f"check-{profile}-{safe_id(job.get('id'))}-{signature[:8]}", "kind": "rehearsal", "at": now,
            "bot": profile, "bot_name": bot_name, "job_id": job.get("id"),
            "title": clean(scrub(job.get("name") or "Schedule", redactor), private, 240),
            "schedule": schedule_text(job), "state": "ready",
            "check": {"reason": reason, "prompt": clean(scrub(job.get("prompt") or "", redactor), private, MAX_PROMPT),
                      "script": clean(scrub(script, redactor), private, 300) if script else None,
                      "hash": script_hash[:12] if script_hash and script_hash != "missing" else None},
            "outcome": None, "held": [], "looked": [], "reply": ""}
