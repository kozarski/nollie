"""The guard and the recorder: hooks in every followed profile, for unattended runs only.

Hermes runs ``pre_tool_call`` callbacks one by one and treats a raise or a timeout as a block,
for every session of the profile. So there are two:

- the guard decides whether to block (the Mac, the add-on's own files, rehearsal holds). It may
  fail closed only where it blocks, and it reads files at most once per execution;
- the recorder never blocks. It puts receipt lines on a bounded in-memory queue that a background
  thread appends to the day files in the main home.

Daytime chats are not recorded and not guarded: both return before touching any file.
"""
from __future__ import annotations

import atexit
import json
import os
from pathlib import Path
import queue
import threading
import time

from . import ask_first, private_bots, receipts, rehearsals
from .night_shift import RECORDERS, Settings, local_day, receipts_dir
from .workflow_core import atomic_write, file_lock

QUEUE_LIMIT = 2000
DAY_LIMIT = 4 * 1024 * 1024
PRIVATE_SECONDS = 60.0
DECISION_LIMIT = 256
EXIT_DRAIN_SECONDS = 2.0
WAKE_FLAG = "night-shift.wake"
SILENT = "[SILENT]"
BLOCK_MESSAGES = {"mac": receipts.MAC, "plugin": receipts.PLUGIN, "held": receipts.REHEARSAL}


class _Blank:
    """A screen with nothing on it: the receipt predicts a hold only for calls held whatever the screen
    shows. A click Ask first held after reading the screen is settled from its result."""

    def label_at(self, tool, args):
        return "blank screen"

    def text(self, tool, args):
        return ""


def held_action(tool_name, args):
    """The plain words for a call Ask first holds in an unattended run, or None. Never reads a file."""
    try:
        return ask_first.classify(tool_name, args, screen=_Blank(), read_file=None)
    except Exception:
        return None


def _session_env(name):
    from gateway.session_context import get_session_env
    return get_session_env(name) or ""


def _toolset(name):
    from tools.registry import registry
    return registry.get_toolset_for_tool(name)


class Writer:
    """Appends queued lines in a background thread. A full queue drops the line and counts it."""

    def __init__(self, root, profile, *, private=lambda: False, limit=QUEUE_LIMIT, day_limit=DAY_LIMIT,
                 start=True):
        self.root, self.profile = Path(root), profile
        self.private, self.day_limit, self.autostart = private, day_limit, start
        self.queue = queue.Queue(maxsize=limit)
        self.lock = threading.Lock()
        self.drops = {}
        self.dropped = 0
        self.thread = None

    def put(self, item):
        try:
            if self.autostart:
                self._start()
            self.queue.put_nowait(item)
        except queue.Full:
            self._count(item)
        except Exception:
            pass

    def _start(self):
        if self.thread is None:
            with self.lock:
                if self.thread is None:
                    self.thread = threading.Thread(target=self._run, name="nollie-receipts", daemon=True)
                    self.thread.start()

    def _count(self, item):
        if not isinstance(item, dict):
            return
        with self.lock:
            self.dropped += 1
            slot = self.drops.setdefault((local_day(item["at"]), item["run"]), {"count": 0, "at": item["at"]})
            slot["count"] += 1

    def _run(self):
        while True:
            try:
                item = self.queue.get(timeout=1.0)
            except queue.Empty:
                self._save_drops()
                continue
            try:
                self.write(item)
            except Exception:
                pass
            finally:
                self.queue.task_done()
            if self.queue.empty():
                self._save_drops()

    def drain(self):
        """Write everything queued now, in the caller's thread. For tests and shutdown."""
        while True:
            try:
                item = self.queue.get_nowait()
            except queue.Empty:
                break
            try:
                self.write(item)
            finally:
                self.queue.task_done()
        self._save_drops()

    def flush(self, seconds=EXIT_DRAIN_SECONDS, clock=time.monotonic):
        """At exit: write what is still queued and wait for a write the background thread has begun,
        for at most ``seconds``. Never raises.

        A Board worker is a short process, and its last lines (often the run's end) are queued
        just before it exits. The thread takes a line off the queue before it writes it, so an
        empty queue is not enough: the count of unfinished lines has to reach zero.
        """
        deadline = clock() + seconds
        try:
            while clock() < deadline:
                try:
                    item = self.queue.get_nowait()
                except queue.Empty:
                    if self.queue.unfinished_tasks == 0:
                        break
                    time.sleep(0.005)
                    continue
                try:
                    self.write(item)
                except Exception:
                    pass
                finally:
                    self.queue.task_done()
            self._save_drops()
        except Exception:
            pass

    def write(self, item):
        if item == "wake":
            path = self.root / WAKE_FLAG
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            os.close(os.open(path, os.O_WRONLY | os.O_CREAT, 0o600))
            return
        if self.private():
            return
        folder = receipts_dir(self.root, self.profile)
        for level in (self.root, folder.parent, folder):
            level.mkdir(exist_ok=True, mode=0o700)
        if folder.is_symlink():
            return
        path = folder / (local_day(item["at"]) + ".jsonl")
        try:
            if path.stat().st_size >= self.day_limit:
                self._count(item)
                return
        except FileNotFoundError:
            pass
        data = (json.dumps(item, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)

    def _save_drops(self):
        with self.lock:
            drops, self.drops = self.drops, {}
        if not drops or self.private():
            return
        folder = receipts_dir(self.root, self.profile)
        by_day = {}
        for (day, run), slot in drops.items():
            by_day.setdefault(day, {})[run] = slot
        for day, runs in by_day.items():
            path = folder / (day + ".unrecorded.json")
            try:
                with file_lock(folder / (day + ".unrecorded.lock")):
                    try:
                        document = json.loads(path.read_text())
                        saved = document["runs"] if document.get("version") == 1 else {}
                    except (OSError, ValueError, KeyError, AttributeError):
                        saved = {}
                    for run, slot in runs.items():
                        old = saved.get(run) if isinstance(saved.get(run), dict) else {"count": 0, "at": slot["at"]}
                        saved[run] = {"count": int(old.get("count", 0)) + slot["count"],
                                      "at": min(int(old.get("at", slot["at"])), slot["at"])}
                    atomic_write(path, {"version": 1, "runs": saved})
            except Exception:
                pass


class Recorder:
    def __init__(self, *, root, profile, main_home, cron, session_env=_session_env, environ=os.environ,
                 checks=None, redactor=None, toolset=_toolset, jobs=None, settings=None, private=None,
                 writer=None, clock=time.time, monotonic=time.monotonic):
        self.root, self.profile, self.main_home = Path(root), profile, Path(main_home)
        self.cron, self.session_env, self.environ = cron, session_env, environ
        self.checks = checks if checks is not None else receipts.HermesChecks()
        self.redactor = redactor
        self.toolset, self.clock, self.monotonic = toolset, clock, monotonic
        self.jobs = jobs
        self.settings = settings or Settings(self.root, interval=10.0, clock=monotonic)
        self.private_names = private or (lambda: private_bots.names(self.main_home))
        self.writer = writer or Writer(self.root, profile, private=self.is_private)
        self.lock = threading.Lock()
        self.decisions = {}
        self.started = set()
        self.replied = set()
        self.registry = None
        self.registry_stamp = None
        self.private_checked = None
        self.private_value = False

    # Who is calling: no I/O ---------------------------------------------------------------

    def identify(self, task_id=None, session_id=None):
        """The unattended run this call belongs to, or None for a chat the person is in."""
        try:
            execution = self.cron()
        except Exception:
            execution = None
        if execution is not None:
            job_id, execution_id = str(execution.job_id), str(execution.execution_id)
            run = task_id if isinstance(task_id, str) and task_id.startswith(f"cron:{job_id}:") \
                else f"cron:{job_id}:{execution_id}"
            return {"key": run, "kind": "schedule", "job_id": job_id, "execution_id": execution_id,
                    "title": str(getattr(execution, "job_name", "") or "")}
        try:
            board = self.environ.get("HERMES_KANBAN_TASK")
        except Exception:
            board = None
        if board:
            return {"key": f"board:{board}", "kind": "board", "task": str(board)}
        try:
            helper = str(self.session_env("HERMES_CRON_SESSION")).strip().lower() in ("1", "true", "yes")
        except Exception:
            helper = False
        if helper:
            return {"key": f"helper:{session_id or 'unknown'}", "kind": "helper"}
        return None

    # Cached reads ------------------------------------------------------------------------

    def active(self):
        try:
            value = self.settings.get()
        except Exception:
            value = dict(night_shift=True, rehearsals=True, rehearsals_since=None, damaged=True)
        return value if value.get("night_shift") or value.get("rehearsals") else None

    def is_private(self):
        """This bot was marked Private: stop recording. A damaged list counts as private."""
        now = self.monotonic()
        if self.private_checked is None or now - self.private_checked >= PRIVATE_SECONDS:
            try:
                self.private_value = private_bots.excluded(self.profile, self.private_names())
            except Exception:
                self.private_value = True
            self.private_checked = now
        return self.private_value

    def _registry(self):
        """(registry or None, damaged). A damaged file falls back to the last good copy."""
        path = self.root / rehearsals.FILE_NAME
        try:
            info = path.stat()
            stamp = (info.st_mtime_ns, info.st_size, info.st_ino)
        except FileNotFoundError:
            return None, False
        if stamp == self.registry_stamp and self.registry is not None:
            return self.registry, False
        try:
            registry = rehearsals.read(self.root, wait=0.5)
        except (OSError, ValueError):
            return self.registry, True
        self.registry, self.registry_stamp = registry, stamp
        return registry, False

    def _followups(self):
        try:
            document = json.loads((self.root / "followups.json").read_text())
            return document if isinstance(document, dict) else None
        except (OSError, ValueError):
            return None

    def decision(self, run, settings):
        """``real`` or ``rehearsal``, decided once per execution. Any doubt rehearses."""
        if run["kind"] != "schedule" or not settings.get("rehearsals"):
            return rehearsals.REAL
        with self.lock:
            cached = self.decisions.get(run["key"])
        if cached:
            return cached
        try:
            registry, damaged = self._registry()
            since = settings.get("rehearsals_since")
            if (not damaged and not settings.get("damaged") and since is not None
                    and (registry is None or registry.get("since") != since)):
                # Rehearsals were just turned on: the service is recording today's jobs as on.
                result = rehearsals.REAL
            else:
                job = self.jobs.get(self.profile, run["job_id"]) if self.jobs is not None else None
                if job is None:
                    result = rehearsals.REHEARSAL
                else:
                    result = rehearsals.decide(self.profile, job, self.jobs.file_hash(self.profile), registry,
                                               self._followups())
        except Exception:
            result = rehearsals.REHEARSAL
        with self.lock:
            if len(self.decisions) >= DECISION_LIMIT:
                self.decisions.pop(next(iter(self.decisions)))
            self.decisions[run["key"]] = result
        return result

    def verdict(self, run, tool_name, args, settings, *, cached_only=False):
        """``mac``, ``plugin``, ``held`` or None: what the guard does with this call."""
        try:
            mac = receipts.mac_block(tool_name, args, self.toolset)
        except Exception:
            mac = True
        if mac:
            return "mac"
        if receipts.plugin_block(tool_name, args):
            return "plugin"
        if held_action(tool_name, args) is not None:
            # Held on every real run too, so the report says it needs a yes rather than "rehearsal".
            return receipts.ASK_FIRST
        if run["kind"] == "schedule" and settings.get("rehearsals"):
            if cached_only:
                with self.lock:
                    decided = self.decisions.get(run["key"])
            else:
                decided = self.decision(run, settings)
            if decided == rehearsals.REHEARSAL and not receipts.look_only(tool_name, args):
                return "held"
        return None

    # Hooks -------------------------------------------------------------------------------

    def guard(self, tool_name=None, args=None, task_id=None, session_id=None, **_):
        try:
            run = self.identify(task_id, session_id)
            if run is None:
                return None
            settings = self.active()
            if not settings:
                return None
            found = self.verdict(run, tool_name, args, settings)
        except Exception:
            return None
        # Ask first holds those itself, with the whole action in its message: the verdict is for the receipt.
        return {"action": "block", "message": BLOCK_MESSAGES[found]} if found in BLOCK_MESSAGES else None

    def _line(self, run, event, **fields):
        return dict({"v": 1, "at": int(self.clock()), "run": run["key"], "event": event}, **fields)

    def _start(self, run, settings, session_id=None):
        if run["key"] in self.started:
            return
        self.started.add(run["key"])
        if len(self.started) > DECISION_LIMIT * 4:
            self.started = {run["key"]}
        with self.lock:
            decided = self.decisions.get(run["key"])
        fields = {"kind": run["kind"], "rehearsal": decided == rehearsals.REHEARSAL}
        if run["kind"] == "schedule":
            fields.update(job_id=run["job_id"], execution_id=run["execution_id"],
                          title=receipts.scrub(run["title"], self.redactor, 240))
        if run["kind"] == "board":
            fields["task"] = run["task"]
        self.writer.put(self._line(run, "start", **fields))

    def record_call(self, tool_name=None, args=None, task_id=None, session_id=None, tool_call_id=None, **_):
        try:
            run = self.identify(task_id, session_id)
            if run is None:
                return None
            settings = self.active()
            if not settings:
                return None
            self._start(run, settings, session_id)
            found = self.verdict(run, tool_name, args, settings, cached_only=True)
            receipt = receipts.classify(tool_name, args, self.checks, guard=found, redactor=self.redactor)
            target = receipts.target(tool_name, args, self.redactor)
            held = held_action(tool_name, args) if found == receipts.ASK_FIRST else None
            if held is not None:
                # The person reads what was held in the morning, in the same plain words a card would use.
                target = receipts.scrub(held.summary, self.redactor, receipts.TARGET_LIMIT)
            self.writer.put(self._line(run, "call", call=str(tool_call_id or ""), tool=str(tool_name or ""),
                                       target=target, receipt=receipt))
        except Exception:
            pass
        return None

    def record_result(self, tool_name=None, args=None, result=None, task_id=None, session_id=None,
                      tool_call_id=None, status=None, **_):
        try:
            run = self.identify(task_id, session_id)
            if run is None:
                return None
            settings = self.active()
            if not settings:
                return None
            outcome = receipts.result_status(status, result)
            fields = {"call": str(tool_call_id or ""), "tool": str(tool_name or ""), "status": outcome}
            if outcome == "blocked":
                found = self.verdict(run, tool_name, args, settings, cached_only=True)
                fields["block"] = receipts.block_detail(result, found)
            self.writer.put(self._line(run, "result", **fields))
            if outcome != "blocked" and receipts.creates_schedule(tool_name, args):
                self.writer.put("wake")
        except Exception:
            pass
        return None

    def session_start(self, session_id=None, **_):
        try:
            run = self.identify(None, session_id)
            if run is None:
                return None
            settings = self.active()
            if not settings:
                return None
            self.decision(run, settings)
            self._start(run, settings, session_id)
        except Exception:
            pass
        return None

    def session_end(self, session_id=None, task_id=None, completed=None, failed=None, interrupted=None, **_):
        try:
            run = self.identify(task_id, session_id)
            if run is None:
                return None
            if not self.active():
                return None
            outcome = "stopped" if interrupted else "failed" if failed or not completed else "done"
            self.writer.put(self._line(run, "end", outcome=outcome))
        except Exception:
            pass
        return None

    def transform_reply(self, response_text=None, session_id=None, **_):
        """A rehearsal's reply is never delivered. Decided from memory only: no files, no locks."""
        try:
            run = self.identify(None, session_id)
            if run is None or run["kind"] != "schedule":
                return None
            with self.lock:
                decided = self.decisions.get(run["key"])
            if decided != rehearsals.REHEARSAL:
                return None
            if run["key"] not in self.replied and isinstance(response_text, str) and response_text != SILENT:
                self.replied.add(run["key"])
                self.writer.put(self._line(run, "reply", text=receipts.scrub(response_text, self.redactor, 4000)))
            return SILENT
        except Exception:
            return None

    def llm_reply(self, session_id=None, task_id=None, assistant_response=None, **_):
        """Keeps a rehearsal's reply for the report if the transform did not run."""
        try:
            run = self.identify(task_id, session_id)
            if run is None or run["kind"] != "schedule":
                return None
            with self.lock:
                decided = self.decisions.get(run["key"])
            if (decided == rehearsals.REHEARSAL and run["key"] not in self.replied
                    and isinstance(assistant_response, str) and assistant_response.strip()
                    and assistant_response != SILENT):
                self.replied.add(run["key"])
                self.writer.put(self._line(run, "reply",
                                           text=receipts.scrub(assistant_response, self.redactor, 4000)))
        except Exception:
            pass
        return None

    def approval(self, choice=None, pattern_key=None, pattern_keys=None, description=None, **_):
        """Keeps a person's Always, so a later receipt can say when it was chosen."""
        try:
            if choice != "always" or not self.active():
                return None
            keys = [k for k in (pattern_keys or [pattern_key]) if isinstance(k, str) and k][:8]
            if keys:
                self.writer.put({"v": 1, "at": int(self.clock()), "run": "approval", "event": "always",
                                 "keys": keys, "detail": receipts.scrub(description or "", self.redactor, 300)})
        except Exception:
            pass
        return None

    def heartbeat(self):
        try:
            atomic_write(self.root / RECORDERS / (self.profile + ".json"),
                         {"version": 1, "pid": os.getpid(), "at": int(self.clock())})
        except Exception:
            pass


HOOKS = (("pre_tool_call", "guard"), ("pre_tool_call", "record_call"), ("post_tool_call", "record_result"),
         ("on_session_start", "session_start"), ("on_session_end", "session_end"),
         ("post_llm_call", "llm_reply"), ("transform_llm_output", "transform_reply"),
         ("post_approval_response", "approval"))


def register(ctx, home, profile):
    """Load the guard and the recorder into this profile. The guard is registered first."""
    from .hermes_adapter import ProfileJobs
    recorder = Recorder(root=Path(home) / "nollie-workflow", profile=profile, main_home=home,
                        cron=ctx.current_cron_execution, redactor=receipts.hermes_redactor(),
                        jobs=ProfileJobs(home))
    for hook, name in HOOKS:
        ctx.register_hook(hook, getattr(recorder, name))
    atexit.register(recorder.writer.flush)

    def unloaded():
        recorder.writer.flush()
        atexit.unregister(recorder.writer.flush)
    unload = getattr(ctx, "on_unload", None)
    if callable(unload):
        unload(unloaded)
    recorder.heartbeat()
    return recorder
