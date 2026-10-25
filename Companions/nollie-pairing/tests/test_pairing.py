"""Temporary storage and the real Hermes auth router; no running gateway is contacted."""
import base64
import concurrent.futures
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from urllib.parse import parse_qs, urlsplit

SOURCE = os.environ.get("HERMES_SOURCE")
if not SOURCE:
    raise RuntimeError("Set HERMES_SOURCE to the Hermes source checkout to test.")
_HOME = tempfile.TemporaryDirectory(prefix="nollie-pairing-hermes-")
os.environ["HERMES_HOME"] = _HOME.name
os.environ["HERMES_RUNTIME_DIR"] = str(Path(_HOME.name) / "runtime")
sys.path.insert(0, SOURCE)
ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


core = load("pairing_test_provider", ROOT / "provider.py")
from hermes_cli.dashboard_auth import (clear_providers, register_provider, InvalidCredentialsError,
                                      RefreshExpiredError, ProviderError, assert_protocol_compliance)


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.now = 1000000
        self.monotonic = 1000000
        self.root = Path(self.temp.name) / "pairing"
        self.enabled = True
        self.provider = core.PairingProvider(self.root, clock=lambda: self.now, monotonic=lambda: self.monotonic, enabled=lambda: self.enabled)
        self.owner = "a" * 64

    def create(self):
        return self.provider.create_invitation(self.owner, "Test iPhone")

    def pair(self, invitation=None):
        item = invitation or self.create()
        return self.provider.complete_password_login(username=item["id"], password=item["grant"])

    def test_provider_obeys_supported_protocol(self):
        assert_protocol_compliance(core.PairingProvider)

    def test_one_use_and_independent_device_credentials(self):
        invitation = self.create()
        session = self.pair(invitation)
        self.assertNotEqual(session.access_token, invitation["grant"])
        self.assertNotEqual(session.refresh_token, session.access_token)
        self.assertEqual(self.provider.verify_session(access_token=session.access_token).provider, "nollie-pairing")
        self.assertEqual(self.provider.invitation_status(self.owner, invitation["id"]), {"state": "paired"})
        with self.assertRaises(InvalidCredentialsError):
            self.pair(invitation)

    def test_expiry_is_exactly_two_minutes(self):
        invitation = self.create()
        self.now += 120
        with self.assertRaises(InvalidCredentialsError):
            self.pair(invitation)
        self.assertEqual(self.provider.invitation_status(self.owner, invitation["id"])["state"], "expired")

    def test_cancel_blocks_redemption_but_successful_sheet_close_keeps_device(self):
        invitation = self.create()
        self.provider.cancel_invitation(self.owner, invitation["id"])
        with self.assertRaises(InvalidCredentialsError):
            self.pair(invitation)
        paired = self.create()
        session = self.pair(paired)
        self.provider.cancel_invitation(self.owner, paired["id"])
        self.assertIsNotNone(self.provider.verify_session(access_token=session.access_token))

    def test_clock_rollback_cannot_extend_invitation(self):
        invitation = self.create()
        self.now -= 300
        self.monotonic += 120
        with self.assertRaises(InvalidCredentialsError):
            self.pair(invitation)

    def test_five_wrong_attempts_consume_invitation(self):
        invitation = self.create()
        for _ in range(5):
            with self.assertRaises(InvalidCredentialsError):
                self.provider.complete_password_login(username=invitation["id"], password="0" * 64)
        with self.assertRaises(InvalidCredentialsError):
            self.pair(invitation)

    def test_unknown_attempts_are_globally_bounded(self):
        invitation = self.create()
        for _ in range(60):
            with self.assertRaises(InvalidCredentialsError):
                self.provider.complete_password_login(username="unknown", password="invalid")
        with self.assertRaises(InvalidCredentialsError):
            self.pair(invitation)
        self.now += 60
        self.assertIsNotNone(self.pair(invitation))

    def test_pending_capacity_and_create_rate_are_bounded(self):
        for _ in range(core.MAX_INVITATIONS):
            self.create()
        with self.assertRaises(OverflowError):
            self.create()

    def test_two_racing_redemptions_issue_only_one_device(self):
        invitation = self.create()
        def run():
            try:
                self.pair(invitation)
                return True
            except InvalidCredentialsError:
                return False
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            results = list(pool.map(lambda _: run(), range(2)))
        self.assertEqual(results.count(True), 1)
        self.assertEqual(len(self.provider.list_devices(self.owner)), 1)

    def test_refresh_rotates_and_old_access_and_refresh_fail(self):
        first = self.pair()
        refreshed = self.provider.refresh_session(refresh_token=first.refresh_token)
        self.assertIsNone(self.provider.verify_session(access_token=first.access_token))
        with self.assertRaises(RefreshExpiredError):
            self.provider.refresh_session(refresh_token=first.refresh_token)
        self.assertIsNotNone(self.provider.verify_session(access_token=refreshed.access_token))

    def test_restart_keeps_devices_but_loses_pending_grants(self):
        session = self.pair()
        pending = self.create()
        other = core.PairingProvider(self.root, clock=lambda: self.now)
        self.assertIsNotNone(other.verify_session(access_token=session.access_token))
        with self.assertRaises(InvalidCredentialsError):
            other.complete_password_login(username=pending["id"], password=pending["grant"])

    def test_revoke_one_device_keeps_another(self):
        first, second = self.pair(), self.pair()
        self.provider.revoke_device(self.owner, first.user_id.removeprefix("nollie-device:"))
        self.assertIsNone(self.provider.verify_session(access_token=first.access_token))
        self.assertIsNotNone(self.provider.verify_session(access_token=second.access_token))

    def test_logout_revokes_access_and_refresh(self):
        session = self.pair()
        self.provider.revoke_session(refresh_token=session.refresh_token)
        self.assertIsNone(self.provider.verify_session(access_token=session.access_token))

    def test_owner_cannot_query_cancel_or_revoke_another_owner(self):
        invitation = self.create()
        with self.assertRaises(KeyError):
            self.provider.cancel_invitation("b" * 64, invitation["id"])
        session = self.pair(invitation)
        with self.assertRaises(KeyError):
            self.provider.revoke_device("b" * 64, invitation["id"])
        self.assertEqual(self.provider.list_devices("b" * 64), [])
        self.assertIsNotNone(self.provider.verify_session(access_token=session.access_token))

    def test_no_raw_credentials_persist_and_permissions_are_private(self):
        invitation = self.create()
        session = self.pair(invitation)
        raw = (self.root / "devices.json").read_text()
        for secret in (invitation["grant"], session.access_token, session.refresh_token):
            self.assertNotIn(secret, raw)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.root / "devices.json").stat().st_mode & 0o777, 0o600)

    def test_disable_rejects_pending_and_existing_credentials(self):
        session, invitation = self.pair(), self.create()
        self.enabled = False
        self.assertIsNone(self.provider.verify_session(access_token=session.access_token))
        with self.assertRaises(InvalidCredentialsError):
            self.pair(invitation)
        with self.assertRaises(RefreshExpiredError):
            self.provider.refresh_session(refresh_token=session.refresh_token)

    def test_storage_symlink_and_unsafe_mode_fail_closed(self):
        outside = Path(self.temp.name) / "outside"
        outside.mkdir()
        self.root.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ProviderError):
            self.create()
        self.assertEqual(list(outside.iterdir()), [])
        self.root.unlink()
        self.root.mkdir(mode=0o755)
        with self.assertRaises(ProviderError):
            self.create()

    def test_corrupt_store_is_not_overwritten(self):
        self.pair()
        path = self.root / "devices.json"
        path.write_text("[]")
        with self.assertRaises(ProviderError):
            self.create()
        self.assertEqual(path.read_text(), "[]")


class NativeHTTPTests(unittest.TestCase):
    def setUp(self):
        from fastapi import FastAPI
        from fastapi.testclient import TestClient
        from hermes_cli.dashboard_auth import routes, native_flow, Session
        from hermes_cli.dashboard_auth.middleware import gated_auth_middleware
        clear_providers()
        native_flow._reset_for_tests()
        self.addCleanup(clear_providers)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.provider = core.PairingProvider(Path(self.temp.name) / "pairing")
        register_provider(self.provider)
        plugin = load("pairing_test_router", ROOT / "dashboard" / "plugin_api.py")
        app = FastAPI()
        app.state.auth_required = True
        @app.middleware("http")
        async def auth(request, call_next):
            if request.headers.get("Authorization") == "Bearer fixture-original-mac":
                request.state.session = Session("owner", "", "", "", "fixture", 9999999999, "fixture-original-mac", "")
                return await call_next(request)
            return await gated_auth_middleware(request, call_next)
        app.include_router(routes.router)
        app.include_router(plugin.router, prefix="/api/plugins/nollie-pairing")
        self.app = app
        self.client = TestClient(app, base_url="https://pairing.example.test")
        self.addCleanup(self.client.close)
        self.headers = {"Authorization": "Bearer fixture-original-mac"}
        self.path = "/api/plugins/nollie-pairing"

    def create(self):
        response = self.client.post(self.path + "/invitations", headers=self.headers, json={"device_name": "Fixture iPhone"})
        self.assertEqual(response.status_code, 200)
        return response.json()

    def redeem(self, invitation, verifier="a" * 64):
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        response = self.client.get("/auth/native/authorize", params={"provider": "nollie-pairing", "code_challenge": challenge,
            "code_challenge_method": "S256", "redirect_uri": "http://127.0.0.1:1/callback", "state": "fixture-state"}, follow_redirects=False)
        self.assertEqual(response.status_code, 302)
        response = self.client.post("/auth/password-login", json={"provider": "nollie-pairing", "username": invitation["id"], "password": invitation["grant"]})
        self.assertEqual(response.status_code, 200)
        query = parse_qs(urlsplit(response.json()["next"]).query)
        self.assertEqual(query["state"], ["fixture-state"])
        response = self.client.post("/auth/native/token", json={"code": query["code"][0], "code_verifier": verifier})
        self.assertEqual(response.status_code, 200)
        return response.json(), query["code"][0]

    def test_real_native_flow_refresh_and_ws_ticket(self):
        tokens, code = self.redeem(self.create())
        self.assertEqual(tokens["provider"], "nollie-pairing")
        bearer = {"Authorization": "Bearer " + tokens["access_token"]}
        me = self.client.get("/api/auth/me", headers=bearer)
        self.assertEqual(me.status_code, 200)
        self.assertTrue(me.json()["user_id"].startswith("nollie-device:"))
        ticket = self.client.post("/api/auth/ws-ticket", headers=bearer)
        self.assertEqual(ticket.status_code, 200)
        self.assertIn("ticket", ticket.json())
        replay = self.client.post("/auth/native/token", json={"code": code, "code_verifier": "a" * 64})
        self.assertEqual(replay.status_code, 400)
        refreshed = self.client.post("/auth/native/refresh", json={"provider": "nollie-pairing", "refresh_token": tokens["refresh_token"]})
        self.assertEqual(refreshed.status_code, 200)
        self.assertNotEqual(refreshed.json()["access_token"], tokens["access_token"])

    def test_paired_phone_cannot_enroll_another_device(self):
        tokens, _ = self.redeem(self.create())
        headers = {"Authorization": "Bearer " + tokens["access_token"]}
        response = self.client.post(self.path + "/invitations", headers=headers, json={})
        self.assertEqual(response.status_code, 403)

    def test_unauthenticated_create_rejected_and_capability_is_honest(self):
        self.assertEqual(self.client.post(self.path + "/invitations", json={}).status_code, 401)
        self.assertTrue(self.client.get(self.path + "/capabilities", headers=self.headers).json()["supported"])
        self.app.state.auth_required = False
        self.assertFalse(self.client.get(self.path + "/capabilities", headers=self.headers).json()["supported"])
        self.assertEqual(self.client.post(self.path + "/invitations", headers=self.headers, json={}).status_code, 409)

    def test_http_and_spoofed_forwarded_proto_do_not_enable_pairing(self):
        from fastapi.testclient import TestClient
        with TestClient(self.app, base_url="http://pairing.example.test") as client:
            response = client.get(self.path + "/capabilities", headers={**self.headers, "X-Forwarded-Proto": "https"})
            self.assertFalse(response.json()["supported"])

    def test_cancel_and_revoke_endpoints(self):
        invitation = self.create()
        self.assertEqual(self.client.delete(self.path + "/invitations/" + invitation["id"], headers=self.headers).status_code, 200)
        self.assertEqual(self.client.get(self.path + "/invitations/" + invitation["id"], headers=self.headers).json()["state"], "cancelled")
        second = self.create()
        tokens, _ = self.redeem(second)
        self.assertEqual(self.client.delete(self.path + "/devices/" + second["id"], headers=self.headers).status_code, 200)
        self.assertEqual(self.client.get("/api/auth/me", headers={"Authorization": "Bearer " + tokens["access_token"]}).status_code, 401)

    def test_phone_can_revoke_only_itself_without_other_device_id(self):
        first, _ = self.redeem(self.create())
        second, _ = self.redeem(self.create())
        first_headers = {"Authorization": "Bearer " + first["access_token"]}
        self.assertEqual(self.client.delete(self.path + "/device", headers=first_headers).status_code, 200)
        self.assertEqual(self.client.get("/api/auth/me", headers=first_headers).status_code, 401)
        self.assertEqual(self.client.get("/api/auth/me", headers={"Authorization": "Bearer " + second["access_token"]}).status_code, 200)
        self.assertEqual(self.client.delete(self.path + "/device", headers=self.headers).status_code, 401)


if __name__ == "__main__":
    unittest.main(verbosity=2)
