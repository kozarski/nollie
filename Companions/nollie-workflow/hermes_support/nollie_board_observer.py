"""Read-only, privacy-filtered Board metadata for the Nollie observer."""
from __future__ import annotations

import json
import re
import sqlite3
from contextlib import contextmanager

_FIELDS = ("id", "title", "assignee", "created_by", "tenant", "status", "session_id", "block_kind")


@contextmanager
def connect_closing(*, board):
    """Open an existing board read-only, with no automatic schema initialization."""
    from hermes_cli.kanban_db import kanban_db_path, _lossy_text
    path = kanban_db_path(board=board).resolve()
    conn = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    conn.text_factory = _lossy_text
    try:
        yield conn
    finally:
        conn.close()


def _private(value, private):
    """True when a value names a private bot: the whole value, or any word in it."""
    text = str(value or "").strip().lower()
    if not text or not private:
        return False
    words = {text} | set(re.split(r"[^a-z0-9_-]+", text)) | set(re.split(r"[^a-z0-9]+", text))
    return bool(words & private)


def read_board(conn, *, cursors, since, profiles, private, include_events=True, only_task_id=None):
    """Filter ownership before reading titles or events in one consistent snapshot.

    The caller supplies an existing Hermes board connection, the bots it follows and
    the Private list. No schema, readiness, claim, task, comment or subscription is
    changed. Only assignments to followed, nonprivate bots are eligible; private
    ownership metadata never grants access to their content.
    """
    if conn.in_transaction:
        raise RuntimeError("Board observer requires its own read transaction")
    private = frozenset(str(name).lower() for name in private)
    profiles = tuple(name for name in profiles if isinstance(name, str) and name not in private)
    if not profiles:
        return []
    conn.execute("BEGIN")
    try:
        query = ("SELECT id, assignee, created_by, tenant FROM tasks WHERE assignee IN ("
                 + ", ".join("?" * len(profiles)) + ")")
        params = profiles
        if only_task_id is not None:
            query += " AND id = ?"
            params += (only_task_id,)
        ownership = conn.execute(query, params).fetchall()
        result = []
        for owner in ownership:
            if _private(owner["created_by"], private) or _private(owner["tenant"], private):
                continue
            task_id = owner["id"]
            row = conn.execute("SELECT " + ", ".join(_FIELDS) + " FROM tasks WHERE id = ?",
                               (task_id,)).fetchone()
            task = {field: row[field] for field in _FIELDS}
            events = []
            if include_events:
                rows = conn.execute(
                    "SELECT id, kind, run_id, created_at, payload FROM task_events "
                    "WHERE task_id = ? AND id > ? AND created_at >= ? ORDER BY id ASC",
                    (task_id, int(cursors.get(task_id, 0)), int(since))).fetchall()
                for event in rows:
                    try:
                        payload = json.loads(event["payload"] or "{}")
                    except (ValueError, TypeError):
                        payload = {}
                    events.append({"id": event["id"], "kind": event["kind"], "run_id": event["run_id"],
                                   "created_at": event["created_at"], "payload": payload})
            result.append({"task": task, "events": events})
        return result
    finally:
        conn.rollback()
