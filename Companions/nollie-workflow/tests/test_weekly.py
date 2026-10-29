import importlib.util
import json
import os
from datetime import datetime, timedelta
from pathlib import Path
import sqlite3
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
NAME = "weekly_test_package"
spec = importlib.util.spec_from_file_location(NAME, ROOT / "__init__.py", submodule_search_locations=[str(ROOT)])
package = importlib.util.module_from_spec(spec)
sys.modules[NAME] = package
spec.loader.exec_module(package)
from weekly_test_package import papertrail, private_bots, weekly, weekly_settings

try:
    import fastapi
    from fastapi.testclient import TestClient
except (ImportError, RuntimeError):
    fastapi = TestClient = None

# 18:00 local on Sunday 25 Oct 2026, when the note goes out by default.
NOW = datetime(2026, 10, 25, 18, 0).timestamp()
WEEK_START = datetime(2026, 10, 19).timestamp()


def at(days_ago, hour=12):
    """A time ``days_ago`` local days before the 25th, at ``hour``."""
    return (datetime(2026, 10, 25, hour, 0) - timedelta(days=days_ago)).timestamp()


def write_lines(home, lines):
    folder = Path(home) / "nollie-workflow" / "papertrail"
    folder.mkdir(parents=True, exist_ok=True)
    for line in lines:
        day = datetime.fromtimestamp(line["at"]).strftime("%Y-%m-%d")
        with open(folder / f"{day}.jsonl", "a") as handle:
            handle.write(json.dumps(dict({"v": 1}, **line)) + "\n")


def model(when, provider="anthropic", host="https://api.anthropic.com", route="online", turn="t"):
    return {"at": when, "route": route, "source": "model", "provider": provider, "host": host, "model": "m",
            "turn": f"{turn}-{when}", "in": 10, "out": 2}


def door(when, host, kind="terminal", route="online"):
    return {"at": when, "route": route, "source": "door", "kind": kind, "host": host, "port": 443}


def answer(when, choice="once", ask="send"):
    return {"at": when, "route": "mac", "source": "approval", "choice": choice, "ask": ask, "turn": f"a-{when}"}


def search(when, service="exa", searches=1, pages=0):
    return {"at": when, "route": "online", "source": "tool", "provider": service, "tool": "web_search",
            "turn": f"s-{when}", "searches": searches, "pages": pages}


def ledger(path, rows):
    connection = sqlite3.connect(path)
    connection.execute("CREATE TABLE executions (id TEXT PRIMARY KEY, job_id TEXT NOT NULL, status TEXT NOT NULL,"
                       " claimed_at TEXT NOT NULL, finished_at TEXT)")
    for index, (job, status, when) in enumerate(rows):
        stamp = datetime.fromtimestamp(when).astimezone().isoformat()
        connection.execute("INSERT INTO executions VALUES (?, ?, ?, ?, ?)", (f"e{index}", job, status, stamp, stamp))
    connection.commit()
    connection.close()


class WeeklyRecordTests(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)

    def read(self, **kwargs):
        kwargs.setdefault("ledger", self.home / "cron" / "executions.db")
        return weekly.read(self.home, "career", now=NOW, provider_name=lambda _: None, environ={}, **kwargs)

    def test_an_empty_week_says_nothing_happened_and_nothing_was_recorded_before(self):
        body = self.read()
        self.assertEqual(body["places"], [])
        self.assertEqual(body["replies"], {"stayed": 0, "left": 0, "online": 0})
        self.assertEqual(body["answers"], {"once": 0, "session": 0, "always": 0, "deny": 0})
        self.assertEqual(body["earlier_answers"], [])
        self.assertIsNone(body["recording_since"])
        self.assertEqual(body["schedules"], [])
        self.assertEqual(body["board"], {"done": 0, "stopped": 0, "failed": 0})
        self.assertEqual(body["since"], int(WEEK_START))
        self.assertTrue(body["runs_kept"], "no ledger yet means no runs, not an unreadable one")

    def test_places_are_grouped_and_counted_with_when_each_was_first_seen(self):
        write_lines(self.home, [
            model(at(20)), model(at(3)), model(at(1)),
            door(at(2), "github.com"), door(at(2, 13), "github.com"), door(at(0), "api.notion.com", kind="mcp"),
            door(at(9), "pypi.org", kind="code"),  # Last week only: not this week's place.
            search(at(1), searches=2, pages=3),
            {"at": at(1), "route": "mac", "source": "model", "provider": "ollama", "turn": "local", "in": 5, "out": 1},
        ])
        body = self.read()
        places = {(p["kind"], p.get("host") or p.get("provider") or p.get("service") or ""): p for p in body["places"]}
        self.assertEqual(places[("model", "https://api.anthropic.com")]["count"], 2)
        self.assertEqual(places[("model", "https://api.anthropic.com")]["first_at"], int(at(20)))
        self.assertEqual(places[("terminal", "github.com")]["count"], 2)
        self.assertEqual(places[("mcp", "api.notion.com")]["first_at"], int(at(0)))
        self.assertEqual(places[("search", "exa")]["count"], 2)
        self.assertEqual(places[("pages", "")]["count"], 3)
        self.assertNotIn(("code", "pypi.org"), places)
        self.assertNotIn("ollama", json.dumps(body["places"]), "a reply that stayed on this Mac is no place")
        self.assertEqual(body["places"][0]["count"], 3, "most used first")
        self.assertEqual(body["recording_since"], int(datetime(2026, 10, 5).timestamp()))

    def test_answers_this_week_and_in_each_earlier_full_week(self):
        write_lines(self.home, [
            answer(at(1)), answer(at(2), "deny", "delete"), answer(at(3), "always", "post"), answer(at(4), "session"),
            answer(at(8)), answer(at(9)),  # The week before.
            answer(at(20)),  # The week before that.
            model(at(29)),  # Papertrail began 29 days ago: three earlier weeks are whole.
        ])
        body = self.read()
        self.assertEqual(body["answers"], {"once": 1, "session": 1, "always": 1, "deny": 1})
        self.assertEqual(body["asks"], {"delete": 1, "post": 1, "send": 2})
        self.assertEqual(body["earlier_answers"], [2, 1, 0])

    def test_a_week_with_papertrail_begun_midweek_has_no_earlier_weeks(self):
        write_lines(self.home, [answer(at(3)), model(at(4))])
        self.assertEqual(self.read()["earlier_answers"], [])

    def test_replies_count_every_one_not_only_the_listed(self):
        write_lines(self.home, [model(at(1, 9) + i * 60, turn=f"t{i}") for i in range(230)])
        replies = self.read()["replies"]
        self.assertEqual((replies["left"], replies["online"]), (230, 230))

    def test_schedules_runs_come_from_the_ledger_and_an_unreadable_one_is_said(self):
        (self.home / "cron").mkdir()
        ledger(self.home / "cron" / "executions.db", [
            ("j1", "completed", at(1)), ("j1", "completed", at(2)), ("j1", "failed", at(3)),
            ("j1", "completed", at(10)), ("j2", "unknown", at(0)), ("j1", "running", at(0)),
        ])
        jobs = [{"id": "j1", "name": "Morning prices", "created_at": "2026-09-01T07:00:00+01:00", "enabled": True,
                 "state": "scheduled"},
                {"id": "j2", "name": " Bin day ", "created_at": datetime.fromtimestamp(at(2)).astimezone().isoformat(),
                 "enabled": False, "state": "paused", "prompt": "secret-prompt", "script": "secret.sh"},
                {"name": "no id"}]
        body = self.read(jobs=jobs)
        found = {job["id"]: job for job in body["schedules"]}
        self.assertEqual(found["j1"]["runs"], {"done": 2, "failed": 1, "unfinished": 0})
        self.assertEqual(found["j2"]["runs"], {"done": 0, "failed": 0, "unfinished": 1})
        self.assertEqual((found["j2"]["name"], found["j2"]["paused"], found["j1"]["paused"]), ("Bin day", True, False))
        self.assertEqual(found["j2"]["created_at"], int(at(2)))
        self.assertNotIn("secret", json.dumps(body))
        self.assertEqual(len(body["schedules"]), 2)
        (self.home / "cron" / "executions.db").write_text("not a database")
        body = self.read(jobs=jobs)
        self.assertFalse(body["runs_kept"])
        self.assertIsNone(body["schedules"][0]["runs"])

    def test_a_schedule_name_can_be_left_out(self):
        jobs = [{"id": "j1", "name": "Moss diary", "enabled": True}]
        body = self.read(jobs=jobs, name=lambda text: "" if "Moss" in text else text)
        self.assertIsNone(body["schedules"][0]["name"])

    def test_board_outcomes_count_only_this_bots_this_week(self):
        outcomes = [{"assignee": "career", "outcome": "completed", "at": int(at(1))},
                    {"assignee": "career", "outcome": "completed", "at": int(at(2))},
                    {"assignee": "career", "outcome": "gave_up", "at": int(at(2))},
                    {"assignee": "career", "outcome": "completed", "at": int(at(12))},
                    {"assignee": "nowhere", "outcome": "completed", "at": int(at(1))}]
        self.assertEqual(self.read(outcomes=outcomes)["board"], {"done": 2, "stopped": 0, "failed": 1})

    def test_apps_and_web_give_names_and_hosts_never_commands_or_keys(self):
        config = {"mcp_servers": {
            "notion": {"url": "https://mcp.notion.com/mcp?token=secret-token", "headers": {"Authorization": "secret"}},
            "files": {"command": "npx", "args": ["secret-arg"], "env": {"KEY": "secret-key"}, "enabled": False},
            "../bad": {"command": "x"}, "odd": "not a server", "quiet": {"command": "y", "enabled": "false"},
        }, "agent": {"disabled_toolsets": ["web"]}, "web": {"search_backend": "exa"}}
        body = self.read(config=config)
        self.assertEqual(body["apps"], [{"name": "files", "on": False, "host": None},
                                        {"name": "notion", "on": True, "host": "mcp.notion.com"},
                                        {"name": "quiet", "on": False, "host": None}])
        self.assertEqual(body["web"], {"on": False, "service": "exa"})
        self.assertNotIn("secret", json.dumps(body))
        self.assertEqual(self.read()["web"], {"on": True, "service": None})

    def test_the_filter_reads_the_runtime_switch_and_no_door_means_none(self):
        self.assertEqual(weekly.filter_state({}), "none")
        door_env = {"HTTPS_PROXY": "http://unplaced.program:abc@127.0.0.1:50123"}
        self.assertEqual(weekly.filter_state(door_env), "off")
        switch = self.home / "network-filter.json"
        env = dict(door_env, NOLLIE_NETWORK_FILTER=str(switch))
        self.assertEqual(weekly.filter_state(env), "off", "missing file")
        switch.write_text(json.dumps({"version": 1, "on": True, "refuse": True}))
        self.assertEqual(weekly.filter_state(env), "on")
        switch.write_text(json.dumps({"version": 1, "on": False}))
        self.assertEqual(weekly.filter_state(env), "off")
        switch.write_text("{damaged")
        self.assertEqual(weekly.filter_state(env), "off")
        self.assertEqual(weekly.filter_state({"HTTPS_PROXY": "http://proxy.example.com:8080"}), "none")


class FakeConfig:
    def __init__(self, config):
        self.config = json.loads(json.dumps(config))
        self.saves = 0

    def load(self):
        return json.loads(json.dumps(self.config))

    def save(self, config):
        self.saves += 1
        self.config = json.loads(json.dumps(config))


class WeeklySwitchTests(unittest.TestCase):
    def test_an_app_turns_off_and_on_again_and_stays_in_the_config(self):
        config = FakeConfig({"mcp_servers": {"notion": {"url": "https://mcp.notion.com/mcp"}}})
        self.assertEqual(weekly.set_switch(config, "app", "notion", False), {"kind": "app", "name": "notion", "on": False})
        self.assertEqual(config.config["mcp_servers"]["notion"], {"url": "https://mcp.notion.com/mcp", "enabled": False})
        self.assertEqual(weekly.set_switch(config, "app", "notion", True)["on"], True)
        self.assertEqual(config.config["mcp_servers"]["notion"]["enabled"], True)

    def test_web_tools_turn_off_and_on_without_touching_other_switched_off_tools(self):
        config = FakeConfig({"agent": {"disabled_toolsets": ["computer_use"]}})
        self.assertEqual(weekly.set_switch(config, "web", None, False), {"kind": "web", "name": None, "on": False})
        self.assertEqual(config.config["agent"]["disabled_toolsets"], ["computer_use", "web"])
        self.assertEqual(weekly.set_switch(config, "web", None, True)["on"], True)
        self.assertEqual(config.config["agent"]["disabled_toolsets"], ["computer_use"])

    def test_an_unknown_app_changes_nothing(self):
        config = FakeConfig({"mcp_servers": {}})
        with self.assertRaises(weekly.NoSuchSwitch):
            weekly.set_switch(config, "app", "notion", False)
        with self.assertRaises(weekly.NoSuchSwitch):
            weekly.set_switch(config, "shell", None, False)
        self.assertEqual(config.saves, 0)


class ChangeRecordTests(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)

    def test_a_removed_app_is_a_change_listed_apart_and_never_a_reply(self):
        recorder = papertrail.Recorder(self.home, clock=lambda: at(1))
        self.assertTrue(recorder.change("app_removed", "notes"))
        self.assertFalse(recorder.change("app_added", "notes"))
        self.assertFalse(recorder.change("app_removed", "../x"))
        self.assertTrue(recorder.flush())
        trail = papertrail.read(self.home, "career", 7, now=NOW, provider_name=lambda _: None)
        self.assertEqual(trail["changes"], [{"at": int(at(1)), "kind": "app_removed", "name": "notes"}])
        self.assertEqual((trail["stayed"]["window"], trail["left"]["window"]), (0, 0))
        week = weekly.read(self.home, "career", now=NOW, provider_name=lambda _: None, environ={},
                           ledger=self.home / "none.db")
        self.assertEqual([c["name"] for c in week["changes"]], ["notes"])
        self.assertEqual(week["places"], [])


class FakeApps:
    def __init__(self, config, plugin=False, stays=False):
        self.config, self.plugin, self.stays, self.removed = config, plugin, stays, []

    def remove(self, name):
        if self.plugin:
            raise weekly.FromPlugin(name)
        servers = self.config.setdefault("mcp_servers", {})
        if name not in servers:
            return False
        self.removed.append(name)
        if not self.stays:
            del servers[name]
        return True


class RemoveAppTests(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.config_path = self.home / "config.yaml"

    def write(self, config):
        self.config_path.write_text(json.dumps(config))  # JSON is YAML, so Hermes's reader takes it.

    def test_removing_reads_the_config_again_and_records_the_change(self):
        hermes = FakeApps({"mcp_servers": {"notes": {"url": "https://mcp.notes.example.com"}}})
        recorder = papertrail.Recorder(self.home, clock=lambda: NOW - 60)
        removed = []

        class Removing(FakeApps):
            pass
        original = hermes.remove

        def remove(name):
            done = original(name)
            self.write(hermes.config)
            removed.append(name)
            return done
        hermes.remove = remove
        self.write(hermes.config)
        self.assertTrue(weekly.remove_app(hermes, self.config_path, recorder, "notes"))
        self.assertEqual(removed, ["notes"])
        trail = papertrail.read(self.home, "career", 7, now=NOW, provider_name=lambda _: None)
        self.assertEqual([c["name"] for c in trail["changes"]], ["notes"])
        self.assertFalse(weekly.remove_app(hermes, self.config_path, recorder, "notes"), "already gone")

    def test_an_app_still_in_the_config_afterwards_is_not_called_removed(self):
        config = {"mcp_servers": {"notes": {"url": "https://mcp.notes.example.com"}}}
        self.write(config)
        recorder = papertrail.Recorder(self.home, clock=lambda: NOW - 60)
        with self.assertRaises(RuntimeError):
            weekly.remove_app(FakeApps(config, stays=True), self.config_path, recorder, "notes")
        recorder.flush()
        self.assertEqual(papertrail.read(self.home, "career", 7, now=NOW, provider_name=lambda _: None)["changes"], [])

    def test_a_plugins_app_and_a_bad_name_change_nothing(self):
        with self.assertRaises(weekly.FromPlugin):
            weekly.remove_app(FakeApps({}, plugin=True), self.config_path, None, "notes")
        with self.assertRaises(weekly.NoSuchSwitch):
            weekly.remove_app(FakeApps({}), self.config_path, None, "../x")


class WeeklySettingsTests(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)

    def test_defaults_before_anything_is_saved(self):
        self.assertEqual(weekly_settings.read(self.home), ({"muted": [], "note": {"on": True, "weekday": 1},
                                                            "live_at": None}, False))

    def test_mute_one_helper_at_a_time_and_unmute(self):
        weekly_settings.mute(self.home, "career", True)
        weekly_settings.mute(self.home, "Nowhere", True)
        self.assertEqual(weekly_settings.read(self.home)[0]["muted"], ["career", "nowhere"])
        weekly_settings.mute(self.home, "career", False)
        self.assertEqual(weekly_settings.read(self.home)[0]["muted"], ["nowhere"])
        for bad in (("../x", True), ("career", "yes")):
            with self.assertRaises(ValueError):
                weekly_settings.mute(self.home, *bad)

    def test_private_bots_are_left_out_of_what_is_shown(self):
        weekly_settings.mute(self.home, "moss", True)
        weekly_settings.mute(self.home, "career", True)
        settings, _ = weekly_settings.read(self.home)
        self.assertEqual(weekly_settings.visible(settings, {"moss"})["muted"], ["career"])

    def test_the_note_day_and_the_macs_word_are_kept(self):
        weekly_settings.set_note(self.home, False, 6)
        weekly_settings.mark_live(self.home, now=1234)
        self.assertEqual(weekly_settings.read(self.home)[0], {"muted": [], "note": {"on": False, "weekday": 6},
                                                              "live_at": 1234})
        for bad in ((True, 0), (True, 8), ("on", 1), (True, True)):
            with self.assertRaises(ValueError):
                weekly_settings.set_note(self.home, *bad)

    def test_a_damaged_file_is_never_read_as_nobody_muted(self):
        (self.home / weekly_settings.FILE_NAME).write_text("{damaged")
        with self.assertRaises(ValueError):
            weekly_settings.read(self.home)


@unittest.skipUnless(fastapi and TestClient, "FastAPI and its test client are available in the Hermes runtime")
class WeeklyRouteTests(unittest.TestCase):
    PATH = "/api/plugins/nollie-workflow/week"

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("workflow_api_weekly_test", ROOT / "dashboard/plugin_api.py")
        cls.api = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.api)
        app = fastapi.FastAPI()
        app.include_router(cls.api.router, prefix="/api/plugins/nollie-workflow")
        cls.client = TestClient(app)

    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.active = "default"
        self.bots = {"career": self.home / "profiles" / "career"}
        write_lines(self.bots["career"], [model(datetime.now().timestamp() - 60)])
        (self.bots["career"] / "config.yaml").write_text("mcp_servers:\n  notion:\n    url: https://mcp.notion.com/mcp\n")

        def profile_dir(name):
            if name == "default":
                return self.home
            if name not in self.bots:
                self.fail(f"looked up {name}")
            return self.bots[name]

        profiles = SimpleNamespace(get_active_profile_name=lambda: self.active, get_profile_dir=profile_dir,
                                   profile_exists=lambda name: name in self.bots)
        modules = patch.dict("sys.modules", {"hermes_cli": SimpleNamespace(), "hermes_cli.profiles": profiles,
                                             "hermes_cli.providers": SimpleNamespace(get_provider=None)})
        modules.start()
        self.addCleanup(modules.stop)

        class Jobs:
            def __init__(self, home):
                pass

            def jobs(self, profile):
                return [{"id": "j1", "name": "Morning prices", "enabled": True},
                        {"id": "j2", "name": "Moss diary", "enabled": True}]
        jobs = patch.object(self.api._adapter, "ProfileJobs", Jobs)
        jobs.start()
        self.addCleanup(jobs.stop)

    def test_a_bot_gets_its_week_and_a_private_name_is_left_out(self):
        response = self.client.get(self.PATH, params={"bot": "career"})
        self.assertEqual((response.status_code, response.headers.get("cache-control")), (200, "no-store"))
        body = response.json()
        self.assertEqual(body["bot"], "career")
        self.assertEqual(body["replies"]["left"], 1)
        self.assertTrue(body["papertrail"])
        self.assertEqual({job["id"]: job["name"] for job in body["schedules"]}, {"j1": "Morning prices", "j2": None})

    def test_private_bots_are_refused_and_bad_names_are_422(self):
        for bot in ("moss", "private"):
            response = self.client.get(self.PATH, params={"bot": bot})
            self.assertEqual((response.status_code, response.json()["detail"]), (403, "The weekly note leaves private bots out."))
        private_bots.save(self.home, ["career"])
        self.assertEqual(self.client.get(self.PATH, params={"bot": "career"}).status_code, 403)
        self.assertEqual(self.client.get(self.PATH, params={"bot": "../career"}).status_code, 422)

    def test_another_profiles_scope_is_refused(self):
        self.active = "career"
        self.assertEqual(self.client.get(self.PATH, params={"bot": "career"}).status_code, 403)

    def test_the_switch_route_turns_an_app_off_through_the_bots_config(self):
        config = FakeConfig({"mcp_servers": {"notion": {"url": "https://mcp.notion.com/mcp"}}})
        homes = []

        def opened(home):
            homes.append(Path(home))
            return config
        with patch.object(self.api._weekly, "ConfigFile", opened):
            response = self.client.put(self.PATH + "/switch", json={"bot": "career", "kind": "app", "name": "notion", "on": False})
            self.assertEqual(response.json(), {"bot": "career", "kind": "app", "name": "notion", "on": False})
            self.assertEqual(homes, [self.bots["career"]])
            missing = self.client.put(self.PATH + "/switch", json={"bot": "career", "kind": "app", "name": "slack", "on": False})
            self.assertEqual(missing.status_code, 404)
            for body in ({"bot": "career", "kind": "shell", "on": False}, {"bot": "career", "kind": "app", "name": "../x", "on": False}):
                self.assertEqual(self.client.put(self.PATH + "/switch", json=body).status_code, 422)
            self.assertEqual(self.client.put(self.PATH + "/switch", json={"bot": "moss", "kind": "web", "on": False}).status_code, 403)

    def test_remove_goes_through_hermes_and_is_recorded(self):
        config = {"mcp_servers": {"notes": {"url": "https://mcp.notes.example.com"}}}
        (self.bots["career"] / "config.yaml").write_text(json.dumps(config))
        profiles = []

        def opened(profile):
            profiles.append(profile)
            apps = FakeApps(config)
            original = apps.remove

            def remove(name):
                done = original(name)
                (self.bots["career"] / "config.yaml").write_text(json.dumps(config))
                return done
            apps.remove = remove
            return apps
        with patch.object(self.api._weekly, "HermesApps", opened):
            response = self.client.post(self.PATH + "/remove-app", json={"bot": "career", "name": "notes"})
            self.assertEqual(response.json(), {"bot": "career", "name": "notes", "removed": True})
            self.assertEqual(profiles, ["career"], "Hermes's own scope for that bot")
            self.assertEqual(self.client.post(self.PATH + "/remove-app", json={"bot": "career", "name": "notes"}).status_code, 404)
            self.assertEqual(self.client.post(self.PATH + "/remove-app", json={"bot": "moss", "name": "notes"}).status_code, 403)
            self.assertEqual(self.client.post(self.PATH + "/remove-app", json={"bot": "career", "name": "../x"}).status_code, 422)
        plugin_error = self.api._weekly.FromPlugin

        class PluginApps:
            def __init__(self, profile):
                pass

            def remove(self, name):
                raise plugin_error(name)
        with patch.object(self.api._weekly, "HermesApps", PluginApps):
            self.assertEqual(self.client.post(self.PATH + "/remove-app", json={"bot": "career", "name": "notes"}).status_code, 409)
        week = self.client.get(self.PATH, params={"bot": "career"}).json()
        self.assertEqual([c["name"] for c in week["changes"]], ["notes"])

    def test_mutes_and_the_note_are_kept_for_every_device(self):
        base = "/api/plugins/nollie-workflow"
        self.assertEqual(self.client.get(base + "/mutes").json(), {"muted": [], "saved": False})
        response = self.client.put(base + "/mutes/career", json={"muted": True})
        self.assertEqual((response.status_code, response.json()), (200, {"muted": ["career"], "saved": True}))
        self.assertEqual(response.headers.get("cache-control"), "no-store")
        self.assertEqual(self.client.put(base + "/mutes/moss", json={"muted": True}).status_code, 403)
        self.assertEqual(self.client.put(base + "/mutes/career", json={"muted": "yes"}).status_code, 422)
        self.assertEqual(self.client.put(base + "/mutes/career", json={"muted": False}).json()["muted"], [])
        self.assertEqual(self.client.get(base + "/weekly-note").json(),
                         {"on": True, "weekday": 1, "live_at": None, "saved": True})
        self.assertEqual(self.client.put(base + "/weekly-note", json={"on": True, "weekday": 6}).json()["weekday"], 6)
        self.assertEqual(self.client.put(base + "/weekly-note", json={"on": True, "weekday": 9}).status_code, 422)
        self.assertIsInstance(self.client.post(base + "/weekly-note/live").json()["live_at"], int)
        # The Mac's alerts helper sent the note through iCloud: Papertrail keeps it, as the person's iCloud.
        self.assertEqual(self.client.post(base + "/papertrail/icloud", json={"bot": "career", "kind": "weekly"}).json(),
                         {"recorded": True})
        self.assertEqual(self.client.post(base + "/papertrail/icloud", json={"bot": "career", "kind": "monthly"}).status_code, 422)
        places = self.client.get(self.PATH, params={"bot": "career"}).json()["places"]
        self.assertEqual([place["count"] for place in places if place["kind"] == "icloud"], [1])
        self.active = "career"
        self.assertEqual(self.client.get(base + "/mutes").status_code, 403)


if __name__ == "__main__":
    unittest.main()
