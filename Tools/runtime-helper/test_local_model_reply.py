"""Fixed local inference fixtures. No model, network, credentials or installed home."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ENTRY = Path(__file__).resolve().parents[2] / "Services/Runtime/runtime_entry.py"
spec = importlib.util.spec_from_file_location("local_reply_entry_fixture", ENTRY)
entry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(entry)


class FakeConnection:
    def __init__(self, raw=None, status=200, length=None):
        self.raw = raw if raw is not None else json.dumps({"model": "small-q4", "choices": [
            {"finish_reason": "stop", "message": {"content": " Hello "}}]}).encode()
        self.status = status
        self.length = length
        self.sock = SimpleNamespace(settimeout=lambda _: None)
        self.closed = False
        self.calls = []

    def factory(self, host, port, timeout):
        self.calls.append((host, port, timeout))
        return self

    def connect(self): pass
    def request(self, method, path, body, headers): self.calls.append((method, path, json.loads(body), headers))
    def getresponse(self):
        self.sock = None  # HTTP/1.0 close keeps its file alive, not HTTPConnection.sock.
        return self
    def getheader(self, name): return self.length
    def read1(self, count):
        result, self.raw = self.raw[:count], self.raw[count:]
        return result
    def close(self): self.closed = True


class LocalReplyTests(unittest.TestCase):
    def test_target_accepts_only_owned_literal_loopback_and_staged_selected_model(self):
        self.assertEqual(entry._local_reply_target(("http://127.0.0.1:9999", "fixture"), "small-q4", ["small-q4"]), (9999, "fixture"))
        bad = [None, ("https://example.invalid", "fixture"), ("http://localhost:99", "fixture"),
               ("http://127.0.0.1:99/v1", "fixture"), ("http://127.0.0.1:99?target=x", "fixture"),
               ("http://user@127.0.0.1:99", "fixture"), ("http://127.0.0.1:99", ""),
               ("http://127.0.0.1:999999", "fixture")]
        for target in bad:
            with self.subTest(target=target), self.assertRaises(entry.LocalReplyFailure):
                entry._local_reply_target(target, "small-q4", ["small-q4"])
        for model, staged in [(None, []), ("online-model", []), ("../model", ["../model"])]:
            with self.assertRaises(entry.LocalReplyFailure):
                entry._local_reply_target(("http://127.0.0.1:99", "fixture"), model, staged)

    def test_fixed_request_has_no_history_tools_redirect_or_cloud_fallback(self):
        fake = FakeConnection()
        result = entry._local_reply_request(9999, "fixture", "small-q4", fake.factory)
        self.assertEqual(result, {"provider": "llamacpp", "model": "small-q4", "text": "Hello"})
        self.assertEqual(fake.calls[0], ("127.0.0.1", 9999, 3))
        method, path, body, headers = fake.calls[1]
        self.assertEqual((method, path), ("POST", "/v1/chat/completions"))
        self.assertEqual(body["messages"], [{"role": "user", "content": "Reply with one short friendly greeting."}])
        self.assertEqual(body["tools"], [])
        self.assertEqual(body["tool_choice"], "none")
        self.assertEqual(body["max_tokens"], 512)
        self.assertFalse(body["stream"])
        self.assertEqual(headers["Authorization"], "Bearer fixture")
        self.assertNotIn("fixture", json.dumps(result))
        self.assertTrue(fake.closed)

    def test_redirects_errors_oversized_and_unfinished_responses_fail_closed(self):
        invalid = [FakeConnection(status=302), FakeConnection(status=500), FakeConnection(length="65537"),
                   FakeConnection(raw=b"x" * 65537), FakeConnection(raw=b"not json")]
        for mutation in ("wrong-model", "unfinished", "tool", "function", "empty", "long"):
            result = {"model": "small-q4", "choices": [{"finish_reason": "stop", "message": {"content": "Hello"}}]}
            if mutation == "wrong-model": result["model"] = "fallback-model"
            elif mutation == "unfinished": result["choices"][0]["finish_reason"] = "length"
            elif mutation == "tool": result["choices"][0]["message"]["tool_calls"] = [{"name": "terminal"}]
            elif mutation == "function": result["choices"][0]["message"]["function_call"] = {"name": "terminal"}
            else: result["choices"][0]["message"]["content"] = " " if mutation == "empty" else "x" * 4097
            invalid.append(FakeConnection(raw=json.dumps(result).encode()))
        for fake in invalid:
            with self.subTest(status=fake.status), self.assertRaises(entry.LocalReplyFailure):
                entry._local_reply_request(9999, "fixture", "small-q4", fake.factory)
            self.assertTrue(fake.closed)

    def test_absolute_deadline_and_transport_errors_are_sanitized(self):
        fake = FakeConnection()
        with patch.object(entry.time, "monotonic", side_effect=[100, 281]):
            with self.assertRaises(entry.LocalReplyFailure):
                entry._local_reply_request(9999, "fixture", "small-q4", fake.factory)
        fake = FakeConnection()
        fake.connect = lambda: (_ for _ in ()).throw(ValueError("fixture secret"))
        with self.assertRaises(entry.LocalReplyFailure) as error:
            entry._local_reply_request(9999, "fixture", "small-q4", fake.factory)
        self.assertEqual(str(error.exception), "")
        self.assertTrue(fake.closed)

    def test_deadline_interrupts_a_response_even_before_headers_finish(self):
        callbacks, shutdowns = [], []
        class Timer:
            daemon = False
            def __init__(self, duration, callback):
                self.duration = duration
                callbacks.append(callback)
            def start(self): pass
            def cancel(self): pass
        fake = FakeConnection()
        fake.sock = SimpleNamespace(settimeout=lambda _: None, shutdown=lambda how: shutdowns.append(how))
        def stalled_headers():
            callbacks[0]()
            raise OSError("deadline")
        fake.getresponse = stalled_headers
        with patch.object(entry.threading, "Timer", Timer), self.assertRaises(entry.LocalReplyFailure):
            entry._local_reply_request(9999, "fixture", "small-q4", fake.factory)
        self.assertEqual(shutdowns, [entry.socket.SHUT_RDWR])
        self.assertTrue(fake.closed)

    def test_private_or_unauthenticated_request_does_not_read_model_or_endpoint(self):
        def forbidden(): self.fail("Rejected request reached configuration")
        for profile, authenticated in [("private", True), ("default", False), ("career", True)]:
            with self.assertRaises(entry.LocalReplyFailure):
                entry._perform_local_reply(profile, authenticated, forbidden, forbidden, forbidden, threading.Lock())

    def test_missing_managed_router_never_uses_external_or_fallback_detection(self):
        def forbidden(*_): self.fail("No owned router must mean no inference")
        with self.assertRaises(entry.LocalReplyFailure):
            entry._perform_local_reply("default", True, lambda: "small-q4", lambda: ["small-q4"], lambda: None,
                                       threading.Lock(), request=forbidden)

    def test_ownership_or_selection_change_discards_result_and_releases_lock(self):
        for changes in ("model", "endpoint"):
            lock = threading.Lock()
            model = ["small-q4"]
            endpoint = [("http://127.0.0.1:99", "fixture")]
            def request(*_):
                if changes == "model": model[0] = "different"
                else: endpoint[0] = None
                return {"text": "Hello"}
            with self.assertRaises(entry.LocalReplyFailure):
                entry._perform_local_reply("default", True, lambda: model[0], lambda: ["small-q4"], lambda: endpoint[0], lock, request)
            self.assertFalse(lock.locked())

    def test_only_one_probe_at_a_time(self):
        lock = threading.Lock()
        lock.acquire()
        with self.assertRaises(entry.LocalReplyFailure):
            entry._perform_local_reply("default", True, lambda: self.fail("Concurrent read"), lambda: [], lambda: None, lock)
        lock.release()

    def test_route_is_registered_under_auth_and_never_accepts_client_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            hashes = {}
            for relative in entry.MODEL_PROBE_SOURCE_HASHES:
                path = root / relative; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b"fixture")
                hashes[relative] = hashlib.sha256(b"fixture").hexdigest()
            routes = []
            local = SimpleNamespace(__file__=str(root / "hermes_cli/web_routers/local_models.py"),
                router=SimpleNamespace(add_api_route=lambda *args, **kwargs: routes.append((args, kwargs))),
                _active_llamacpp_model_id=lambda: "small-q4")
            bootstrap = SimpleNamespace(__file__=str(root / "hermes_cli/local_runtime/bootstrap.py"), staged_model_ids=lambda: ["small-q4"])
            endpoint = SimpleNamespace(__file__=str(root / "hermes_cli/local_runtime/endpoint.py"), managed_root=lambda: ("http://127.0.0.1:99", "fixture"))
            class HTTPException(Exception):
                def __init__(self, status_code, detail): self.status_code = status_code; self.detail = detail
            modules = {"fastapi": SimpleNamespace(HTTPException=HTTPException, Request=object),
                       "hermes_cli": SimpleNamespace(web_server=SimpleNamespace(_has_valid_session_token=lambda r: r == "authorized")),
                       "hermes_cli.web_routers": SimpleNamespace(local_models=local),
                       "hermes_cli.local_runtime": SimpleNamespace(bootstrap=bootstrap, endpoint=endpoint)}
            with patch.dict(sys.modules, modules), patch.object(entry, "MODEL_PROBE_SOURCE_HASHES", hashes):
                entry._install_local_reply_probe(root)
                self.assertEqual(routes[0][0][0], "/api/nollie/local-model/reply-check")
                self.assertEqual(routes[0][1], {"methods": ["POST"]})
                route = routes[0][0][1]
                with self.assertRaises(HTTPException) as denied: route("unauthorized")
                self.assertEqual(denied.exception.status_code, 401)
                with self.assertRaises(HTTPException) as denied: route("authorized", "private")
                self.assertEqual(denied.exception.status_code, 403)
                with patch.object(entry, "_perform_local_reply", side_effect=ValueError("secret")):
                    with self.assertRaises(HTTPException) as failure: route("authorized")
                self.assertEqual(failure.exception.status_code, 503)
                self.assertNotIn("secret", failure.exception.detail)


if __name__ == "__main__":
    unittest.main()
