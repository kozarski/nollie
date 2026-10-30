"""Offline checks for ship.py. Nothing here talks to Apple, GitHub or Cloudflare."""
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import ship

COREY = dict(author=ship.OWNER, email=ship.OWNER_EMAIL, committer=ship.OWNER, committer_email=ship.OWNER_EMAIL)
# Built in pieces so this file never holds anything that reads as a real key.
REALISH = "Q7rT2mVx9LpW4nZ8kJ3sH6dF1gB5yC0aE"


def project(version="1.2", build="6", count=3):
    rows = "".join(f"\t\t\t\tCURRENT_PROJECT_VERSION = {build};\n\t\t\t\tMARKETING_VERSION = {version};\n"
                   for _ in range(count))
    return f"// !$*UTF8*$!\n{{\n{rows}\t\t\t\tINFOPLIST_FILE = Apps/Info.plist;\n}}\n"


SCHEMA = """DEFINE SCHEMA

    RECORD TYPE NoteV1 (
        "___recordID" REFERENCE QUERYABLE,
        version INT64 QUERYABLE,
        box ENCRYPTED BYTES,
        GRANT CREATE TO "_icloud",
        GRANT READ, WRITE TO "_creator"
    );
"""

# The same schema as cktool exports it: sorted, padded, grants in another order.
EXPORTED = """DEFINE SCHEMA

    RECORD TYPE NoteV1 (
        "___recordID"   REFERENCE QUERYABLE,
        box             ENCRYPTED BYTES,
        version         INT64 QUERYABLE,
        GRANT READ, WRITE TO "_creator",
        GRANT CREATE TO "_icloud"
    );
"""


class VersionTests(unittest.TestCase):
    def test_versions_are_read_and_bumped_in_every_place(self):
        bumped = ship.bump_project(project(), "1.3", "7")
        self.assertEqual(ship.project_versions(bumped), (["1.3"] * 3, ["7"] * 3))

    def test_a_good_next_version_passes_and_an_already_bumped_one_too(self):
        self.assertEqual(ship.version_problems(project(), "1.3", "7", ("1.1", "5")), [])
        self.assertEqual(ship.version_problems(project("1.3", "7"), "1.3", "7", ("1.1", "5")), [])

    def test_mixed_older_taken_or_low_numbers_are_each_caught(self):
        mixed = project() + "MARKETING_VERSION = 1.1;\nCURRENT_PROJECT_VERSION = 6;\n"
        self.assertTrue(ship.version_problems(mixed, "1.3", "7"))
        self.assertTrue(ship.version_problems(project("1.4"), "1.3", "7"))
        self.assertTrue(ship.version_problems(project(), "1.3", "6"))
        self.assertTrue(ship.version_problems(project(), "1.3", "7", ("1.3", "5")))
        self.assertTrue(ship.version_problems(project(), "1.3", "7", ("1.1", "8")))
        self.assertTrue(ship.version_problems(project(), "1.3", "7", tag_taken=True))
        self.assertTrue(ship.version_problems(project("1.3", "6"), "1.3", "7"))

    def test_odd_versions_are_refused(self):
        for text in ("1", "v1.3", "1.3-beta", "", None):
            with self.subTest(text=text), self.assertRaises(ship.ShipError):
                ship.parse_version(text)
        self.assertGreater(ship.parse_version("1.10"), ship.parse_version("1.9"))
        self.assertEqual(ship.parse_version("1.3"), ship.parse_version("1.3.0"))

    def test_an_info_plist_with_its_own_number_is_caught(self):
        def read(numbers):
            return lambda path: plistlib.dumps({"CFBundleShortVersionString": numbers[0], "CFBundleVersion": numbers[1]})
        self.assertEqual(ship.info_plist_problems(project(), read(("$(MARKETING_VERSION)", "$(CURRENT_PROJECT_VERSION)"))), [])
        self.assertEqual(len(ship.info_plist_problems(project(), read(("1.2", "6")))), 2)


class CommitTests(unittest.TestCase):
    def commit(self, body, **who):
        return dict(COREY, sha="a" * 40, body=body, **who)

    def test_coreys_own_commits_pass_even_when_they_name_a_plan(self):
        bodies = ["Plans: sign in with your ChatGPT or Claude plan", "Merge release-1.2: the weekly note",
                  "Papertrail: every connection the assistant makes"]
        self.assertEqual(ship.commit_problems([self.commit(body) for body in bodies]), [])

    def test_attribution_of_every_kind_is_caught(self):
        bodies = ["Fix\n\n" + "Co-" + "Authored-By: Someone <x@y.z>",
                  "Fix\n\nGenerated with " + "Claude Code",
                  "Fix, written with the help of an AI assistant",
                  "Fix\n\nhttps://claude" + ".ai/code/session_1",
                  "Fix\n\nnoreply@" + "anthropic.com",
                  "Fix \U0001F916",
                  "AI-generated tests"]
        for body in bodies:
            with self.subTest(body=body):
                self.assertTrue(ship.commit_problems([self.commit(body)]))

    def test_another_author_or_committer_is_caught(self):
        self.assertTrue(ship.commit_problems([self.commit("Fix", author="Someone Else")]))
        self.assertTrue(ship.commit_problems([self.commit("Fix", committer_email="bot@example.com")]))


class SecretTests(unittest.TestCase):
    def test_a_real_looking_token_is_caught_without_saying_it(self):
        token = "gh" + "p_" + REALISH + "abc"
        found = ship.secret_findings([("app.swift:3", f"let token = \"{token}\"")])
        self.assertEqual(found, [("app.swift:3", "a GitHub token")])
        self.assertNotIn(token, repr(found))

    def test_each_kind_is_caught(self):
        samples = ["AK" + "IA" + "Q7RT2MVX9LPW4NZ8", "sk-" + "ant-" + REALISH, "xo" + "xb-" + REALISH,
                   "AI" + "za" + REALISH[:33] + "Qq", "ASC_ISSUER_ID=" + "6f1c2d3e-4b5a-",
                   "-----BEGIN " + "PRIVATE KEY-----", "-----BEGIN EC " + "PRIVATE KEY-----"]
        for sample in samples:
            with self.subTest(sample=sample[:6]):
                self.assertTrue(ship.secret_findings([("f:1", sample)]))

    def test_made_up_values_in_tests_and_docs_pass(self):
        samples = ["sk-" + "ant-api03-AbCdEfGhIjKlMnOpQrSt", "gh" + "p_1234567890abcdefghijklmnopqrstuvwxyz",
                   "ASC_ISSUER_ID=" + "aaaaaaaa-bbbb-....", "\"sk-" + "live-fixture-token-value-here\""]
        for sample in samples:
            with self.subTest(sample=sample[:6]):
                self.assertEqual(ship.secret_findings([("f:1", sample)]), [])

    def test_key_and_settings_files_are_caught(self):
        paths = ["Tools/release/.env", "keys/AuthKey_ABC.p8", "a/profile.mobileprovision", "cert.p12",
                 "Companions/push-relay/.dev.vars", "docs/release.md", "Tools/release/.env.example"]
        self.assertEqual(ship.secret_file_findings(paths), paths[:5])

    def test_only_added_lines_are_read_from_a_patch(self):
        patch_text = ("\0" + "b" * 40 + "\n\ndiff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-gone\n+kept\n"
                      "diff --git a/y b/y\n--- a/y\n+++ /dev/null\n@@ -1 +0,0 @@\n-removed\n")
        self.assertEqual(list(ship.added_lines(patch_text)), [("bbbbbbb:x", "kept")])


class SchemaTests(unittest.TestCase):
    def test_the_same_schema_in_another_order_matches(self):
        self.assertEqual(ship.schema_problems(SCHEMA, EXPORTED), [])

    def test_the_real_schema_matches_itself_reordered(self):
        text = (ship.ROOT / ship.SCHEMA_FILE).read_text()
        reordered = "\n".join(reversed(text.split("\n\n")))
        self.assertTrue(ship.parse_schema(text))
        self.assertEqual(ship.schema_problems(text, "DEFINE SCHEMA\n\n" + reordered), [])

    def test_a_missing_field_index_type_or_grant_is_caught(self):
        cases = [EXPORTED.replace("        box             ENCRYPTED BYTES,\n", ""),
                 EXPORTED.replace("version         INT64 QUERYABLE", "version         INT64"),
                 EXPORTED.replace("NoteV1", "OtherV1"),
                 EXPORTED.replace("GRANT READ, WRITE", "GRANT READ"),
                 EXPORTED + EXPORTED.replace("NoteV1", "ExtraV1")]
        for production in cases:
            with self.subTest(production=production[-60:]):
                self.assertTrue(ship.schema_problems(SCHEMA, production))
        self.assertTrue(ship.schema_problems("DEFINE SCHEMA\n", EXPORTED))


class NotesTests(unittest.TestCase):
    GOOD = ("Nollie 1.3 makes mornings easier.\n\n**New in 1.3**\n- **Things.** Done.\n\n"
            "Nollie for Mac 1.3 ({build}).\nSHA-256 of Nollie.dmg: {dmg sha256} · of Nollie.zip: {zip sha256}.\n")

    def test_finished_notes_pass_and_are_filled_in_later(self):
        self.assertEqual(ship.notes_problems(self.GOOD, "1.3"), [])
        filled = ship.fill_notes(self.GOOD, "7", "d" * 64, "e" * 64)
        self.assertIn("1.3 (7)", filled)
        self.assertIn("d" * 64, filled)
        self.assertNotIn("{", filled)

    def test_unfinished_notes_are_caught(self):
        template = (ship.ROOT / "Docs" / "release-notes-template.md").read_text()
        cases = ["", template, self.GOOD.replace("easier", "easier — truly"),
                 self.GOOD.replace("Things.", "{Name of the thing}."), self.GOOD.replace("Nollie 1.3", "Nollie 1.2", 1)]
        for text in cases:
            with self.subTest(text=text[:30]):
                self.assertTrue(ship.notes_problems(text, "1.3"))


class SiteTests(unittest.TestCase):
    def test_a_served_page_matches_its_file_without_cloudflares_bot_check(self):
        page = b"<html><body><p>Hi</p>\n</body></html>"
        served = page.replace(b"</body>", b"<script>(function(){var u='/cdn-cgi/challenge-platform/scripts/jsd/main.js"
                                           b"?ray=a52b';})();</script></body>")
        self.assertEqual(ship.as_written(served), page)
        own = page.replace(b"</body>", b"<script src=\"site.js\"></script></body>")
        self.assertEqual(ship.as_written(own), own)


class KeyTests(unittest.TestCase):
    VALUES = {"ASC_APP_ID": "1", "ASC_KEY_ID": "PERSONAL01", "ASC_ISSUER_ID": "issuer-fixture",
              "ASC_KEY_PATH": "/fixture/key.p8", "ASC_KEY_KIND": "individual"}

    def test_coreys_own_key_passes(self):
        self.assertEqual(ship.release_env_problems(self.VALUES, exists=lambda path: True), [])

    def test_the_team_key_a_team_kind_or_a_missing_file_is_caught_without_values(self):
        cases = [dict(self.VALUES, ASC_KEY_ID=ship.NOTARY_KEY_ID), dict(self.VALUES, ASC_KEY_KIND=""),
                 {k: v for k, v in self.VALUES.items() if k != "ASC_ISSUER_ID"}]
        for values in cases:
            with self.subTest(values=sorted(values)):
                problems = ship.release_env_problems(values, exists=lambda path: True)
                self.assertTrue(problems)
                self.assertNotIn("issuer-fixture", " ".join(problems))
        self.assertTrue(ship.release_env_problems(self.VALUES, exists=lambda path: False))

    def test_the_notary_issuer_comes_from_the_environment_or_the_asc_config(self):
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder) / "config.json"
            config.write_text(json.dumps({"key_id": "OTHER", "issuer_id": "wrong",
                                          "keys": [{"key_id": ship.NOTARY_KEY_ID, "issuer_id": "right"}]}))
            self.assertEqual(ship.notary_issuer(config, environ={}), "right")
            self.assertEqual(ship.notary_issuer(config, environ={"NOLLIE_NOTARY_ISSUER_ID": "set"}), "set")
            self.assertIsNone(ship.notary_issuer(Path(folder) / "missing.json", environ={}))

    def test_only_a_valid_developer_id_of_coreys_passes(self):
        good = f'  1) ABC "{ship.DEVELOPER_ID}"\n  2) DEF "Apple Development: Created via API (X)" (CSSMERR_TP_CERT_REVOKED)'
        self.assertEqual(ship.identity_problems(good), [])
        self.assertEqual(ship.identity_warnings(good), [])
        self.assertTrue(ship.identity_problems('  1) ABC "Developer ID Application: Someone (X)"'))
        self.assertTrue(ship.identity_problems(f'  1) ABC "{ship.DEVELOPER_ID}" (CSSMERR_TP_CERT_REVOKED)'))
        self.assertTrue(ship.identity_warnings('  1) ABC "Apple Distribution: Created via API (X)"'))


class OutwardTests(unittest.TestCase):
    def test_sends_are_recognised(self):
        sends = [(["git", "push", "origin", "v1.3"], {}),
                 (["git", "-C", "x", "push"], {}),
                 (["gh", "release", "create", "v1.3", "--draft"], {}),
                 (["gh", "release", "edit", "v1.3", "--draft=false"], {}),
                 (["gh", "release", "upload", "v1.3", "x"], {}),
                 (["gh", "workflow", "run", "release.yml"], {}),
                 (["npx", "wrangler", "pages", "deploy", "public"], {}),
                 (["xcrun", "altool", "--upload-app"], {}),
                 (["xcrun", "notarytool", "submit", "x.dmg"], {}),
                 (["xcrun", "cktool", "import-schema"], {}),
                 (["lockf", "/tmp/l", "Tools/release/direct-release.sh", "out"], {}),
                 (["bash", "Tools/release/testflight.sh"], {}),
                 (["bash", "Tools/release/testflight.sh"], {"DRY_RUN": "1", "UPLOAD_PRODUCT": "x.ipa"}),
                 (["python3", "Tools/release/asc-listing.py", "screenshots"], {})]
        for argv, env in sends:
            with self.subTest(argv=argv):
                self.assertTrue(ship.outward(argv, env))

    def test_reads_and_local_work_are_not_sends(self):
        reads = [(["git", "ls-remote", "--tags", "origin"], {}),
                 (["git", "commit", "-m", "Nollie 1.3: version 1.3 (7)"], {}),
                 (["gh", "release", "view", "v1.1"], {}),
                 (["gh", "release", "download", "v1.3"], {}),
                 (["gh", "api", "user", "--jq", ".login"], {}),
                 (["xcrun", "cktool", "export-schema"], {}),
                 (["lockf", "/tmp/l", "Tools/release/direct-release.sh", "out"], {"DRY_RUN": "1"}),
                 (["bash", "Tools/release/testflight.sh"], {"DRY_RUN": "1", "OFFLINE": "1"}),
                 (["Tools/release/sparkle-appcast.sh", "out", "v1.3"], {"DRY_RUN": "1"}),
                 (["python3", "Tools/dev/verify.py"], {})]
        for argv, env in reads:
            with self.subTest(argv=argv):
                self.assertIsNone(ship.outward(argv, env))


class PlanTests(unittest.TestCase):
    def test_a_run_carries_on_after_the_last_step_done(self):
        self.assertEqual(ship.plan({"steps": {}}), list(ship.STEPS))
        state = {"steps": {"preflight": {}, "bump": {}, "check": {}}}
        self.assertEqual(ship.plan(state)[0], "mac")
        self.assertEqual(ship.plan(state, start="bump")[:2], ["bump", "check"])
        self.assertEqual(ship.plan(state, only="site"), ["site"])
        self.assertEqual(ship.plan({"steps": {step: {} for step in ship.STEPS}}), [])


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class RepositoryTests(unittest.TestCase):
    """A throwaway repository stands in for Nollie's."""

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name) / "repo"
        (self.root / "Nollie.xcodeproj").mkdir(parents=True)
        (self.root / "Nollie.xcodeproj" / "project.pbxproj").write_text(project())
        (self.root / ".gitignore").write_text("build/\n")
        git(self.root, "init", "--quiet", "-b", "release-1.3")
        git(self.root, "config", "user.name", ship.OWNER)
        git(self.root, "config", "user.email", ship.OWNER_EMAIL)
        git(self.root, "config", "commit.gpgsign", "false")
        git(self.root, "add", ".")
        git(self.root, "commit", "--quiet", "-m", "Start")

    def tearDown(self):
        self.folder.cleanup()

    def make(self, *argv):
        release = ship.Ship(ship.arguments(["1.3", *argv]), root=self.root)
        release.state.update(build="7", branch="release-1.3")
        return release

    def test_the_bump_is_one_commit_of_coreys_with_every_version_changed(self):
        release = self.make()
        release.step = "bump"
        with patch("sys.stdout", io.StringIO()):
            release.step_bump()
        text = (self.root / "Nollie.xcodeproj" / "project.pbxproj").read_text()
        self.assertEqual(ship.project_versions(text), (["1.3"] * 3, ["7"] * 3))
        self.assertEqual(git(self.root, "log", "-1", "--format=%an <%ae>|%s"),
                         f"{ship.OWNER} <{ship.OWNER_EMAIL}>|Nollie 1.3: version 1.3 (7)")
        self.assertEqual(release.state["commit"], git(self.root, "rev-parse", "HEAD"))
        with patch("sys.stdout", io.StringIO()):
            release.step_bump()
        self.assertEqual(git(self.root, "rev-list", "--count", "HEAD"), "2")

    def test_a_dry_run_bump_leaves_the_branch_alone(self):
        release = self.make("--dry-run")
        release.step = "bump"
        with patch("sys.stdout", io.StringIO()):
            release.step_bump()
        self.assertEqual(git(self.root, "log", "-1", "--format=%s"), "Start")
        self.assertIn("1.3", (release.work / "Nollie.xcodeproj" / "project.pbxproj").read_text())
        self.assertEqual(git(release.work, "log", "-1", "--format=%s"), "Nollie 1.3: version 1.3 (7)")
        self.assertEqual(git(self.root, "tag"), "")
        git(self.root, "worktree", "remove", "--force", str(release.work))

    def test_a_checkpoint_without_a_terminal_stops_and_with_approve_goes_on(self):
        release = self.make()
        release.step = "publish"
        with patch("sys.stdout", io.StringIO()), patch("sys.stdin", io.StringIO("")):
            with self.assertRaises(ship.Stop):
                release.checkpoint("publish", ["the release"], ["gh release edit"])
        approved = self.make("--approve", "publish")
        approved.step = "publish"
        with patch("sys.stdout", io.StringIO()):
            self.assertTrue(approved.checkpoint("publish", ["the release"], ["gh release edit"]))

    def test_a_send_without_a_yes_is_refused(self):
        release = self.make()
        release.step = "draft"
        with self.assertRaises(ship.ShipError):
            release.run(["git", "push", "origin", "v1.3"], cwd=self.root)
        dry = self.make("--dry-run")
        dry.step = "draft"
        dry.approved.add("draft")
        with self.assertRaises(ship.ShipError):
            dry.run(["git", "push", "origin", "v1.3"], cwd=self.root)

    def test_a_dry_run_of_the_outward_steps_sends_nothing_and_says_what_it_would(self):
        site = Path(self.folder.name) / "site"
        (site / "public").mkdir(parents=True)
        (site / "public" / "index.html").write_text(f'<a href="{ship.SITE_DOWNLOAD}">Download for Mac</a>')
        git(site, "init", "--quiet", "-b", "main")
        git(site, "config", "user.name", ship.OWNER)
        git(site, "config", "user.email", ship.OWNER_EMAIL)
        git(site, "add", ".")
        git(site, "commit", "--quiet", "-m", "Site")
        release = self.make("--dry-run")
        release.out.mkdir(parents=True)
        assets = release.out / "assets"
        assets.mkdir()
        for name in ("Nollie.dmg", "Nollie.zip"):
            (assets / name).write_bytes(b"made here " + name.encode())
            (assets / f"{name}.sha256").write_text(f"{ship.sha256(assets / name)}  {name}\n")
        size = (assets / "Nollie.zip").stat().st_size
        (assets / "appcast.xml").write_text(
            '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
            "<sparkle:version>7</sparkle:version><sparkle:shortVersionString>1.3</sparkle:shortVersionString>"
            f'<enclosure url="https://github.com/kozarski/nollie/releases/download/v1.3/Nollie.zip" length="{size}" '
            'sparkle:edSignature="c3RhbmQtaW4="/></item></channel></rss>')
        (release.out / "notes.md").write_text(NotesTests.GOOD)
        release.state.update(commit=git(self.root, "rev-parse", "HEAD"))
        ran = []
        real_run = release.run

        def record(argv, **options):
            ran.append([str(word) for word in argv])
            return real_run(argv, **options)
        with patch.object(release, "run", side_effect=record), patch.object(ship, "SITE", site), \
                patch("sys.stdout", io.StringIO()) as output:
            for step in ("draft", "appcast", "publish", "site"):
                release.step = step
                getattr(release, f"step_{step}")()
        self.assertFalse([argv for argv in ran if ship.outward(argv)])
        sent = (release.out / "would-send.txt").read_text()
        for expected in ("git push origin", "gh release create v1.3", "--draft", "Nollie.dmg", "sha256",
                         "gh release edit v1.3", "--draft=false", "wrangler pages deploy public"):
            self.assertIn(expected, sent)
        self.assertEqual(sent.count("-- Checkpoint"), 3)
        self.assertIn("nothing was sent", output.getvalue())
        self.assertEqual(git(self.root, "tag"), "")

    def test_a_stopped_run_says_how_to_carry_on(self):
        with patch.object(ship.Ship, "step_preflight", side_effect=ship.Stop("preflight")), \
                patch.object(ship, "ROOT", self.root), patch("sys.stdout", io.StringIO()) as output:
            code = ship.main(["1.3"])
        self.assertEqual(code, 2)
        self.assertIn("--from preflight --approve preflight", output.getvalue())

    def test_a_later_step_needs_the_preflight_first(self):
        with patch.object(ship, "ROOT", self.root), patch("sys.stderr", io.StringIO()) as errors:
            code = ship.main(["1.3", "--from", "mac"])
        self.assertEqual(code, 1)
        self.assertIn("preflight", errors.getvalue())


class ScriptTests(unittest.TestCase):
    def test_the_shell_scripts_parse(self):
        for name in ("ship.sh", "direct-release.sh", "sparkle-appcast.sh", "testflight.sh"):
            with self.subTest(name=name):
                subprocess.run(["bash", "-n", str(Path(__file__).with_name(name))], check=True)

    def test_testflight_refuses_offline_uploads_and_an_offline_run_without_a_number(self):
        script = Path(__file__).with_name("testflight.sh")
        base = {"PATH": os.environ["PATH"], "HOME": tempfile.gettempdir()}
        for env in ({"OFFLINE": "1"}, {"OFFLINE": "1", "DRY_RUN": "1"},
                    {"OFFLINE": "1", "DRY_RUN": "1", "BUILD_NUMBER": "7", "UPLOAD_PRODUCT": "x.ipa"},
                    {"UPLOAD_PRODUCT": "x.ipa", "DRY_RUN": "1", "BUILD_NUMBER": "7"},
                    {"UPLOAD_PRODUCT": "x.ipa"}):
            with self.subTest(env=env):
                result = subprocess.run(["bash", str(script)], env={**base, **env}, capture_output=True, text=True,
                                        timeout=60)
                self.assertEqual(result.returncode, 1)
                self.assertNotIn("Archiving", result.stdout)


if __name__ == "__main__":
    unittest.main()
