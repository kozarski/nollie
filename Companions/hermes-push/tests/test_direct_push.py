"""Direct APNs delivery: no secrets in the process list or the log, and no chat words in the clear."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

SCRIPT = Path(__file__).resolve().parents[1] / "hermes_push.py"
spec = importlib.util.spec_from_file_location("push_direct_test", SCRIPT)
companion = importlib.util.module_from_spec(spec)
spec.loader.exec_module(companion)

BEARER = "PROVIDER-TOKEN-SECRET"
DEVICE_TOKEN = "d3v1c3t0k3n" * 5
TITLE, BODY, TEXT, THREAD = "Scout", "The invoice is ready", "Invoice 7 totals 1200", "line from the chat"


def envelope():
    return {"aps": {"alert": {"title": TITLE, "body": BODY}, "thread-id": "s-1", "category": "HERMES_TURN",
                    "interruption-level": "active", "sound": "default"},
            "hermes": {"kind": "reply", "gateway": "https://gw.example", "session_id": "s-1", "profile": "career",
                       "title": TITLE, "text": TEXT, "thread": [THREAD]}}


def sender():
    apns = companion.APNs.__new__(companion.APNs)
    apns.direct, apns.topic, apns.force_sandbox = True, "com.example.app", False
    apns.key_id, apns.team_id, apns._pem, apns._jwt = "K", "T", "", ("", 0.0)
    apns.last_response = ""
    apns._provider_token = lambda: BEARER
    return apns


def device(**more):
    return {"device_id": "phone-1", "platform": "ios", "apns_token": DEVICE_TOKEN, **more}


class Curl:
    """Stands in for subprocess.run and keeps what curl would have been given."""

    def __init__(self, result=None):
        self.calls, self.result = [], result

    def __call__(self, command, **kwargs):
        self.calls.append((command, kwargs.get("input", "")))
        if isinstance(self.result, Exception):
            raise self.result
        return self.result or subprocess.CompletedProcess(command, 0, stdout="\n200", stderr="")


class SecretsStayOffTheCommandLine(unittest.TestCase):
    def test_the_command_holds_no_token_and_the_config_on_stdin_holds_both(self):
        curl = Curl()
        with patch.object(companion.subprocess, "run", curl):
            self.assertTrue(sender().send(device(), envelope(), collapse_id="c"))
        command, config = curl.calls[0]
        self.assertEqual(command[-2:], ["-K", "-"])
        joined = " ".join(command)
        for secret in (BEARER, DEVICE_TOKEN, "authorization", "bearer", "api.push.apple.com"):
            self.assertNotIn(secret, joined)
        self.assertIn(f"header = \"authorization: bearer {BEARER}\"", config)
        self.assertIn(f"/3/device/{DEVICE_TOKEN}", config)
        self.assertIn("data-binary = ", config)

    def test_the_config_escapes_what_would_break_a_line(self):
        config = companion.curl_config("https://h/x", [("a", 'v"1\\2')], 'one\ntwo "q"')
        self.assertEqual(config.splitlines(), ['url = "https://h/x"', 'header = "a: v\\"1\\\\2"',
                                              'data-binary = "one\\ntwo \\"q\\""'])

    def test_a_timeout_logs_a_fixed_line_without_the_command(self):
        command = ["curl", "-H", f"authorization: bearer {BEARER}", f"https://h/3/device/{DEVICE_TOKEN}"]
        curl = Curl(subprocess.TimeoutExpired(command, 30))
        with patch.object(companion.subprocess, "run", curl), self.assertLogs("hermes-push", "WARNING") as logged:
            self.assertFalse(sender().send(device(), envelope()))
        text = "\n".join(logged.output)
        self.assertIn("timed out", text)
        for secret in (BEARER, DEVICE_TOKEN, "authorization"):
            self.assertNotIn(secret, text)

    def test_any_other_failure_logs_no_exception_text(self):
        curl = Curl(OSError(f"cannot run with {BEARER} for {DEVICE_TOKEN}"))
        with patch.object(companion.subprocess, "run", curl), self.assertLogs("hermes-push", "WARNING") as logged:
            self.assertFalse(sender().send(device(), envelope()))
        text = "\n".join(logged.output)
        self.assertIn("could not be run", text)
        for secret in (BEARER, DEVICE_TOKEN):
            self.assertNotIn(secret, text)

    def test_a_dry_run_starts_nothing(self):
        apns = sender()
        apns.dry_run = True
        curl = Curl()
        with patch.object(companion.subprocess, "run", curl):
            self.assertTrue(apns.send(device(), envelope()))
        self.assertEqual(curl.calls, [])


class DirectAlertsAreGeneric(unittest.TestCase):
    def sent(self, target):
        curl = Curl()
        with patch.object(companion.subprocess, "run", curl):
            self.assertTrue(sender().send(target, envelope()))
        config = curl.calls[0][1]
        line = next(row for row in config.splitlines() if row.startswith("data-binary = "))
        return json.loads(json.loads(line[len("data-binary = "):]))

    def test_without_a_payload_key_only_the_generic_words_go(self):
        payload = self.sent(device())
        self.assertEqual(payload["aps"]["alert"], {"title": "Nollie", "body": "New message"})
        self.assertEqual(payload["aps"]["mutable-content"], 1)
        self.assertNotIn("enc", payload)
        wire = json.dumps(payload)
        for words in (TITLE, BODY, TEXT, THREAD, "reply"):
            self.assertNotIn(words, wire)
        self.assertEqual(payload["hermes"], {"gateway": "https://gw.example", "session_id": "s-1", "profile": "career"})

    def test_with_a_payload_key_the_real_words_go_sealed(self):
        key = base64.b64encode(os.urandom(32)).decode()
        payload = self.sent(device(payload_key=key))
        self.assertEqual(payload["aps"]["alert"], {"title": "Nollie", "body": "New message"})
        self.assertEqual(payload["aps"]["mutable-content"], 1)
        wire = json.dumps(payload["aps"]) + json.dumps(payload["hermes"])
        for words in (TITLE, BODY, TEXT, THREAD):
            self.assertNotIn(words, wire)
        raw = base64.b64decode(payload["enc"])
        opened = json.loads(AESGCM(base64.b64decode(key)).decrypt(raw[:12], raw[12:], None))
        self.assertEqual((opened["title"], opened["body"], opened["category"]), (TITLE, BODY, "HERMES_TURN"))
        self.assertEqual(opened["hermes"]["text"], TEXT)
        self.assertEqual(opened["thread_id"], "s-1")

    def test_a_key_that_cannot_seal_falls_back_to_the_generic_words(self):
        with self.assertLogs("hermes-push", "WARNING"):
            payload = self.sent(device(payload_key="not base64 at all!"))
        self.assertNotIn("enc", payload)
        self.assertNotIn(BODY, json.dumps(payload))

    def test_the_test_alert_and_other_push_types_are_left_alone(self):
        note = {"aps": {"alert": {"title": "Push is working", "body": "ok"}}, "hermes": {"kind": "test"}}
        self.assertIs(companion.APNs._direct_alert(device(), note), note)
        curl = Curl()
        ping = {"aps": {"content-available": 1}, "hermes": {"kind": "complication"}}
        with patch.object(companion.subprocess, "run", curl):
            sender().send(device(), ping, push_type="complication")
        self.assertNotIn("mutable-content", curl.calls[0][1])

    def test_the_relay_still_gets_everything_sealed_as_before(self):
        key = base64.b64encode(os.urandom(32)).decode()
        target = device(payload_key=key, relay={"url": "https://r.example", "install_id": "i", "secret": "s"})
        request = sender()._relay_request(target, "alert", envelope(), "c", None)
        self.assertEqual(set(request), {"push_type", "enc", "collapse_id", "thread_id", "interruption"})
        raw = base64.b64decode(request["enc"])
        opened = json.loads(AESGCM(base64.b64decode(key)).decrypt(raw[:12], raw[12:], None))
        self.assertEqual((opened["title"], opened["body"]), (TITLE, BODY))


if __name__ == "__main__":
    unittest.main()
