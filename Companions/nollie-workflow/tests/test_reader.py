import importlib.util
import json
from pathlib import Path
import sqlite3
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("observer_helper", Path(__file__).resolve().parents[1]
    / "hermes_support/nollie_board_observer.py")
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)
# "private" is listed and private: the reader must drop it from the followed bots itself.
PROFILES = ("default", "career", "nowhere", "forager", "private")
PRIVATE = frozenset({"private", "moss"})


def read_board(conn, **kwargs):
    return reader.read_board(conn, **{"profiles": PROFILES, "private": PRIVATE, **kwargs})


class RecordingConnection(sqlite3.Connection):
    def execute(self, query, parameters=()):
        self.calls.append((query, parameters))
        result = super().execute(query, parameters)
        if self.after_query:
            self.after_query(query)
        return result


class ReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "fixture.db"
        self.conn = sqlite3.connect(self.path, factory=RecordingConnection)
        self.conn.calls, self.conn.after_query = [], None
        self.conn.row_factory = sqlite3.Row
        self.addCleanup(self.conn.close)
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("CREATE TABLE tasks (id TEXT, title TEXT, body TEXT, assignee TEXT, "
            "created_by TEXT, tenant TEXT, status TEXT, session_id TEXT, block_kind TEXT)")
        self.conn.execute("CREATE TABLE task_events (id INTEGER, task_id TEXT, kind TEXT, "
            "run_id INTEGER, created_at INTEGER, payload TEXT)")
        self.add("allowed", "nowhere")
        self.add("private-owner", "private")
        self.add("private-author", "default", created_by="profile:private")
        self.add("private-tenant", "career", tenant="Moss")
        self.conn.commit()
        self.conn.calls.clear()

    def add(self, identity, assignee, *, created_by="default", tenant=None, state="review"):
        self.conn.execute("INSERT INTO tasks VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (identity, identity + " title", "BODY MUST NEVER BE READ", assignee,
             created_by, tenant, state, "source-session", None))
        self.conn.execute("INSERT INTO task_events VALUES (?, ?, ?, ?, ?, ?)",
            (1, identity, "review_requested", 1, 101, json.dumps({"summary": identity + " summary"})))

    def test_private_ownership_filtered_before_titles_or_events_and_no_body_projection(self):
        result = read_board(self.conn, cursors={}, since=100)
        self.assertEqual([item["task"]["id"] for item in result], ["allowed"])
        queries = [(q, p) for q, p in self.conn.calls if q.startswith("SELECT")]
        self.assertEqual(len(queries), 3)
        self.assertEqual(queries[1][1], ("allowed",))
        self.assertEqual(queries[2][1], ("allowed", 0, 100))
        self.assertFalse(any("body" in q.lower() or "SELECT *" in q for q, p in queries))
        self.assertNotIn("private", json.dumps(result))
        self.assertFalse(self.conn.in_transaction)

    def test_attention_and_validation_do_not_query_events(self):
        result = read_board(self.conn, cursors={}, since=0, include_events=False,
                                   only_task_id="allowed")
        self.assertEqual(len(result), 1)
        self.assertFalse(result[0]["events"])
        self.assertFalse(any("task_events" in q for q, p in self.conn.calls))
        self.conn.calls.clear()
        self.assertFalse(read_board(self.conn, cursors={}, since=0,
            include_events=False, only_task_id="private-author"))
        self.assertFalse(any("title" in q for q, p in self.conn.calls))

    def test_timestamp_and_task_cursor_are_both_enforced(self):
        self.assertFalse(read_board(self.conn, cursors={"allowed": 1}, since=100)[0]["events"])
        self.assertFalse(read_board(self.conn, cursors={}, since=102)[0]["events"])

    def test_ownership_change_after_snapshot_is_seen_by_next_validation(self):
        writer = sqlite3.connect(self.path)
        self.addCleanup(writer.close)
        changed = False
        def mutate(query):
            nonlocal changed
            if not changed and query.startswith("SELECT id, assignee"):
                changed = True
                writer.execute("UPDATE tasks SET assignee = 'private', title = 'PRIVATE NEW TITLE' "
                               "WHERE id = 'allowed'")
                writer.commit()
        self.conn.after_query = mutate
        result = read_board(self.conn, cursors={}, since=100)
        self.assertEqual(result[0]["task"]["title"], "allowed title")
        self.assertFalse(read_board(self.conn, cursors={}, since=0,
            include_events=False, only_task_id="allowed"))

    def test_refuses_nested_transaction_and_preserves_callers_transaction(self):
        self.conn.execute("BEGIN")
        with self.assertRaises(RuntimeError):
            read_board(self.conn, cursors={}, since=0)
        self.assertTrue(self.conn.in_transaction)
        self.conn.rollback()

    def test_followed_bots_and_private_list_are_data(self):
        self.add("scout-task", "scout")
        self.add("scout-tenant", "nowhere", tenant="team:scout")
        self.conn.commit()
        self.assertNotIn("scout-task", [r["task"]["id"] for r in read_board(self.conn, cursors={}, since=100)])
        self.conn.calls.clear()
        rows = reader.read_board(self.conn, cursors={}, since=100, profiles=("nowhere", "private", "scout", "career"),
                                 private=frozenset({"scout"}))
        # Once the list no longer names them, the private bot and its tenant are ordinary bots.
        self.assertEqual(sorted(r["task"]["id"] for r in rows), ["allowed", "private-owner", "private-tenant"])
        self.assertEqual(self.conn.calls[1][1], ("nowhere", "private", "career"))
        self.assertEqual(self.conn.calls[1][0].count("?"), 3)

    def test_no_followed_bot_reads_nothing(self):
        self.assertEqual(reader.read_board(self.conn, cursors={}, since=0, profiles=("moss",),
                                           private=frozenset({"moss"})), [])
        self.assertEqual(reader.read_board(self.conn, cursors={}, since=0, profiles=(), private=frozenset()), [])
        self.assertFalse(self.conn.calls)

    def test_connection_cannot_write_or_create_a_missing_board(self):
        api = SimpleNamespace(kanban_db_path=lambda **kwargs: self.path,
                              _lossy_text=lambda value: value.decode("utf-8", errors="replace"))
        with patch.dict(sys.modules, {"hermes_cli": SimpleNamespace(), "hermes_cli.kanban_db": api}):
            with reader.connect_closing(board="default") as conn:
                self.assertEqual(len(read_board(conn, cursors={}, since=100)), 1)
                with self.assertRaises(sqlite3.OperationalError):
                    conn.execute("DELETE FROM tasks")
            self.path = self.path.with_name("missing.db")
            with self.assertRaises(sqlite3.OperationalError):
                with reader.connect_closing(board="missing"):
                    self.fail("created a missing board")
            self.assertFalse(self.path.exists())


if __name__ == "__main__":
    unittest.main()
