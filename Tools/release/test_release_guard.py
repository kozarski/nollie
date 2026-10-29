#!/usr/bin/env python3
"""Offline release checks. Fixtures never read credentials or contact Apple."""
import copy
import io
import json
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import release_guard as guard


def signing_fixture(platform="ios"):
    app_key = "com.apple.application-identifier" if platform == "macos" else "application-identifier"
    aps_key = "com.apple.developer.aps-environment" if platform == "macos" else "aps-environment"
    entitlements = {
        app_key: guard.TEAM_ID + "." + guard.BUNDLE_ID,
        aps_key: "production",
        "com.apple.developer.team-identifier": guard.TEAM_ID,
        "com.apple.developer.icloud-container-identifiers": [guard.CLOUD_CONTAINER],
        "com.apple.developer.icloud-container-environment": "Production",
        "com.apple.developer.icloud-services": ["CloudKit"],
    }
    return ({"CFBundleIdentifier": guard.BUNDLE_ID, "CFBundleVersion": "7"}, entitlements,
            {"TeamIdentifier": [guard.TEAM_ID], "Entitlements": copy.deepcopy(entitlements)})


class IdentityTests(unittest.TestCase):
    def test_only_exact_app_identity_is_accepted(self):
        calls = []
        def fetch(path):
            calls.append(path)
            return 200, {"data": {"id": "123", "type": "apps", "attributes": {"bundleId": guard.BUNDLE_ID}}}
        guard.require_app_identity("123", fetch)
        self.assertEqual(calls, ["/apps/123?fields[apps]=bundleId"])

    def test_wrong_app_missing_identity_and_http_errors_fail_closed(self):
        cases = [
            (200, {"data": {"id": "123", "type": "apps", "attributes": {"bundleId": "com.example.other-app"}}}),
            (200, {"data": {"id": "456", "type": "apps", "attributes": {"bundleId": guard.BUNDLE_ID}}}),
            (200, {"data": {"id": "123", "type": "apps", "attributes": {}}}),
            (200, {"data": []}), (401, {}), (500, {}),
        ]
        for response in cases:
            with self.subTest(response=response), self.assertRaises(guard.GuardError):
                guard.require_app_identity("123", lambda path: response)

    def test_invalid_app_id_does_not_make_a_request(self):
        for app_id in (None, "", "123/other", "123?filter=x"):
            with self.subTest(app_id=app_id), self.assertRaises(guard.GuardError):
                guard.require_app_identity(app_id, lambda path: self.fail("Unexpected request"))

    def test_network_errors_do_not_echo_sensitive_error_text(self):
        def fail(path):
            raise RuntimeError("fixture-token-must-not-appear")
        with self.assertRaises(guard.GuardError) as result:
            guard.require_app_identity("123", fail)
        self.assertNotIn("fixture-token", str(result.exception))

    def test_standalone_listing_and_feedback_stop_before_any_mutation(self):
        class Response:
            status = 200
            headers = {"Content-Type": "application/json"}
            def read(self):
                return json.dumps({"data": {"id": "123", "type": "apps", "attributes": {"bundleId": "com.example.other-app"}}}).encode()
            def __enter__(self): return self
            def __exit__(self, *args): pass
        env = {"ASC_APP_ID": "123", "ASC_KEY_ID": "fixture", "ASC_ISSUER_ID": "fixture",
               "ASC_KEY_PATH": "/never-read", "NOLLIE_GITHUB_REPO": "fixture/fixture"}
        for script, args in [("asc-listing.py", ["screenshots"]), ("feedback-issues.py", ["--dry-run"])]:
            requests = []
            def open_fixture(request):
                requests.append((request.get_method(), request.full_url))
                return Response()
            with self.subTest(script=script), patch.object(guard, "release_environment", return_value=env), \
                 patch.dict(os.environ, env, clear=True), patch.object(sys, "argv", [script] + args), \
                 patch("subprocess.check_output", return_value=b"fixture-token"), \
                 patch("urllib.request.urlopen", side_effect=open_fixture), \
                 patch("subprocess.run", side_effect=AssertionError("No tracker or screenshot operation allowed")), \
                 patch("sys.stdout", new_callable=io.StringIO), self.assertRaises(SystemExit):
                runpy.run_path(str(Path(__file__).with_name(script)), run_name="__main__")
            self.assertEqual(requests, [("GET", guard.API + "/apps/123?fields[apps]=bundleId")])


class SignerTests(unittest.TestCase):
    def test_only_coreys_own_certificates_sign_an_archive(self):
        guard.require_named_signer(["Apple Development: Corey Kozarski (G7LTSB66HB)", "Apple Root CA"])
        guard.require_named_signer(iter(["Apple Distribution: Corey Kozarski (5985LRZFZS)"]))
        for leaf in (["Apple Development: Created via API (LA7B5435SG)"], ["Apple Development: Someone Else"], []):
            with self.assertRaises(guard.GuardError):
                guard.require_named_signer(leaf)


class ExportTests(unittest.TestCase):
    def test_store_client_cannot_include_direct_services(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Nollie.app"
            app.mkdir()
            guard.require_client_contents(app)
            for relative in ("Helpers/Nollie Runtime.app", "Library/Helpers/Nollie Runtime.app",
                             "Library/LaunchAgents/com.coreykozarski.nollie.runtime.plist",
                             "Library/LoginItems/Nollie Notifications.app"):
                with self.subTest(relative=relative):
                    path = app / "Contents" / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.touch()
                    with self.assertRaises(guard.GuardError):
                        guard.require_client_contents(app)
                    path.unlink()

    def check(self, info, entitlements, profile, platform="ios", identifier=guard.BUNDLE_ID, team=guard.TEAM_ID):
        guard.require_export_metadata(info, identifier, team, entitlements, profile, platform, "7")

    def test_ios_and_mac_production_signatures_pass(self):
        for platform in ("ios", "macos"):
            self.check(*signing_fixture(platform), platform=platform)

    def test_wrong_product_team_build_or_signed_identifier_is_rejected(self):
        for change in ("bundle", "build", "team", "identifier", "entitlement-team", "application-identifier"):
            with self.subTest(change=change), self.assertRaises(guard.GuardError):
                info, entitlements, profile = signing_fixture()
                kwargs = {}
                if change == "bundle": info["CFBundleIdentifier"] = "com.example.other-app"
                elif change == "build": info["CFBundleVersion"] = "6"
                elif change == "team": kwargs["team"] = "WRONGTEAM1"
                elif change == "identifier": kwargs["identifier"] = "com.example.other-app"
                elif change == "entitlement-team": entitlements["com.apple.developer.team-identifier"] = "WRONGTEAM1"
                else: entitlements["application-identifier"] = guard.TEAM_ID + ".com.example.other-app"
                self.check(info, entitlements, profile, **kwargs)

    def test_missing_development_or_additional_cloud_entitlements_are_rejected(self):
        cases = {
            "aps-environment": [None, "development"],
            "com.apple.developer.icloud-container-environment": [None, "Development"],
            "com.apple.developer.icloud-container-identifiers": [[], ["iCloud.com.example.other-app"], [guard.CLOUD_CONTAINER, "iCloud.com.example.other-app"]],
            "com.apple.developer.icloud-services": [[], ["CloudDocuments"]],
            "get-task-allow": [True],
        }
        for key, values in cases.items():
            for value in values:
                with self.subTest(key=key, value=value), self.assertRaises(guard.GuardError):
                    info, entitlements, profile = signing_fixture()
                    entitlements[key] = value
                    self.check(info, entitlements, profile)

    def test_profile_alone_cannot_make_bad_signature_pass(self):
        info, entitlements, profile = signing_fixture()
        entitlements["aps-environment"] = "development"
        with self.assertRaises(guard.GuardError): self.check(info, entitlements, profile)

    def test_xcode_profile_granting_every_icloud_service_is_accepted(self):
        info, entitlements, profile = signing_fixture()
        profile["Entitlements"]["com.apple.developer.icloud-services"] = "*"
        profile["Entitlements"]["com.apple.developer.icloud-container-environment"] = ["Production", "Development"]
        self.check(info, entitlements, profile)

    def test_profile_without_cloudkit_is_rejected(self):
        for services in (None, [], ["CloudDocuments"], "CloudDocuments"):
            with self.subTest(services=services), self.assertRaises(guard.GuardError):
                info, entitlements, profile = signing_fixture()
                profile["Entitlements"]["com.apple.developer.icloud-services"] = services
                self.check(info, entitlements, profile)

    def test_wrong_or_nonproduction_profile_is_rejected(self):
        for change in ("team", "identity", "aps", "container", "environment"):
            with self.subTest(change=change), self.assertRaises(guard.GuardError):
                info, entitlements, profile = signing_fixture()
                if change == "team": profile["TeamIdentifier"] = ["WRONGTEAM1"]
                elif change == "identity": profile["Entitlements"]["application-identifier"] = "wrong"
                elif change == "aps": profile["Entitlements"]["aps-environment"] = "development"
                elif change == "container": profile["Entitlements"]["com.apple.developer.icloud-container-identifiers"] = []
                else: profile["Entitlements"]["com.apple.developer.icloud-container-environment"] = "Development"
                self.check(info, entitlements, profile)

    def test_export_inspects_real_signature_and_profile_before_accepting(self):
        info, entitlements, profile = signing_fixture()
        with tempfile.TemporaryDirectory() as directory:
            product = Path(directory) / "Nollie.ipa"
            with zipfile.ZipFile(product, "w") as package:
                package.writestr("Payload/Nollie.app/Info.plist", plistlib.dumps(info))
            calls = []
            def command(args):
                calls.append(args[:3])
                if args[0] == "ditto":
                    app = Path(args[-1]) / "Payload" / "Nollie.app"
                    app.mkdir(parents=True)
                    (app / "Info.plist").write_bytes(plistlib.dumps(info))
                elif args[0] == "security": return plistlib.dumps(profile)
                elif "--entitlements" in args: return plistlib.dumps(entitlements)
                return b""
            details = subprocess.CompletedProcess([], 0, stdout=b"", stderr=("Identifier=" + guard.BUNDLE_ID + "\nTeamIdentifier=" + guard.TEAM_ID + "\n").encode())
            with patch.object(guard, "command", side_effect=command), patch("subprocess.run", return_value=details):
                guard.verify_export(product, "ios", "7")
            self.assertIn(["codesign", "--verify", "--deep"], calls)
            self.assertIn(["security", "cms", "-D"], calls)

    def test_unsafe_ipa_paths_are_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.ipa"
            with zipfile.ZipFile(path, "w") as package: package.writestr("../outside", b"fixture")
            with self.assertRaises(guard.GuardError): guard.require_safe_ipa(path)


class ArchiveTests(unittest.TestCase):
    def test_missing_and_wrong_archive_metadata_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory)
            with self.assertRaises(guard.GuardError): guard.require_archive(archive, "7")
            app = archive / "Products/Applications/Nollie.app"
            app.mkdir(parents=True)
            info = {"CFBundleIdentifier": guard.BUNDLE_ID, "CFBundleVersion": "7"}
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            metadata = {**info, "ApplicationPath": "Applications/Nollie.app"}
            (archive / "Info.plist").write_bytes(plistlib.dumps({"ApplicationProperties": metadata}))
            signed = subprocess.CompletedProcess([], 0, stdout=b"", stderr=b"Authority=Apple Development: Corey Kozarski (G7LTSB66HB)\n")
            by_api = subprocess.CompletedProcess([], 0, stdout=b"", stderr=b"Authority=Apple Development: Created via API (LA7B5435SG)\n")
            with patch("subprocess.run", return_value=signed):
                guard.require_archive(archive, "7")
            with patch("subprocess.run", return_value=by_api), self.assertRaises(guard.GuardError):
                guard.require_archive(archive, "7")
            with self.assertRaises(guard.GuardError): guard.require_archive(archive, "8")
            info["CFBundleIdentifier"] = "com.example.other-app"
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            with self.assertRaises(guard.GuardError): guard.require_archive(archive, "7")

    def run_script(self, directory, *, archive_exit=9, existing=None):
        root = Path(directory)
        scripts = root / "Tools/release"
        scripts.mkdir(parents=True)
        shutil.copyfile(Path(__file__).with_name("testflight.sh"), scripts / "testflight.sh")
        # Only app identity is stubbed. Archive validation runs the production module.
        scripts.joinpath("release_guard.py").write_text(
            "import runpy,sys\nif sys.argv[1] != 'app': runpy.run_path(" + repr(str(Path(guard.__file__).resolve())) + ",run_name='__main__')\n")
        key = root / "fixture-key"
        key.write_text("not-a-credential")
        bin_dir = root / "bin"
        bin_dir.mkdir()
        marker = root / "commands"
        fake = bin_dir / "xcodebuild"
        fake.write_text("#!/bin/bash\nprintf '%s\\n' \"$1\" >> \"$FIXTURE_COMMANDS\"\n"
                        "while [ \"$#\" -gt 0 ]; do if [ \"$1\" = '-archivePath' ]; then shift; mkdir -p \"$1\"; fi; shift; done\n"
                        "exit " + str(archive_exit) + "\n")
        fake.chmod(0o755)
        if existing:
            (root / "build/archives" / existing).mkdir(parents=True)
        env = {**os.environ, "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"], "FIXTURE_COMMANDS": str(marker),
               "ASC_APP_ID": "123", "ASC_KEY_ID": "fixture", "ASC_ISSUER_ID": "fixture", "ASC_KEY_PATH": str(key),
               "BUILD_NUMBER": "7", "MARKETING_VERSION": "1.0", "PLATFORM": "ios", "DRY_RUN": "1"}
        env.pop("ARCHIVE_DIR", None)
        result = subprocess.run(["bash", str(scripts / "testflight.sh")], env=env, capture_output=True, text=True)
        return result, marker.read_text().splitlines() if marker.exists() else []

    def test_archive_failure_is_not_swallowed_even_when_it_leaves_a_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls = self.run_script(directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Archive failed", result.stderr)
            self.assertEqual(calls, ["archive"])

    def test_success_exit_without_complete_archive_cannot_export(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls = self.run_script(directory, archive_exit=0)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Release blocked", result.stderr)
            self.assertEqual(calls, ["archive"])

    def test_existing_archive_or_export_is_preserved_and_blocks_build(self):
        for existing in ("Nollie-7.xcarchive", "export-Nollie-7"):
            with self.subTest(existing=existing), tempfile.TemporaryDirectory() as directory:
                result, calls = self.run_script(directory, existing=existing)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("already exists", result.stderr)
                self.assertEqual(calls, [])
                self.assertTrue((Path(directory) / "build/archives" / existing).exists())


if __name__ == "__main__": unittest.main()
