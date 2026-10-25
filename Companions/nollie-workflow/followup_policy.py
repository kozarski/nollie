"""Typed checkpoints and watch state; Hermes remains the only scheduler."""
from __future__ import annotations

from datetime import date, datetime, time, timedelta, timezone
import hashlib
import json
from pathlib import Path
import re
from zoneinfo import ZoneInfo

from . import private_bots
from .workflow_core import atomic_write, file_lock, private_identity


def identity(board, task_id):
    """The stable key for one task. Followups.key also refuses a private board or task."""
    if any(not isinstance(v, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,120}", v) for v in (board, task_id)):
        raise ValueError("invalid task identity")
    return hashlib.sha256(json.dumps([board, task_id], separators=(",", ":")).encode()).hexdigest()


def text(value, limit=2000):
    if not isinstance(value, str) or not value.strip() or len(value.encode()) > limit:
        raise ValueError("missing or oversized evidence")
    return value.strip()


def calendar(spec, now):
    """Calendar days, not elapsed hours: a London 09:00 check stays at 09:00 at DST."""
    zone = ZoneInfo(spec["timezone"])
    anchor = date.fromisoformat(spec["anchor_date"])
    end = date.fromisoformat(spec["stop_date"])
    days = spec["every_days"]
    if type(days) is not int or not 1 <= days <= 365 or end < anchor:
        raise ValueError("invalid watch dates")
    clock = time.fromisoformat(spec["at"])
    if clock.tzinfo or clock.second or clock.microsecond:
        raise ValueError("watch time must be local hours and minutes")
    local = datetime.fromtimestamp(now, zone)
    delta = (local.date() - anchor).days
    cycle = delta // days
    due_date = anchor + timedelta(days=cycle * days)
    due = datetime.combine(due_date, clock, zone)
    if local < due:
        cycle -= 1
        due_date = anchor + timedelta(days=cycle * days)
        due = datetime.combine(due_date, clock, zone)
    expired = local.date() >= end
    next_date = anchor + timedelta(days=max(cycle + 1, 0) * days)
    next_check = datetime.combine(next_date, clock, zone)
    return {"cycle": cycle, "due_at": due.isoformat(), "expired": expired,
            "next_check_at": None if next_date >= end else next_check.isoformat()}


def route_signature(job):
    # A route or prompt edit requires explicit rebinding. Never store credentials or full prompts.
    fields = ("id", "model", "provider", "base_url", "deliver", "failure_deliver", "prompt", "schedule",
              "skills", "skill", "context_from", "workdir", "interpreter", "no_agent",
              "monitor_script", "monitor_url", "reasoning_effort", "enabled_toolsets", "attach_to_session", "origin")
    authored = {k: job.get(k) for k in fields}
    authored["repeat_times"] = (job.get("repeat") or {}).get("times")
    return hashlib.sha256(json.dumps(authored, sort_keys=True,
                                    separators=(",", ":")).encode()).hexdigest()


class Followups:
    def __init__(self, root, jobs, task_lookup, now=None, private=None):
        self.root, self.jobs = Path(root), jobs
        self.task_lookup = task_lookup
        self.now = now or (lambda: datetime.now(timezone.utc).timestamp())
        # The Private list lives in the main home, the parent of this companion's state folder.
        self.private = private or (lambda: private_bots.names(self.root.parent))

    def key(self, board, task_id):
        key = identity(board, task_id)
        private = self.private()
        if any(private_identity(v, private) for v in (board, task_id)):
            raise ValueError("invalid task identity")
        return key

    def _load(self):
        path = self.root / "followups.json"
        if path.is_symlink() or self.root.is_symlink():
            raise ValueError("linked follow-up state")
        if not path.exists():
            return {"version": 1, "tasks": {}}
        if path.stat().st_size > 4_000_000:
            raise ValueError("oversized follow-up state")
        state = json.loads(path.read_text())
        if state.get("version") != 1 or not isinstance(state.get("tasks"), dict):
            raise ValueError("invalid follow-up state")
        return state

    def _task(self, board, task_id):
        key = self.key(board, task_id)
        task = self.task_lookup(board, task_id)
        if not task:
            raise ValueError("task is unavailable")
        return key, task

    def _save(self, state):
        atomic_write(self.root / "followups.json", state)

    def bind_watch(self, board, task_id, job_id, request, constraints, spec, script):
        key, task = self._task(board, task_id)
        if task.get("status") == "archived":
            raise ValueError("archived task")
        request, constraints = text(request), text(constraints)
        if set(spec) != {"timezone", "anchor_date", "stop_date", "every_days", "at"}:
            raise ValueError("invalid watch cadence")
        cal = calendar(spec, self.now())
        if cal["expired"]:
            raise ValueError("watch deadline has passed")
        job = self.jobs.get(job_id)
        hour, minute = time.fromisoformat(spec["at"]).hour, time.fromisoformat(spec["at"]).minute
        if (not job or job.get("id") != job_id or job.get("state") != "paused"
                or job.get("enabled") is not False or job.get("no_agent")
                or job.get("monitor_script") or job.get("monitor_url")
                or job.get("script") not in (None, "", script)
                or not job.get("model") or not job.get("provider")
                or (job.get("repeat") or {}).get("times") is not None
                or job.get("schedule", {}).get("kind") != "cron"
                or job.get("schedule", {}).get("expr") != f"{minute} {hour} * * *"):
            raise ValueError("bind a paused daily native job with explicit model and provider pins")
        with file_lock(self.root / "followups.lock"):
            state = self._load()
            old = state["tasks"].get(key, {})
            if old.get("watch", {}).get("state") == "active":
                raise ValueError("stop the existing watch before replacing it")
            if any(t.get("watch", {}).get("job_id") == job_id and k != key
                   for k, t in state["tasks"].items()):
                raise ValueError("job already belongs to another task")
            entry = dict(old, board=board, task_id=task_id)
            entry["watch"] = {"state": "binding", "job_id": job_id, "request": request,
                              "constraints": constraints, "cadence": spec, "script": script,
                              "route": route_signature(job), "last_cycle": -1, "comparisons": {},
                              "history": [], "finished_cycles": {}, "next_check_at": cal["next_check_at"]}
            state["tasks"][key] = entry
            self._save(state)  # A failed native update stays gated, never appears active.
            updated = self.jobs.bind_gate(job_id, entry["watch"]["route"], script)
            if (not updated or updated.get("script") != script or updated.get("precheck_fail_closed") is not True
                    or updated.get("enabled") is not False or updated.get("state") != "paused"
                    or route_signature(updated) != entry["watch"]["route"]):
                raise ValueError("native job binding was not confirmed")
            entry["watch"]["state"] = "active"
            self._save(state)
            return {"job_id": job_id, "state": "paused", "watch": "bound", "next_check_at": cal["next_check_at"],
                    "note": "Resume the same native job only after verifying its chosen route. No check was started."}

    def checkpoint(self, board, task_id, run_id, evidence_ids, findings, remaining, next_action):
        key, task = self._task(board, task_id)
        run_id = text(run_id, 120)
        if (not isinstance(evidence_ids, list) or not 1 <= len(evidence_ids) <= 20
                or len(set(evidence_ids)) != len(evidence_ids)):
            raise ValueError("checkpoint needs distinct verified source result identities")
        ids = [text(v, 240) for v in evidence_ids]
        checkpoint = {"run_id": run_id, "evidence_ids": ids, "findings": text(findings),
                      "remaining": text(remaining), "next_action": text(next_action), "saved_at": self.now()}
        with file_lock(self.root / "followups.lock"):
            state = self._load()
            entry = state["tasks"].setdefault(key, {"board": board, "task_id": task_id})
            known = set(entry.get("evidence_ids", []))
            new_evidence = bool(set(ids) - known)
            entry["checkpoint"] = checkpoint
            # Bound the store. Exhausting the evidence budget never authorizes further continuation.
            if len(known | set(ids)) > 500:
                raise ValueError("checkpoint history requires review")
            entry["evidence_ids"] = sorted(known | set(ids))
            self._save(state)
            return {"saved": True, "new_evidence": new_evidence, "task_status": task.get("status"),
                    "continuation_scheduled": False,
                    "note": "No task was unblocked, restarted or scheduled. Preserve native loop and approval guards."}

    def record_check(self, board, task_id, cycle, comparison_key, facts, sources):
        key, _ = self._task(board, task_id)
        comparison_key = text(comparison_key, 240)
        if (not isinstance(facts, dict) or not facts or len(json.dumps(facts, sort_keys=True, allow_nan=False).encode()) > 2000
                or not isinstance(sources, list) or not 1 <= len(sources) <= 10):
            raise ValueError("a check needs bounded comparable facts and verified sources")
        sources = [text(v, 500) for v in sources]
        with file_lock(self.root / "followups.lock"):
            state = self._load()
            watch = state["tasks"].get(key, {}).get("watch")
            if not watch or watch["state"] != "active":
                raise ValueError("no active watch")
            cal = calendar(watch["cadence"], self.now())
            if type(cycle) is not int or cycle < 0 or cycle > cal["cycle"] or cal["expired"]:
                raise ValueError("invalid or expired check cycle")
            previous = watch["comparisons"].get(comparison_key)
            receipt = {"cycle": cycle, "comparison_key": comparison_key, "facts": facts, "sources": sources,
                       "checked_at": self.now()}
            if any(h["cycle"] == cycle and h["comparison_key"] == comparison_key for h in watch["history"]):
                old = next(h for h in watch["history"] if h["cycle"] == cycle and h["comparison_key"] == comparison_key)
                if old["facts"] != facts or old["sources"] != sources:
                    raise ValueError("a check receipt cannot be rewritten")
                return {"recorded": True, "changed": old["changed"], "duplicate": True,
                        "watch_state": "active", "next_check_at": watch["next_check_at"]}
            if str(cycle) in watch["finished_cycles"] or cycle < watch["last_cycle"] or (comparison_key not in watch["comparisons"] and len(watch["comparisons"]) >= 16):
                raise ValueError("stale check or too many comparison groups")
            receipt["changed"] = previous is None or previous["facts"] != facts
            receipt["previous_facts"] = previous["facts"] if previous else None
            watch["comparisons"][comparison_key] = {"baseline": previous["baseline"] if previous else receipt,
                                                     "facts": facts, "last_check_at": receipt["checked_at"]}
            watch["history"] = (watch["history"] + [receipt])[-128:]
            self._save(state)
            return {"recorded": True, "changed": receipt["changed"], "previous_facts": receipt["previous_facts"],
                    "watch_state": "active", "next_check_at": watch["next_check_at"],
                    "cycle_finished": False}

    def finish_check(self, board, task_id, cycle):
        key, _ = self._task(board, task_id)
        with file_lock(self.root / "followups.lock"):
            state = self._load()
            watch = state["tasks"].get(key, {}).get("watch")
            if not watch or watch["state"] != "active" or type(cycle) is not int:
                raise ValueError("no active check")
            cal = calendar(watch["cadence"], self.now())
            observations = [h for h in watch["history"] if h["cycle"] == cycle]
            if not observations or cycle < watch["last_cycle"] or cycle > cal["cycle"] or cal["expired"]:
                raise ValueError("missing or stale check")
            changed = any(h["changed"] for h in observations)
            watch["finished_cycles"][str(cycle)] = {"changed": changed, "finished_at": self.now()}
            watch["finished_cycles"] = dict(sorted(watch["finished_cycles"].items(), key=lambda item: int(item[0]))[-128:])
            watch["last_cycle"] = cycle
            watch["next_check_at"] = cal["next_check_at"]
            self._save(state)
            return {"finished": True, "changed": changed, "watch_state": "active",
                    "next_check_at": watch["next_check_at"],
                    "result": "Report the verified change." if changed else "[SILENT]"}

    def stop(self, board, task_id, reason):
        # Revoking an already recorded watch must work even if its source is offline.
        key = self.key(board, task_id)
        reason = text(reason, 240)
        with file_lock(self.root / "followups.lock"):
            state = self._load()
            watch = state["tasks"].get(key, {}).get("watch")
            if not watch:
                raise ValueError("no watch exists")
            watch.update(state="stopped", stop_reason=reason, stopped_at=self.now(), next_check_at=None)
            self._save(state)  # The gate closes even if the native pause fails.
            current = self.jobs.get(watch["job_id"])
            if (not current or route_signature(current) != watch["route"]
                    or current.get("script") != watch["script"]):
                return {"stopped": True, "job_paused": False, "reason": "native job changed; inspect it separately"}
            job = self.jobs.pause_gate(watch["job_id"], watch["route"], watch["script"], "Nollie watch stopped")
            return {"stopped": True, "job_paused": bool(job and job.get("enabled") is False)}

    def gate(self, key):
        with file_lock(self.root / "followups.lock"):
            state = self._load()
            entry = state["tasks"].get(key)
            if not entry or not entry.get("watch"):
                return {"wakeAgent": False, "reason": "unbound"}
            _, task = self._task(entry["board"], entry["task_id"])
            watch = entry["watch"]
            if watch["state"] != "active":
                return {"wakeAgent": False, "reason": "stopped"}
            if task.get("status") == "archived":
                return {"wakeAgent": False, "reason": "archived"}
            if task.get("status") == "blocked" and task.get("block_kind") not in ("transient", "dependency"):
                return {"wakeAgent": False, "reason": "needs_attention"}
            job = self.jobs.get(watch["job_id"])
            if not job or route_signature(job) != watch["route"] or job.get("script") != watch["script"] or job.get("precheck_fail_closed") is not True:
                return {"wakeAgent": False, "reason": "job_changed"}
            cal = calendar(watch["cadence"], self.now())
            if cal["expired"]:
                watch.update(state="stopped", stop_reason="deadline passed", next_check_at=None)
                self._save(state)
                self.jobs.pause_gate(watch["job_id"], watch["route"], watch["script"], "Nollie watch deadline passed")
                return {"wakeAgent": False, "reason": "deadline"}
            due = cal["cycle"] >= 0 and cal["cycle"] > watch["last_cycle"]
            return {"wakeAgent": due, "cycle": cal["cycle"], "board": entry["board"], "task_id": entry["task_id"],
                    "constraints": watch["constraints"], "previous": watch["comparisons"] if due else {},
                    "next_check_at": cal["next_check_at"]}

    def status(self, board, task_id):
        key, _ = self._task(board, task_id)
        return {"followup": self._load()["tasks"].get(key), "continuation_scheduled": False}

    def context(self, record):
        """Lifecycle context never suppresses a Board failure, review or outcome."""
        entry = self._load()["tasks"].get(self.key(record["board"], record["task"]["id"]), {})
        watch = entry.get("watch")
        result = {"checkpoint": entry.get("checkpoint")}
        if watch:
            result["watch"] = {k: watch.get(k) for k in ("state", "job_id", "constraints", "next_check_at")}
        return result
