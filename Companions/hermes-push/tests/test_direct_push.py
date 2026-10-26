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
# The app puts a key in every device file it writes.
KEY = base64.b64encode(bytes(range(32))).decode()


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
    return {"device_id": "phone-1", "platform": "ios", "apns_token": DEVICE_TOKEN, "payload_key": KEY, **more}


def opened(sealed, key=KEY):
    raw = base64.b64decode(sealed)
    return json.loads(AESGCM(base64.b64decode(key)).decrypt(raw[:12], raw[12:], None))


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


class DirectAlertsAreSealed(unittest.TestCase):
    def sent(self, target, note=None):
        curl = Curl()
        with patch.object(companion.subprocess, "run", curl):
            self.assertTrue(sender().send(target, note or envelope()))
        config = curl.calls[0][1]
        line = next(row for row in config.splitlines() if row.startswith("data-binary = "))
        return json.loads(json.loads(line[len("data-binary = "):]))

    def test_the_real_words_go_sealed_with_the_devices_key(self):
        payload = self.sent(device())
        self.assertEqual(payload["aps"]["alert"], {"title": "Nollie", "body": "New message"})
        self.assertEqual(payload["aps"]["mutable-content"], 1)
        wire = json.dumps(payload["aps"]) + json.dumps(payload["hermes"])
        for words in (TITLE, BODY, TEXT, THREAD):
            self.assertNotIn(words, wire)
        inside = opened(payload["enc"])
        self.assertEqual((inside["title"], inside["body"], inside["category"]), (TITLE, BODY, "HERMES_TURN"))
        self.assertEqual(inside["hermes"]["text"], TEXT)
        self.assertEqual(inside["thread_id"], "s-1")

    def test_the_buttons_and_routing_work_without_the_extension(self):
        note = envelope()
        note["aps"]["category"] = "HERMES_APPROVAL"
        note["hermes"].update(kind="approval", request_id="rq-9")
        payload = self.sent(device(), note)
        self.assertEqual(payload["aps"]["category"], "HERMES_APPROVAL")
        self.assertEqual(payload["hermes"], {"kind": "approval", "gateway": "https://gw.example", "session_id": "s-1",
                                             "profile": "career", "request_id": "rq-9"})

    def test_the_devices_own_connection_is_named_so_the_right_private_list_counts(self):
        connection = "6F1B3C2A-9D4E-4F5A-8B7C-1D2E3F4A5B6C"
        payload = self.sent(device(connection_id=connection))
        self.assertEqual(payload["hermes"]["connection_id"], connection)
        self.assertEqual(opened(payload["enc"])["hermes"]["connection_id"], connection)
        target = device(connection_id=connection, relay={"url": "https://r.example", "install_id": "i", "secret": "s"})
        request = sender()._relay_request(target, "alert", envelope(), "c", None)
        self.assertEqual(opened(request["enc"])["hermes"]["connection_id"], connection)

    def test_a_device_file_from_an_older_app_without_a_key_gets_only_the_generic_words(self):
        payload = self.sent(device(payload_key=None))
        self.assertEqual(payload["aps"]["alert"], {"title": "Nollie", "body": "New message"})
        self.assertEqual(payload["aps"]["mutable-content"], 1)
        self.assertEqual(payload["aps"]["category"], "HERMES_TURN")
        self.assertNotIn("enc", payload)
        wire = json.dumps(payload)
        for words in (TITLE, BODY, TEXT, THREAD):
            self.assertNotIn(words, wire)
        self.assertEqual(payload["hermes"], {"kind": "reply", "gateway": "https://gw.example", "session_id": "s-1",
                                             "profile": "career"})

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
        inside = opened(request["enc"], key)
        self.assertEqual((inside["title"], inside["body"]), (TITLE, BODY))


class SealedAlertsFitApplesLimit(unittest.TestCase):
    """Apple refuses a payload over 4 KB, and text outside ASCII takes more room than it looks."""

    def long_envelope(self, text, body=BODY, thread=()):
        note = envelope()
        note["aps"]["alert"]["body"] = body
        note["hermes"].update(text=text, thread=list(thread))
        companion.trim_for_apple(note["hermes"])
        return note

    def check_fits(self, note):
        payload = companion.APNs._direct_alert(device(), note)
        self.assertLessEqual(len(json.dumps(payload).encode()), companion.APPLE_LIMIT)
        self.assertIn("enc", payload)
        return opened(payload["enc"])

    def test_a_long_reply_in_another_script_still_fits_once_sealed(self):
        for letter in ("字", "é", "🦊"):
            text = letter * 3000
            inside = self.check_fits(self.long_envelope(text, thread=[letter * 200] * 5))
            self.assertTrue(inside["hermes"]["text"])
            self.assertTrue(text.startswith(inside["hermes"]["text"]))

    def test_a_long_body_is_shortened_too(self):
        inside = self.check_fits(self.long_envelope("short", body="長" * 2000))
        self.assertTrue(inside["body"])
        self.assertLess(len(inside["body"]), 2000)

    def test_the_words_are_sealed_as_they_are_measured(self):
        content = {"title": "Moss", "body": "🦊 voilà", "hermes": {"text": "字" * 10}}
        sealed = companion.seal_for_device(device(), content)
        self.assertEqual(len(base64.b64decode(sealed)), len(companion.packed(content)) + companion.SEAL_OVERHEAD)
        self.assertEqual(opened(sealed), content)

    def test_the_trim_measures_what_is_sealed(self):
        hermes = {"text": "字" * 2000}
        companion.trim_for_apple(hermes)
        self.assertLessEqual(len(companion.packed(hermes)), 2300)

    def test_short_words_are_left_whole(self):
        self.assertEqual(opened(companion.seal_for_device(device(), {"body": BODY, "hermes": {"text": TEXT}})),
                         {"body": BODY, "hermes": {"text": TEXT}})


if __name__ == "__main__":
    unittest.main()
