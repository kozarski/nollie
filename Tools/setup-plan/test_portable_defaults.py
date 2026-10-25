import copy
import json
from pathlib import Path
import tempfile
import unittest

from portable_defaults import RESOURCE, load_contract, portable_config, portable_soul


class PortableDefaultsTests(unittest.TestCase):
    def test_reads_bundled_contract_and_preserves_authorized_dispatch(self):
        raw = json.loads(RESOURCE.read_text())
        self.assertEqual(load_contract(), raw)
        self.assertEqual(portable_config(), raw["config"])
        self.assertEqual(portable_soul("Juniper"), raw["soul"].replace("{{assistant_name}}", "Juniper"))
        self.assertNotIn("dispatch_in_gateway", portable_config()["kanban"])
        self.assertNotIn("model", portable_config())
        self.assertEqual(portable_config()["plugins"]["enabled"], ["nollie-workflow"])

    def test_name_is_literal_and_cannot_mutate_config(self):
        before = portable_config()
        text = portable_soul('  Juniper "\\\nconfig: off  ')
        self.assertTrue(text.startswith('# Juniper "\\ config: off\n\n'))
        self.assertEqual(portable_config(), before)
        self.assertTrue(portable_soul(" \n ").startswith("# Nollie\n"))

    def test_invalid_contract_never_returns_empty_defaults(self):
        raw = load_contract()
        variants = [{}, {**raw, "version": 2}, {**raw, "soul": "Missing placeholder"}, {**raw, "extra": 1}]
        for section, key, value in [("kanban", "auto_decompose", True),
                                    ("kanban", "max_in_progress", True),
                                    ("kanban", "max_in_progress", 10),
                                    ("approvals", "cron_mode", "approve"),
                                    ("plugins", "enabled", []),
                                    ("plugins", "disabled", ["nollie-workflow"]),
                                    ("cron", "allow_agent_scheduling", True),
                                    ("kanban", "dispatch_in_gateway", False)]:
            changed = copy.deepcopy(raw)
            changed["config"][section][key] = value
            variants.append(changed)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "starter.json"
            for variant in variants:
                with self.subTest(variant=variant):
                    path.write_text(json.dumps(variant))
                    with self.assertRaises(ValueError):
                        portable_config(resource=path)
            path.write_text("not json")
            with self.assertRaises(ValueError):
                portable_soul("Nollie", resource=path)

    def test_missing_resource_does_not_create_anything(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaises(FileNotFoundError):
                portable_config(resource=root / "missing.json")
            self.assertEqual(list(root.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
