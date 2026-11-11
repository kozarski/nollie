"""Local models on this Mac: the mock answers in Hermes 0.23.1's shapes, from a real catalog, and a quick
start moves through Hermes's job states (download, pause, resume, failure, ready and a first reply)."""
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("local_models_mock", Path(__file__).with_name("mock_gateway.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)
LOCAL = mock.LOCAL_MODELS


class LocalModelsTests(unittest.TestCase):
    def setUp(self):
        LOCAL.reset("flow")
        self.addCleanup(LOCAL.reset, "flow")

    def request(self, path, method="GET", body=None):
        request = SimpleNamespace(path=path, method=method, body=json.dumps(body or {}).encode(), headers={})
        response = mock.process_request(None, request)
        return response.status_code, json.loads(response.body)

    def start(self, model="qwen3.8-27b"):
        status, body = self.request("/api/local-models/quickstart?profile=default", "POST", {"model_id": model})
        self.assertEqual(status, 200)
        return body["job_id"]

    def test_catalog_and_hardware_are_the_real_shapes(self):
        status, catalog = self.request("/api/local-models/catalog")
        self.assertEqual(status, 200)
        ids = [m["id"] for m in catalog["models"]]
        self.assertEqual(ids[:2], ["qwen3.8-27b", "qwen3.8-flash-next"])
        recommended = [m for m in catalog["models"] if m["recommended"]]
        self.assertEqual([m["id"] for m in recommended], ["qwen3.8-flash-next"])
        for row in catalog["models"]:
            for key in ("fits", "spilled", "needs_engine", "model_id", "size_bytes", "start_window", "downloaded"):
                self.assertIn(key, row)
        _, hardware = self.request("/api/local-models/hardware")
        self.assertEqual(hardware["ram_total_bytes"], 206158430208)

    def test_a_quick_start_downloads_then_selects_and_answers(self):
        job = self.start()
        _, first = self.request(f"/api/local-models/jobs/{job}")
        self.assertEqual(first["status"], "running")
        self.assertIsNone(first["error"])
        LOCAL.STATE["jobs"][job]["started_at"] -= LOCAL.FLOW_SECONDS * 0.5
        _, middle = self.request(f"/api/local-models/jobs/{job}")
        self.assertEqual(middle["phase"], "downloading")
        self.assertGreater(middle["bytes_per_sec"], 0)
        self.assertGreater(middle["eta_seconds"], 0)
        self.assertEqual(self.request("/api/local-models/quickstart", "POST", {"model_id": "qwen3.8-27b"})[0], 409)
        LOCAL.STATE["jobs"][job]["started_at"] -= LOCAL.FLOW_SECONDS
        _, done = self.request(f"/api/local-models/jobs/{job}")
        self.assertEqual(done["status"], "done")
        _, options = self.request("/api/model/options?profile=default")
        self.assertEqual((options["provider"], options["model"]), ("llamacpp", "Qwen3.8-27B-UD-Q4_K_M"))
        self.assertTrue(options["providers"][0]["authenticated"])
        _, catalog = self.request("/api/local-models/catalog")
        self.assertTrue(catalog["models"][0]["downloaded"])
        status, reply = self.request("/api/nollie/local-model/reply-check?profile=default", "POST")
        self.assertEqual((status, reply["provider"], reply["model"]), (200, "llamacpp", "Qwen3.8-27B-UD-Q4_K_M"))

    def test_pause_keeps_the_bytes_and_resume_carries_on(self):
        job = self.start()
        LOCAL.STATE["jobs"][job]["started_at"] -= LOCAL.FLOW_SECONDS * 0.3
        self.assertEqual(self.request("/api/local-models/download/pause", "POST", {"job_id": job})[1]["paused"], True)
        _, paused = self.request(f"/api/local-models/jobs/{job}")
        self.assertEqual((paused["status"], paused["can_resume"], paused["can_pause"]), ("paused", True, False))
        self.assertNotIn("eta_seconds", paused)
        self.assertEqual(self.request("/api/local-models/download/resume", "POST", {"job_id": job})[1]["resumed"], True)
        _, running = self.request(f"/api/local-models/jobs/{job}")
        self.assertEqual(running["status"], "running")
        self.assertGreaterEqual(running["done_bytes"], paused["done_bytes"])

    def test_failures_carry_hermes_error_words(self):
        for scenario, words in (("failed-network", "download failed from"), ("failed-disk", "No space left on device"),
                                ("failed-checksum", "sha256 mismatch")):
            LOCAL.reset(scenario)
            job = self.start()
            _, view = self.request(f"/api/local-models/jobs/{job}")
            self.assertEqual(view["status"], "error")
            self.assertIn(words, view["error"])

    def test_unknown_jobs_and_models_answer_as_hermes_does(self):
        self.assertEqual(self.request("/api/local-models/jobs/nope")[0], 404)
        self.assertEqual(self.request("/api/local-models/quickstart", "POST", {"model_id": "nope"})[0], 404)
        self.assertEqual(self.request("/api/nollie/local-model/reply-check", "POST")[0], 503)

    def test_ready_starts_with_the_model_chosen(self):
        LOCAL.reset("ready")
        _, options = self.request("/api/model/options")
        self.assertEqual(options["provider"], "llamacpp")


if __name__ == "__main__":
    unittest.main()
