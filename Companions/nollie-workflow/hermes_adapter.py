"""Narrow adapters to installed Hermes services. No direct database queries."""
from __future__ import annotations

from contextlib import contextmanager
from pathlib import Path

from . import private_bots
from .workflow_core import PAYLOAD_FIELDS, Bots, allowed_task, needs_attention, outcome


@contextmanager
def default_scope(home):
    from hermes_constants import set_hermes_home_override, reset_hermes_home_override
    token = set_hermes_home_override(home)
    try:
        yield
    finally:
        reset_hermes_home_override(token)


class BoardSource:
    def __init__(self, home, *, board_api=None, connections=None, reader=None, profile_names=None):
        self.home = Path(home)
        self.board_api, self.connections = board_api, connections
        self.reader = reader
        self.profile_names = profile_names

    def bots(self):
        """Every Hermes profile that exists, less the Private list kept in the main home."""
        names = self.profile_names
        if names is None:
            from hermes_cli.profiles import list_profile_names as names
        return Bots(names(), private_bots.names(self.home))

    def services(self):
        api, connections = self.board_api, self.connections
        if api is None or connections is None:
            from hermes_cli import kanban_db
            from .hermes_support import nollie_board_observer
            api, connections = api or kanban_db, connections or nollie_board_observer
        return api, connections

    def read_board(self, conn, bots, **kwargs):
        kwargs.update(profiles=bots.followed, private=bots.private)
        if self.reader is not None:
            return self.reader(conn, **kwargs)
        from .hermes_support.nollie_board_observer import read_board
        return read_board(conn, **kwargs)

    def validate(self, record):
        """Recheck pending work against current allowed ownership and outcome state."""
        slug, original = record["board"], record["task"]
        bots = self.bots()
        if bots.is_private(slug) or not allowed_task(original, bots):
            return False
        api, connections = self.services()
        with default_scope(self.home):
            if not any(b.get("slug") == slug for b in api.list_boards(include_archived=False)):
                return False
            if not api.kanban_db_path(board=slug).is_file():
                return False
            with connections.connect_closing(board=slug) as conn:
                rows = self.read_board(conn, bots, cursors={}, since=0, include_events=False,
                                       only_task_id=original["id"])
                for row in rows:
                    return allowed_task(row["task"], bots) and bool(outcome(row["task"], record["event"], bots))
        return False

    def task(self, board, task_id):
        rows = self._task_rows(board, task_id, include_events=False)
        return rows[0]["task"] if rows else None

    def _task_rows(self, board, task_id, *, include_events, cursor=0):
        bots = self.bots()
        if bots.is_private(board):
            return []
        api, connections = self.services()
        with default_scope(self.home):
            if not any(b.get("slug") == board for b in api.list_boards(include_archived=False)):
                return []
            if not api.kanban_db_path(board=board).is_file():
                return []
            with connections.connect_closing(board=board) as conn:
                return [row for row in self.read_board(conn, bots, cursors={task_id: cursor}, since=0,
                    include_events=include_events, only_task_id=task_id) if allowed_task(row["task"], bots)]

    def read(self, cursors, installed_at, *, include_events=True):
        bots = self.bots()
        api, connections = self.services()
        events, next_cursors, attention = [], {}, {}
        with default_scope(self.home):
            for board in api.list_boards(include_archived=False):
                slug = board.get("slug")
                if not isinstance(slug, str) or bots.is_private(slug):
                    continue
                # Do not create a board or run schema setup merely because it was listed.
                if not api.kanban_db_path(board=slug).is_file():
                    continue
                board_cursors = cursors.get(slug, {})
                next_cursors[slug] = dict(board_cursors)
                attention[slug] = 0
                with connections.connect_closing(board=slug) as conn:
                    rows = self.read_board(conn, bots, cursors=board_cursors, since=installed_at,
                                           include_events=include_events)
                    for row in rows:
                        safe = row["task"]
                        if not allowed_task(safe, bots):
                            continue
                        task_id = safe["id"]
                        cursor = int(board_cursors.get(task_id, 0))
                        latest = cursor
                        attention[slug] += int(needs_attention(safe, bots))
                        for event in row["events"]:
                            latest = max(latest, event["id"])
                            if event["id"] <= cursor or event["created_at"] < installed_at:
                                continue
                            if not outcome(safe, event, bots):
                                continue
                            raw = dict(event)
                            raw["payload"] = {k: str(v)[:2000] for k, v in (event["payload"] or {}).items()
                                              if k in PAYLOAD_FIELDS and v is not None}
                            safe["title"] = str(safe["title"] or "")[:240]
                            events.append({"board": slug, "task": dict(safe), "event": raw})
                        next_cursors[slug][task_id] = latest
        # Several transitions may land between polls. Only the latest still-relevant
        # outcome for a task needs another turn; every observed event advances its cursor.
        latest_by_task = {}
        for event in sorted(events, key=lambda e: e["event"]["id"]):
            latest_by_task[(event["board"], event["task"]["id"])] = event
        return {"events": sorted(latest_by_task.values(), key=lambda e: (e["board"], e["event"]["id"])),
                "cursors": next_cursors, "counts": attention}


class ProfileJobs:
    """Each profile's own cron store, for Night shift and rehearsals.

    Every call runs under that profile's home and cron store, passes job ids only and checks
    the id Hermes answers with, since Hermes falls back to matching names.
    """

    def __init__(self, home):
        self.home = Path(home)

    def profiles(self):
        from hermes_cli.profiles import list_profile_names
        return list(list_profile_names())

    def profile_home(self, profile):
        if profile == "default":
            return self.home
        from hermes_cli.profiles import get_profile_dir
        return Path(get_profile_dir(profile))

    def display_name(self, profile):
        from hermes_cli.profiles import read_profile_meta
        return read_profile_meta(self.profile_home(profile)).get("display_name") or ""

    @contextmanager
    def scope(self, profile):
        from hermes_constants import set_hermes_home_override, reset_hermes_home_override
        from cron.jobs import use_cron_store
        home = self.profile_home(profile)
        token = set_hermes_home_override(home)
        try:
            with use_cron_store(home):
                yield
        finally:
            reset_hermes_home_override(token)

    def jobs(self, profile):
        from cron.jobs import list_jobs
        with self.scope(profile):
            return [job for job in list_jobs(include_disabled=True) if isinstance(job, dict)]

    @staticmethod
    def _same(job, job_id):
        return job if isinstance(job, dict) and job.get("id") == job_id else None

    def get(self, profile, job_id):
        from cron.jobs import get_job
        with self.scope(profile):
            return self._same(get_job(job_id), job_id)

    def update(self, profile, job_id, updates):
        from cron.jobs import get_job, update_job
        with self.scope(profile):
            if not self._same(get_job(job_id), job_id):
                return None
            return self._same(update_job(job_id, updates), job_id)

    def pause(self, profile, job_id, reason):
        from cron.jobs import get_job, pause_job
        with self.scope(profile):
            if not self._same(get_job(job_id), job_id):
                return None
            return self._same(pause_job(job_id, reason=reason), job_id)

    def resume(self, profile, job_id):
        from cron.jobs import get_job, resume_job
        with self.scope(profile):
            if not self._same(get_job(job_id), job_id):
                return None
            return self._same(resume_job(job_id), job_id)

    def file_hash(self, profile):
        from .rehearsals import file_hash
        return file_hash(self.profile_home(profile))

    def recorder_installed(self, profile):
        return recorder_installed(self.profile_home(profile))


PLUGIN_NAME = "nollie-workflow"


def recorder_installed(home):
    """False when this bot's copy of the add-on was removed, or its config disables it or leaves it out.

    An unreadable config or one without a plugin list says nothing either way, so it counts as installed.
    """
    home = Path(home)
    folder = home / "plugins" / PLUGIN_NAME
    if folder.is_symlink() or not (folder / "recorder.py").is_file():
        return False
    try:
        try:  # Inside Hermes: its own YAML layer. A managed setup's environment has no PyYAML.
            import hermes_yaml as yaml
        except ImportError:
            import yaml
        config = yaml.safe_load((home / "config.yaml").read_text())
    except Exception:
        return True
    plugins = config.get("plugins") if isinstance(config, dict) else None
    if not isinstance(plugins, dict):
        return True

    def names(value):
        return isinstance(value, list) and any(isinstance(item, str) and (item == PLUGIN_NAME
                                                                          or item.endswith("/" + PLUGIN_NAME))
                                               for item in value)
    if names(plugins.get("disabled")):
        return False
    return not isinstance(plugins.get("enabled"), list) or names(plugins.get("enabled"))


class BotChatDelivery:
    """Queue once into the gateway scheduler's existing canonical-chat delivery lane.

    The gateway drains this durable queue even with no client. It owns live-session
    admission, CLI fallback, uncertainty handling and terminal receipts. This adapter
    never runs an agent, creates a cron job, or retries an ambiguous turn itself.
    """
    def __init__(self, home):
        self.home = Path(home)

    def enqueue(self, key, content):
        from cron.bot_chat_delivery import defer
        with default_scope(self.home):
            return defer(key, {"id": "nollie-board-" + key[:16], "name": "Board follow-through",
                               "execution_id": key}, content, "default", self.home)

    def receipt(self, key):
        from cron.bot_chat_delivery import read_pending
        from tools.bot_live_delivery import read_delivery_result
        with default_scope(self.home):
            # A transferred live-owner receipt is authoritative after cron handed it off.
            return read_delivery_result(self.home, key) or read_pending(key)

    def discard_unstarted(self, key, content):
        """Withdraw only our exact queued receipt; a consumer's claim always wins."""
        from cron.bot_chat_delivery import defer, read_pending
        from tools.bot_live_delivery import cancel_queued_delivery
        with default_scope(self.home):
            receipt = read_pending(key)
            if receipt is not None:
                receipt = defer(key, receipt["job"], content, "default", self.home, suppressed=True)
            live = cancel_queued_delivery(self.home, key, error="", reason="Board outcome superseded")
            return live or receipt
