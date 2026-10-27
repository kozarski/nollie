"""Keys from the Keychain reach each bot through Hermes's secret-source contract. Fixture modules
only: no Hermes import, no Keychain. Every value is an obvious fake."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest import mock

ENTRY = Path(__file__).resolve().parents[2] / "Services/Runtime/runtime_entry.py"
spec = importlib.util.spec_from_file_location("nollie_keychain_source_fixture", ENTRY)
entry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(entry)

KEYS = {"default": {"OPENROUTER_API_KEY": "fake-default", "TELEGRAM_BOT_TOKEN": "fake-telegram"},
        "scout": {"GROQ_API_KEY": "fake-scout"}}


class FetchResult:
    def __init__(self, secrets=None):
        self.secrets = secrets or {}


class SecretSource:
    pass


class KeychainSourceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="nollie-keychain-source-")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name).resolve() / "home"
        (self.home / "profiles" / "scout").mkdir(parents=True)
        self.registered = []
        self.cached = {"bitwarden": {"enabled": False}}
        self.base = SimpleNamespace(SecretSource=SecretSource, FetchResult=FetchResult)
        self.registry = SimpleNamespace(register_source=self.register)
        self.snapshot = {}
        self.env_loader = SimpleNamespace(_load_secrets_config=lambda home: self.cached,
                                          get_secret_source_values=lambda home: dict(self.snapshot))
        entry._scope_keychain_source(self.base, self.registry, self.env_loader, self.home, KEYS, self.read_env)
        self.source = self.registered[0][0]

    @staticmethod
    def read_env(path):
        # Stand-in for Hermes's tokenizer: KEY=value lines.
        if not path.is_file():
            return {}
        return dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)

    def register(self, source, **options):
        self.registered.append((source, options))
        return True

    def test_each_bot_gets_only_its_own_keys(self):
        self.assertEqual(self.source.fetch({}, self.home).secrets, KEYS["default"])
        self.assertEqual(self.source.fetch({}, self.home / "profiles" / "scout").secrets, KEYS["scout"])
        self.assertEqual(self.source.fetch({}, self.home / "profiles" / "fresh").secrets, {})
        for elsewhere in (self.home.parent, self.home / "profiles", self.home / "profiles" / "default",
                          self.home / "profiles" / ".scout.staging-1", self.home / "skills"):
            with self.subTest(str(elsewhere)):
                self.assertEqual(self.source.fetch({}, elsewhere).secrets, {})

    def test_source_is_always_on_without_changing_the_saved_config(self):
        self.assertEqual(self.source.name, entry.KEY_SOURCE)
        self.assertEqual(self.source.shape, "bulk")
        self.assertTrue(self.source.is_enabled({}))
        self.assertEqual(self.registered[0][1], {"replace": True, "builtin": True})
        sections = self.env_loader._load_secrets_config(self.home)
        self.assertEqual(sections, {"bitwarden": {"enabled": False}, entry.KEY_SOURCE: {"enabled": True}})
        self.assertEqual(self.cached, {"bitwarden": {"enabled": False}})
        for odd in (None, [], "text"):
            with self.subTest(repr(odd)):
                self.cached = odd
                self.assertEqual(self.env_loader._load_secrets_config(self.home), {entry.KEY_SOURCE: {"enabled": True}})

    def test_a_refused_registration_stops_the_start(self):
        registry = SimpleNamespace(register_source=lambda *_, **__: False)
        with self.assertRaises(SystemExit) as stopped:
            entry._scope_keychain_source(self.base, registry, self.env_loader, self.home, KEYS, self.read_env)
        self.assertEqual(stopped.exception.code, 78)

    def test_what_a_bots_env_file_says_wins(self):
        scout = self.home / "profiles" / "scout"
        (scout / ".env").write_text("GROQ_API_KEY=fake-newer\n")
        self.assertEqual(self.source.fetch({}, scout).secrets, {})
        (self.home / ".env").write_text("OPENROUTER_API_KEY=\nSETTING=1\n")
        self.assertEqual(self.source.fetch({}, self.home).secrets, {"TELEGRAM_BOT_TOKEN": "fake-telegram"})
        # Values Hermes took earlier in this process give way to a later edit of the file too,
        # but only for names this source supplies.
        self.snapshot = {"GROQ_API_KEY": "fake-scout", "VAULT_TOKEN": "fake-vault"}
        (scout / ".env").write_text("GROQ_API_KEY=fake-newer\nVAULT_TOKEN=fake-file\n")
        self.assertEqual(self.env_loader.get_secret_source_values(scout), {"VAULT_TOKEN": "fake-vault"})
        (scout / ".env").write_text("SETTING=1\n")
        self.assertEqual(self.env_loader.get_secret_source_values(scout), {"GROQ_API_KEY": "fake-scout", "VAULT_TOKEN": "fake-vault"})

    def test_a_copied_bot_uses_the_keys_its_copy_took_along(self):
        copy = self.home / "profiles" / "copy"
        copy.mkdir()
        (copy / entry.CLONE_NOTE).write_text(json.dumps({"version": 1, "from": "default", "names": ["OPENROUTER_API_KEY", "MISSING_API_KEY"]}))
        self.assertEqual(self.source.fetch({}, copy).secrets, {"OPENROUTER_API_KEY": "fake-default"})
        # A bot's own key beats the copied one.
        own = dict(KEYS, copy={"OPENROUTER_API_KEY": "fake-own"})
        self.assertEqual(entry._profile_keys(own, self.home, copy), {"OPENROUTER_API_KEY": "fake-own"})

    def test_unsafe_or_malformed_notes_add_nothing(self):
        copy = self.home / "profiles" / "copy"
        copy.mkdir()
        target = self.home / "elsewhere.json"
        target.write_text(json.dumps({"version": 1, "from": "default", "names": ["OPENROUTER_API_KEY"]}))
        os.symlink(target, copy / entry.CLONE_NOTE)
        self.assertEqual(self.source.fetch({}, copy).secrets, {})
        os.unlink(copy / entry.CLONE_NOTE)
        for note in ("{", {"version": 2, "from": "default", "names": []}, {"version": 1, "from": "../x", "names": []},
                     {"version": 1, "from": "default", "names": ["BAD-NAME"]}):
            with self.subTest(note):
                (copy / entry.CLONE_NOTE).write_text(note if isinstance(note, str) else json.dumps(note))
                self.assertEqual(self.source.fetch({}, copy).secrets, {})


class CloneNoteTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="nollie-clone-note-")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name) / "home"
        self.staging = self.home / "profiles" / ".copy.staging-1"
        self.staging.mkdir(parents=True)
        channels = ModuleType("hermes_cli.profile_channels")

        class ChannelKeyIndex:
            def __init__(index, source_dir):
                self.index_source = source_dir

            def platform_for(index, key):
                return "telegram" if key.startswith("TELEGRAM_") else None

        channels.ChannelKeyIndex = ChannelKeyIndex
        package = ModuleType("hermes_cli")
        package.profile_channels = channels
        patcher = mock.patch.dict(sys.modules, {"hermes_cli": package, "hermes_cli.profile_channels": channels})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.note = entry._note_cloned_keys(KEYS, self.home)

    def written(self):
        return json.loads((self.staging / entry.CLONE_NOTE).read_text())

    def test_names_only_and_messaging_tokens_stay_behind(self):
        self.note(self.staging, "default", False)
        self.assertEqual(self.written(), {"version": 1, "from": "default", "names": ["OPENROUTER_API_KEY"]})
        self.assertEqual(self.index_source, self.home)
        self.assertNotIn("fake-", (self.staging / entry.CLONE_NOTE).read_text())
        self.assertEqual(oct((self.staging / entry.CLONE_NOTE).stat().st_mode & 0o777), "0o600")

    def test_copying_channels_takes_the_tokens_too(self):
        self.note(self.staging, "default", True)
        self.assertEqual(self.written()["names"], ["OPENROUTER_API_KEY", "TELEGRAM_BOT_TOKEN"])

    def test_named_source_and_nothing_to_take(self):
        self.note(self.staging, "scout", False)
        self.assertEqual(self.written(), {"version": 1, "from": "scout", "names": ["GROQ_API_KEY"]})
        self.assertEqual(self.index_source, self.home / "profiles" / "scout")
        (self.staging / entry.CLONE_NOTE).unlink()
        self.note(self.staging, "empty", False)
        self.assertFalse((self.staging / entry.CLONE_NOTE).exists())

    def test_an_unreadable_channel_index_shares_no_keys(self):
        sys.modules["hermes_cli.profile_channels"].ChannelKeyIndex = mock.Mock(side_effect=RuntimeError("fixture"))
        self.note(self.staging, "default", False)
        self.assertFalse((self.staging / entry.CLONE_NOTE).exists())


if __name__ == "__main__":
    unittest.main()
