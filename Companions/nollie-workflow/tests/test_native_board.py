"""Read a task through the add-on using the pinned Hermes board schema."""
import importlib.util
from pathlib import Path
import sqlite3
import sys
import types
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("nollie_board_support",
    ROOT.parent / "hermes-patches/tests/support.py")
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)
spec = importlib.util.spec_from_file_location("native_board_package", ROOT / "__init__.py",
                                             submodule_search_locations=[str(ROOT)])
package = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = package
spec.loader.exec_module(package)
from native_board_package.hermes_adapter import BoardSource


class NativeBoardTests(unittest.TestCase):
    def test_addon_reader_uses_native_schema_without_source_helper(self):
        with support.hermes_source() as home:
            # No YAML is parsed by this fixture; the optional parser is unavailable here.
            sys.modules["hermes_yaml"] = types.ModuleType("hermes_yaml")
            db = support.hermes_module("hermes_cli.kanban_db")
            connections = support.hermes_module("hermes_cli.kanban_db_connect")
            with connections.connect_closing(board="default") as conn:
                task_id = db.create_task(conn, title="Fixture task", body="Fixture body",
                    assignee="default", created_by="default", workspace_kind="scratch",
                    initial_status="blocked", board="default")
                before = list(conn.iterdump())

            source = BoardSource(home, profile_names=lambda: ("default",))
            task = source.task("default", task_id)
            self.assertEqual(task["id"], task_id)
            self.assertEqual(task["title"], "Fixture task")
            self.assertEqual(task["status"], "blocked")
            self.assertNotIn("body", task)
            self.assertIn("default", source.read({}, 0)["cursors"])
            api, reader = source.services()
            self.assertIs(api, db)
            self.assertEqual(Path(reader.__file__), ROOT / "hermes_support/nollie_board_observer.py")
            self.assertNotIn("hermes_cli.nollie_board_observer", sys.modules)
            with reader.connect_closing(board="default") as conn:
                self.assertEqual(list(conn.iterdump()), before)
                with self.assertRaises(sqlite3.OperationalError):
                    conn.execute("UPDATE tasks SET title = 'Changed' WHERE id = ?", (task_id,))


if __name__ == "__main__":
    unittest.main()
