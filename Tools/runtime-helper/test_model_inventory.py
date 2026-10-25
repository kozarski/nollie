"""Offline fixtures for the managed API's narrowly scoped catalog compatibility."""
import hashlib
import importlib.util
from pathlib import Path
import re
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ENTRY = Path(__file__).resolve().parents[2] / "Services/Runtime" / "runtime_entry.py"
spec = importlib.util.spec_from_file_location("nollie_runtime_entry_fixture", ENTRY)
entry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(entry)


class ModelInventoryTests(unittest.TestCase):
    def test_native_backend_pins_the_bundled_entry_bytes(self):
        source = (ENTRY.parent / "NativeRuntimeBackend.swift").read_text()
        digest = re.search(r'entrypointDigest = "([a-f0-9]{64})"', source).group(1)
        self.assertEqual(hashlib.sha256(ENTRY.read_bytes()).hexdigest(), digest)
        addons = re.search(r'addonsDigest = "([a-f0-9]{64})"', source).group(1)
        self.assertEqual(hashlib.sha256(ENTRY.with_name("managed_addons.py").read_bytes()).hexdigest(), addons)

    def modules(self, disk=None, memory=None, enabled=True):
        calls = []
        def fetch(force_refresh=False, *, allow_network=True):
            calls.append(("models", force_refresh, allow_network))
            return {"network": True} if allow_network else {}
        def catalog(*, force_refresh=False):
            calls.append(("catalog", force_refresh))
            return {"network": True}
        def override(provider):
            calls.append(("override", provider))
            return {"network": True}
        models = SimpleNamespace(fetch_models_dev=fetch)
        manifest = SimpleNamespace(
            get_catalog=catalog, _fetch_provider_override=override,
            _load_catalog_config=lambda: {"enabled": enabled},
            _read_disk_cache=lambda: (disk, 0), _in_process_catalog=lambda: memory)
        def options(context, *, refresh=False):
            return {**context, "metadata": models.fetch_models_dev(force_refresh=refresh),
                    "catalog": manifest.get_catalog(force_refresh=refresh),
                    "override": manifest._fetch_provider_override("fixture")}
        inventory = SimpleNamespace(build_model_options_payload=options)
        return models, manifest, inventory, calls

    def test_cold_offline_metadata_preserves_saved_model_and_authentication(self):
        models, catalog, inventory, calls = self.modules()
        entry._scope_model_inventory(models, catalog, inventory)
        for authenticated in (False, True, None):
            with self.subTest(authenticated=authenticated):
                providers = [{"slug": "fixture", "authenticated": authenticated}]
                result = inventory.build_model_options_payload(
                    {"model": "saved-model", "provider": "fixture", "providers": providers})
                self.assertEqual(result["model"], "saved-model")
                self.assertEqual(result["provider"], "fixture")
                self.assertIs(result["providers"], providers)
                self.assertEqual(result["metadata"], {})
                self.assertEqual(result["catalog"], {})
                self.assertIsNone(result["override"])
        self.assertTrue(all(call == ("models", False, False) for call in calls))

    def test_cached_catalog_is_preserved_without_fetch_or_synthetic_models(self):
        cached = {"version": 1, "providers": {"fixture": {"models": [{"id": "cached-model"}]}}}
        models, catalog, inventory, calls = self.modules(disk=cached)
        entry._scope_model_inventory(models, catalog, inventory)
        self.assertIs(inventory.build_model_options_payload({})["catalog"], cached)
        self.assertEqual(calls, [("models", False, False)])

    def test_memory_fallback_and_disabled_catalog_obey_existing_scope(self):
        for enabled, expected in ((True, {"cached": True}), (False, {})):
            with self.subTest(enabled=enabled):
                modules = self.modules(memory={"cached": True}, enabled=enabled)
                entry._scope_model_inventory(*modules[:3])
                self.assertEqual(modules[2].build_model_options_payload({})["catalog"], expected)

    def test_explicit_refresh_retains_original_fetch_behavior(self):
        models, catalog, inventory, calls = self.modules()
        entry._scope_model_inventory(models, catalog, inventory)
        result = inventory.build_model_options_payload({"model": "kept"}, refresh=True)
        self.assertEqual(result["model"], "kept")
        self.assertEqual(calls, [("models", True, True), ("catalog", True), ("override", "fixture")])

    def test_failure_resets_scope_for_later_non_picker_reads(self):
        models, catalog, inventory, calls = self.modules()
        def broken(*args, **kwargs):
            self.assertEqual(models.fetch_models_dev(), {})
            raise ValueError("fixture failure")
        inventory.build_model_options_payload = broken
        entry._scope_model_inventory(models, catalog, inventory)
        with self.assertRaises(ValueError):
            inventory.build_model_options_payload({})
        self.assertEqual(models.fetch_models_dev(), {"network": True})
        self.assertEqual(calls[-1], ("models", False, True))

    def test_concurrent_non_picker_read_keeps_its_network_policy(self):
        models, catalog, inventory, calls = self.modules()
        entered, release = threading.Event(), threading.Event()
        result = []
        def waiting(*args, **kwargs):
            entered.set()
            if not release.wait(2):
                raise TimeoutError("fixture synchronization")
            return models.fetch_models_dev()
        inventory.build_model_options_payload = waiting
        entry._scope_model_inventory(models, catalog, inventory)
        worker = threading.Thread(target=lambda: result.append(inventory.build_model_options_payload({})))
        worker.start()
        try:
            self.assertTrue(entered.wait(2))
            self.assertEqual(models.fetch_models_dev(), {"network": True})
        finally:
            release.set()
            worker.join(2)
        self.assertFalse(worker.is_alive())
        self.assertEqual(result, [{}])

    def test_source_guard_accepts_only_exact_owned_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "module.py"
            source.write_bytes(b"fixture")
            expected = {"module.py": hashlib.sha256(b"fixture").hexdigest()}
            with patch.object(entry, "CATALOG_SOURCE_HASHES", expected):
                entry._validate_catalog_source(root)
                source.write_bytes(b"changed")
                with self.assertRaises(SystemExit) as failure:
                    entry._validate_catalog_source(root)
                self.assertEqual(failure.exception.code, 78)

    def test_source_guard_rejects_symlink_even_with_expected_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / "real.py").write_bytes(b"fixture")
            (root / "module.py").symlink_to(root / "real.py")
            with patch.object(entry, "CATALOG_SOURCE_HASHES", {"module.py": hashlib.sha256(b"fixture").hexdigest()}):
                with self.assertRaises(SystemExit):
                    entry._validate_catalog_source(root)


if __name__ == "__main__":
    unittest.main()
