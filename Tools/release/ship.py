#!/usr/bin/env python3
"""Cuts a Nollie release with one command, a step at a time, and stops for Corey's yes before anything
leaves this Mac.

    Tools/release/ship.sh 1.3                start, or carry on from where the last run stopped
    Tools/release/ship.sh 1.3 --dry-run      every local step, on a throwaway copy; sends nothing
    Tools/release/ship.sh 1.3 --from mac     go again from a step
    Tools/release/ship.sh 1.3 --only check   one step on its own
    Tools/release/ship.sh 1.3 --status       what is done so far

The steps, in order (the ones marked "sends" stop at a checkpoint first):

    preflight  clean tree, Corey's own commits, no secrets, signers, CloudKit schema, notes, versions
    bump       sets the version and build number everywhere and commits it
    check      the full check, Tools/dev/verify.py
    mac        the Mac download: Developer ID, notarized, signed for Sparkle, checksums     sends to Apple
    ios        TestFlight for iPhone, iPad and Watch                                       uploads
    macstore   TestFlight for the Mac App Store                                            uploads
    draft      the GitHub release as a draft, with its files and notes                     pushes
    appcast    checks the draft's files and the appcast installed copies will read
    publish    publishes the draft, then checks the live appcast                           publishes
    site       deploys nollie.app, then checks it is served                                deploys

A checkpoint shows exactly what will be sent, and where, then asks for "yes". Without a terminal to ask
in, it stops; once Corey has said yes, run it again with --approve <step>. Progress is kept in
build/ship/<version>/state.json, so a run that stopped carries on where it left off.

--dry-run works on a throwaway checkout in build/ship/<version>-dry-run, so the branch is untouched. It
runs every local step (the bump commit, the full check, all three builds, the DMG, the zip, checksums
and an appcast signed with a stand-in key) and writes everything it would have sent to would-send.txt.
It only reads from elsewhere: the remote tags, the CloudKit production schema, the gh login, and the
published appcast that seeds the feed. It never contacts App Store Connect.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import check_appcast  # noqa: E402
import release_guard  # noqa: E402

OWNER = "Corey Kozarski"
OWNER_EMAIL = "coreykozarski@me.com"
GH_LOGIN = "kozarski"
REPO = "kozarski/nollie"
TEAM_ID = release_guard.TEAM_ID
DEVELOPER_ID = f"Developer ID Application: {OWNER} ({TEAM_ID})"
# The team key. It is for notarization only; uploads use Corey's own key from Tools/release/.env.
NOTARY_KEY_ID = "LA7B5435SG"
NOTARY_KEY_PATH = Path.home() / ".asc" / "keys" / f"AuthKey_{NOTARY_KEY_ID}.p8"
CONTAINER = release_guard.CLOUD_CONTAINER
SCHEMA_FILE = Path("Tools/cloudkit/nollie-alerts.ckdb")
PROJECT_FILE = Path("Nollie.xcodeproj/project.pbxproj")
RELEASE_ENV = Path("Tools/release/.env")
SITE = Path(os.environ.get("NOLLIE_SITE", Path.home() / "code" / "nollie-site"))
SITE_URL = "https://nollie.app/"
SITE_DOWNLOAD = f"https://github.com/{REPO}/releases/latest"
LATEST_APPCAST = f"https://github.com/{REPO}/releases/latest/download/appcast.xml"
LOCK = os.environ.get("NOLLIE_BUILD_LOCK", "/tmp/nollie-xcodebuild.lock")
ASSETS = ("Nollie.dmg", "Nollie.dmg.sha256", "Nollie.zip", "Nollie.zip.sha256", "appcast.xml")
STEPS = ("preflight", "bump", "check", "mac", "ios", "macstore", "draft", "appcast", "publish", "site")
CHECK_STAGES = ("build", "unit", "python", "ui")
# The notes may leave these for the mac step to fill in; anything else in braces is unfinished.
NOTES_FILLED_LATER = ("{build}", "{dmg sha256}", "{zip sha256}")
# This file and its tests name the patterns they look for, so the attribution scan skips them.
SCANNER_FILES = ("Tools/release/ship.py", "Tools/release/test_ship.py")


class ShipError(Exception):
    """Something is wrong; nothing more is done."""


class Stop(Exception):
    """A checkpoint is waiting for Corey's yes."""

    def __init__(self, step):
        super().__init__(step)
        self.step = step


# --- Versions --------------------------------------------------------------------------------------

def parse_version(text):
    if not isinstance(text, str) or not re.fullmatch(r"[0-9]+(\.[0-9]+){1,2}", text):
        raise ShipError(f"{text!r} is not a version like 1.3 or 1.3.1.")
    parts = [int(part) for part in text.split(".")]
    return tuple(parts + [0] * (3 - len(parts)))


def project_versions(text):
    """Every MARKETING_VERSION and CURRENT_PROJECT_VERSION in the project file, in order."""
    return (re.findall(r"\bMARKETING_VERSION = ([^;\n]+);", text),
            re.findall(r"\bCURRENT_PROJECT_VERSION = ([^;\n]+);", text))


def bump_project(text, version, build):
    marketing, builds = project_versions(text)
    if not marketing or len(marketing) != len(builds):
        raise ShipError("The project file's version settings are not in pairs.")
    text = re.sub(r"\bMARKETING_VERSION = [^;\n]+;", f"MARKETING_VERSION = {version};", text)
    text = re.sub(r"\bCURRENT_PROJECT_VERSION = [^;\n]+;", f"CURRENT_PROJECT_VERSION = {build};", text)
    after = project_versions(text)
    if after != ([version] * len(marketing), [str(build)] * len(builds)):
        raise ShipError("The version did not change in every place.")
    return text


def version_problems(project_text, version, build, last_tag=None, tag_taken=False):
    """last_tag is (version, build) of the newest release tag, or None."""
    marketing, builds = project_versions(project_text)
    found = []
    if not marketing:
        return ["The project file has no MARKETING_VERSION."]
    if len(set(marketing)) != 1:
        found.append(f"The project has more than one version: {', '.join(sorted(set(marketing)))}.")
    if len(set(builds)) != 1:
        found.append(f"The project has more than one build number: {', '.join(sorted(set(builds)))}.")
    if len(marketing) != len(builds):
        found.append("The project has a different count of versions and build numbers.")
    if found:
        return found
    current, current_build = marketing[0], builds[0]
    target = parse_version(version)
    if not str(build).isdigit():
        return [f"The build number {build} is not a whole number."]
    if parse_version(current) == target:
        if current_build != str(build):
            found.append(f"The project is already {current} but with build {current_build}, not {build}.")
    elif parse_version(current) > target:
        found.append(f"The project is at {current}, which is newer than {version}.")
    elif not current_build.isdigit() or int(build) <= int(current_build):
        found.append(f"The build number {build} has to be higher than the project's {current_build}.")
    if last_tag:
        tag_version, tag_build = last_tag
        if parse_version(tag_version) >= target:
            found.append(f"{version} is not newer than the last release, {tag_version}.")
        if tag_build.isdigit() and int(build) <= int(tag_build):
            found.append(f"Build {build} is not higher than the last release's build {tag_build}.")
    if tag_taken:
        found.append(f"The tag v{version} already exists.")
    return found


def info_plist_problems(project_text, read):
    """Each target's Info.plist takes its version from the build settings, never a number of its own."""
    found = []
    for path in sorted(set(re.findall(r"\bINFOPLIST_FILE = \"?([^\";\n]+)\"?;", project_text))):
        try:
            info = plistlib.loads(read(path))
        except Exception:
            found.append(f"{path} cannot be read.")
            continue
        for key, setting in (("CFBundleShortVersionString", "$(MARKETING_VERSION)"),
                             ("CFBundleVersion", "$(CURRENT_PROJECT_VERSION)")):
            if key in info and info[key] != setting:
                found.append(f"{path} sets {key} itself instead of using {setting}.")
    return found


# --- Commits, attribution and secrets ---------------------------------------------------------------

_TOOL = (r"(?:claude(?: code)?|chatgpt|copilot|cursor|codex|gemini|an? (?:ai|llm)\b|(?:an? )?ai "
         r"(?:assistant|agent|tool|model))")
ATTRIBUTION = [
    ("has an attribution line", re.compile(r"^\s*(?:co-authored-by|assisted-by|generated-by|made-with)\s*:",
                                           re.I | re.M)),
    ("says a tool made it", re.compile(r"\b(?:generated|written|made|drafted|created|built|authored)\s+"
                                       r"(?:with|by|using)\s+(?:the help of\s+)?\[?" + _TOOL, re.I)),
    ("names a coding assistant", re.compile(r"\b(?:claude code|github copilot|codex cli|gemini cli|cursor ai)\b",
                                            re.I)),
    ("links to an assistant session", re.compile(r"(?:claude\.ai/(?:code|chat|share)|chatgpt\.com/(?:share|c)/"
                                                 r"|chat\.openai\.com/|copilot\.microsoft\.com|gemini\.google\.com/"
                                                 r"(?:share|app))", re.I)),
    ("carries an assistant's address", re.compile(r"noreply@(?:anthropic|openai)\.com", re.I)),
    ("has a robot footer", re.compile("\U0001F916")),
    ("says AI wrote it", re.compile(r"\bAI[- ](?:generated|written|assisted)\b", re.I)),
]


def attribution_problems(text):
    return [kind for kind, pattern in ATTRIBUTION if pattern.search(text or "")]


def commit_problems(commits):
    """commits: dicts with sha, author, email, committer, committer_email, body."""
    found = []
    for commit in commits:
        short = commit["sha"][:7]
        for role, name, email in (("author", commit["author"], commit["email"]),
                                  ("committer", commit["committer"], commit["committer_email"])):
            if name != OWNER or email.lower() != OWNER_EMAIL:
                found.append(f"{short}'s {role} is {name} <{email}>, not {OWNER}.")
        for kind in attribution_problems(commit["body"]):
            found.append(f"{short}'s message {kind}.")
    return found


SECRETS = [
    ("a private key", re.compile(r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----")),
    ("a GitHub token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})")),
    ("an AWS key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("a Slack token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}")),
    ("a model provider key", re.compile(r"\bsk-(?:ant-|proj-|live-)?[A-Za-z0-9_-]{24,}")),
    ("a Google key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
    ("a Cloudflare token", re.compile(r"\b(?:CLOUDFLARE_API_TOKEN|CF_API_TOKEN)\s*[=:]\s*[\"']?[A-Za-z0-9_-]{30,}")),
    ("an App Store Connect issuer", re.compile(r"\bASC_ISSUER_ID\s*=\s*[\"']?[0-9a-f]{8}-[0-9a-f]{4}-", re.I)),
]
SECRET_FILES = re.compile(r"(?:\.p8|\.p12|\.pfx|\.mobileprovision|\.provisionprofile|\.keychain(?:-db)?)$"
                          r"|(?:^|/)(?:\.env|\.dev\.vars|AuthKey_[^/]*)$")
# Made-up values in tests read like this; a real key does not.
STAND_IN_HINTS = ("abcdef", "123456", "fixture", "example", "xxxxxx", "000000", "redacted", "placeholder",
                  "dummy", "fake", "not-a-real", "notreal", "test-only")


def is_stand_in(value):
    lower = value.lower()
    return any(hint in lower for hint in STAND_IN_HINTS) or bool(re.search(r"(.)\1{5}", lower))


def secret_findings(lines):
    """lines: (where, text) pairs. Returns (where, kind) for each secret, never the secret itself."""
    found = []
    for where, text in lines:
        for kind, pattern in SECRETS:
            for match in pattern.finditer(text):
                if kind == "a private key" or not is_stand_in(match.group(0)):
                    found.append((where, kind))
                    break
    return found


def secret_file_findings(paths):
    return [path for path in paths if SECRET_FILES.search(path) and not path.endswith(".example")]


def added_lines(patch):
    """(commit:path, text) for each line a `git log -p --format=%x00%H` patch adds."""
    commit = path = ""
    for line in patch.splitlines():
        if line.startswith("\0"):
            commit = line[1:8]
        elif line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else ""
        elif line.startswith("+") and path:
            yield f"{commit}:{path}", line[1:]


# --- CloudKit schema ---------------------------------------------------------------------------------

def parse_schema(text):
    """{record type: (fields, grants)}, ignoring order, spacing and quotes."""
    types = {}
    for name, body in re.findall(r"RECORD\s+TYPE\s+(\S+)\s*\((.*?)\)\s*;", text, re.S):
        fields, grants = set(), set()
        for line in body.splitlines():
            line = " ".join(line.strip().rstrip(",").split())
            if not line:
                continue
            grant = re.fullmatch(r"GRANT\s+(.+?)\s+TO\s+\"?([^\"]+)\"?", line, re.I)
            if grant:
                for permission in grant.group(1).split(","):
                    grants.add((permission.strip().upper(), grant.group(2)))
            else:
                fields.add(line.replace('"', ""))
        types[name.strip('"')] = (frozenset(fields), frozenset(grants))
    return types


def schema_problems(local_text, production_text):
    local, production = parse_schema(local_text), parse_schema(production_text)
    if not local:
        return ["The schema file has no record types."]
    found = []
    for name in sorted(set(local) - set(production)):
        found.append(f"{name} is in the schema file but not in production.")
    for name in sorted(set(production) - set(local)):
        found.append(f"{name} is in production but not in the schema file.")
    for name in sorted(set(local) & set(production)):
        (fields, grants), (live_fields, live_grants) = local[name], production[name]
        for field in sorted(fields - live_fields):
            found.append(f"{name}: production lacks \"{field}\".")
        for field in sorted(live_fields - fields):
            found.append(f"{name}: production has \"{field}\", which the file does not.")
        if grants != live_grants:
            found.append(f"{name}: the permissions differ.")
    return found


# --- Notes ---------------------------------------------------------------------------------------------

def notes_problems(text, version):
    if not text or not text.strip():
        return ["The notes are empty."]
    found = []
    if "<!--" in text:
        found.append("The notes still have the template's comment.")
    unfinished = sorted(set(re.findall(r"\{[^{}\n]*\}", text)) - set(NOTES_FILLED_LATER))
    if unfinished:
        found.append("The notes still have blanks to fill: " + ", ".join(unfinished[:5]) + ".")
    if "—" in text:
        found.append("The notes have an em-dash.")
    if not text.lstrip().startswith(f"Nollie {version}"):
        found.append(f"The notes should start with \"Nollie {version}\".")
    return found


def fill_notes(text, build, dmg_sha, zip_sha):
    return (text.replace("{build}", str(build)).replace("{dmg sha256}", dmg_sha)
            .replace("{zip sha256}", zip_sha))


# --- Keys and signers ----------------------------------------------------------------------------------

def release_env_problems(values, exists=os.path.exists):
    """Tools/release/.env, for the uploads. Never says a value."""
    found = []
    for name in ("ASC_APP_ID", "ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH"):
        if not values.get(name):
            found.append(f"{name} is not set.")
    if values.get("ASC_KEY_KIND") != "individual":
        found.append("ASC_KEY_KIND is not individual, so uploads would show \"API user\" instead of Corey.")
    if values.get("ASC_KEY_ID") == NOTARY_KEY_ID:
        found.append(f"ASC_KEY_ID is the team key {NOTARY_KEY_ID}, which is for notarization only.")
    if values.get("ASC_KEY_PATH") and not exists(values["ASC_KEY_PATH"]):
        found.append("ASC_KEY_PATH names a file that is not there.")
    return found


def notary_issuer(config_path=Path.home() / ".asc" / "config.json", environ=os.environ):
    """The issuer that goes with the team key: NOLLIE_NOTARY_ISSUER_ID, else the asc tool's config."""
    if environ.get("NOLLIE_NOTARY_ISSUER_ID"):
        return environ["NOLLIE_NOTARY_ISSUER_ID"]
    try:
        config = json.loads(Path(config_path).read_text())
    except (OSError, ValueError):
        return None
    for entry in [config] + list(config.get("keys") or []):
        if isinstance(entry, dict) and entry.get("key_id") == NOTARY_KEY_ID and entry.get("issuer_id"):
            return entry["issuer_id"]
    return None


def identity_problems(find_identity_output):
    """From `security find-identity -v -p codesigning`."""
    lines = find_identity_output.splitlines()
    good = [line for line in lines if f'"{DEVELOPER_ID}"' in line and "CSSMERR" not in line]
    return [] if good else [f"There is no valid \"{DEVELOPER_ID}\" certificate in the keychain."]


def identity_warnings(find_identity_output):
    return ["A \"Created via API\" certificate is valid in the keychain. The release guard refuses anything it signs."
            for line in find_identity_output.splitlines() if "Created via API" in line and "CSSMERR" not in line][:1]


# --- What may leave this Mac ---------------------------------------------------------------------------

def outward(argv, env=None):
    """Why this command sends something out, or None. Reads (downloads, views, exports) are not sends."""
    env = env or {}
    words = [Path(str(word)).name if index == 0 else str(word) for index, word in enumerate(argv)]
    text = " ".join(words)
    script = next((Path(str(word)).name for word in argv if str(word).endswith((".sh", ".py"))), "")
    if script == "testflight.sh" and (env.get("UPLOAD_PRODUCT") or not env.get("DRY_RUN")):
        return "uploads to App Store Connect"
    if script == "direct-release.sh" and not env.get("DRY_RUN"):
        return "sends the Mac app and DMG to Apple's notary service"
    if script == "asc-listing.py":
        return "changes the App Store listing"
    checks = [
        (r"^git (?:.* )?push\b", "pushes to GitHub"),
        (r"^gh (?:.* )?release (?:create|edit|upload|delete|delete-asset)\b", "changes a GitHub release"),
        (r"^gh (?:.* )?workflow run\b", "starts a GitHub workflow"),
        (r"^gh (?:.* )?api\b.*(?:-X|--method)\s*(?:POST|PATCH|PUT|DELETE)", "changes something on GitHub"),
        (r"\bwrangler (?:.* )?deploy\b", "deploys the site"),
        (r"\baltool\b", "uploads to App Store Connect"),
        (r"\bnotarytool submit\b", "sends to Apple's notary service"),
        (r"\bcktool (?:import-schema|reset-schema|create-record|delete-record|delete-records)\b",
         "changes CloudKit"),
        (r"\bxcodebuild\b.*\bupload\b", "uploads through Xcode"),
    ]
    for pattern, reason in checks:
        if re.search(pattern, text):
            return reason
    return None


# --- Small helpers --------------------------------------------------------------------------------------

def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def size_text(size):
    for unit in ("bytes", "KB", "MB", "GB"):
        if size < 1000 or unit == "GB":
            return f"{size} {unit}" if unit == "bytes" else f"{size:.1f} {unit}"
        size /= 1000


def describe(path):
    path = Path(path)
    return f"{path.name}, {size_text(path.stat().st_size)}, sha256 {sha256(path)}"


def now():
    return datetime.datetime.now().isoformat(timespec="seconds")


def fetch(url, timeout=30):
    request = urllib.request.Request(url, headers={"Cache-Control": "no-cache", "User-Agent": "nollie-ship"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


# --- The release -----------------------------------------------------------------------------------------

class Ship:
    def __init__(self, args, root=None):
        self.args = args
        # Read when made, not when defined, so a test that points ROOT elsewhere never reaches a real run's state.
        self.root = Path(root or ROOT)
        self.version = args.version
        parse_version(self.version)
        self.tag = f"v{self.version}"
        self.dry = bool(args.dry_run)
        self.out = self.root / "build" / "ship" / (self.version + ("-dry-run" if self.dry else ""))
        self.state_path = self.out / "state.json"
        self.state = json.loads(self.state_path.read_text()) if self.state_path.exists() else {}
        if self.state and self.state.get("dry", False) != self.dry:
            raise ShipError(f"{self.state_path} belongs to another kind of run.")
        self.state.setdefault("version", self.version)
        self.state.setdefault("dry", self.dry)
        self.state.setdefault("steps", {})
        self.state.setdefault("products", {})
        self.approved = set()
        self.step = None

    # State
    def save(self):
        self.out.mkdir(parents=True, exist_ok=True)
        self.state_path.write_text(json.dumps(self.state, indent=2) + "\n")

    def done(self, step, **details):
        self.state["steps"][step] = {"done": now(), **details}
        self.save()

    @property
    def work(self):
        """Where builds happen: the repository, or the throwaway checkout in a dry run."""
        return Path(self.state["checkout"]) if self.dry and self.state.get("checkout") else self.root

    @property
    def build(self):
        return self.state.get("build")

    @property
    def notes_path(self):
        return Path(self.state.get("notes") or self.args.notes or self.root / "Docs" / "releases" / f"{self.version}.md")

    # Commands
    def run(self, argv, cwd=None, env=None, capture=False, check=True, timeout=None):
        argv = [str(word) for word in argv]
        reason = outward(argv, env)
        if reason and (self.dry or self.step not in self.approved):
            raise ShipError(f"Refused: `{shlex.join(argv)}` {reason}, and {self.step} has no yes for that.")
        try:
            result = subprocess.run(argv, cwd=cwd or self.work, env=env, text=True, timeout=timeout,
                                    capture_output=capture)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ShipError(f"{Path(argv[0]).name} could not run ({error.__class__.__name__}).") from None
        if check and result.returncode != 0:
            raise ShipError(f"`{shlex.join(argv[:4])}{' ...' if len(argv) > 4 else ''}` failed.")
        return result

    def git(self, *args, cwd=None, check=True):
        return self.run(["git", *args], cwd=cwd or self.root, capture=True, check=check).stdout.strip("\n")

    def locked(self, argv):
        return ["lockf", LOCK, *argv]

    def clean_env(self, **extra):
        """The caller's environment without any App Store Connect key, so each tool gets only its own."""
        env = {key: value for key, value in os.environ.items()
               if not key.startswith("ASC_") and key not in ("NOTARY_PROFILE", "DRY_RUN", "OFFLINE",
                                                              "UPLOAD_PRODUCT", "BUILD_NUMBER")}
        env.update({key: str(value) for key, value in extra.items()})
        return env

    # Checkpoints
    def checkpoint(self, title, sends, commands):
        """Shows what is about to leave this Mac. True to go ahead; in a dry run, records it and says False."""
        lines = [f"-- Checkpoint: {title}", "Sends:"] + [f"  {line}" for line in sends]
        lines += ["Runs:"] + [f"  {line}" for line in commands]
        text = "\n".join(lines)
        print("\n" + text, flush=True)
        if self.dry:
            with (self.out / "would-send.txt").open("a") as stream:
                stream.write(text + "\n\n")
            print("Dry run: nothing was sent.")
            return False
        if self.step in (self.args.approve or []):
            print(f"Corey said yes (--approve {self.step}).")
        elif sys.stdin.isatty():
            if input("Send it? Type yes to go ahead: ").strip().lower() != "yes":
                raise Stop(self.step)
        else:
            raise Stop(self.step)
        self.approved.add(self.step)
        return True

    # Shared lookups
    def last_tag(self, cwd=None):
        """The newest release tag behind HEAD, other than this release's own."""
        return self.git("describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", "--exclude", self.tag, "HEAD",
                        cwd=cwd, check=False) or None

    def commits(self, revisions, cwd=None):
        raw = self.git("log", "--format=%H%x1f%an%x1f%ae%x1f%cn%x1f%ce%x1f%B%x1e", *revisions, cwd=cwd)
        commits = []
        for record in raw.split("\x1e"):
            record = record.strip("\n")
            if record:
                sha, author, email, committer, committer_email, body = record.split("\x1f", 5)
                commits.append(dict(sha=sha, author=author, email=email, committer=committer,
                                    committer_email=committer_email, body=body))
        return commits

    # --- Steps ---------------------------------------------------------------------------------------------

    def step_preflight(self):
        results = []

        def report(name, problems, detail="", warnings=()):
            results.append((name, list(problems)))
            print(f"  {'ok' if not problems else 'no'}  {name}{(': ' + detail) if detail and not problems else ''}")
            for line in problems:
                print(f"        {line}")
            for line in warnings:
                print(f"        note: {line}")

        print("\n== Preflight")
        status = self.git("status", "--porcelain")
        branch = self.git("symbolic-ref", "--quiet", "--short", "HEAD", check=False)
        report("Clean tree", [f"Uncommitted: {line}" for line in status.splitlines()[:5]] if status else [],
               f"on {branch or 'a detached HEAD'} at {self.git('rev-parse', '--short', 'HEAD')}")

        last = self.last_tag()
        revisions = [f"{last}..HEAD"] if last else ["HEAD"]
        commits = self.commits(revisions)
        name, email = self.git("config", "user.name", check=False), self.git("config", "user.email", check=False)
        problems = commit_problems(commits)
        if name != OWNER or email.lower() != OWNER_EMAIL:
            problems.insert(0, f"This repository commits as {name} <{email}>, not {OWNER}.")
        report("Commits are Corey's own", problems, f"{len(commits)} since {last or 'the start'}, no attribution")

        tracked = self.git("ls-files").splitlines()
        grep = self.run(["git", "grep", "-I", "-n", "-z", "-E", "-e",
                         "PRIVATE KEY|gh[pousr]_|github_pat_|AKIA|xox[abprs]-|sk-|AIza|API_TOKEN|ASC_ISSUER_ID"],
                        cwd=self.root, capture=True, check=False).stdout
        tree_lines = []
        for record in grep.splitlines():
            parts = record.split("\0")
            if len(parts) >= 3:
                tree_lines.append((f"{parts[0]}:{parts[1]}", parts[2]))
        patch = self.git("log", "-p", "--no-color", "--format=%x00%H", *revisions)
        history = list(added_lines(patch))
        findings = secret_findings(tree_lines) + secret_findings(history)
        problems = [f"{where} has {kind}." for where, kind in findings[:10]]
        problems += [f"{path} is a key or settings file, and it is tracked." for path in secret_file_findings(tracked)]
        problems += [f"{where} {kind}." for where, text in history if not where.split(":", 1)[1] in SCANNER_FILES
                     for kind in attribution_problems(text)][:10]
        report("No secrets or attribution in the tree or since the last release", problems,
               f"{len(tracked)} files and {len(history)} added lines")

        identities = self.run(["security", "find-identity", "-v", "-p", "codesigning"], capture=True,
                              check=False).stdout
        problems = identity_problems(identities)
        login = self.run(["gh", "api", "user", "--jq", ".login"], capture=True, check=False, timeout=60).stdout.strip()
        if login != GH_LOGIN:
            problems.append(f"gh is signed in as {login or 'nobody'}, not {GH_LOGIN}.")
        report("Signers", problems, f"{DEVELOPER_ID}; GitHub as {GH_LOGIN}", identity_warnings(identities))

        with tempfile.TemporaryDirectory(prefix="nollie-schema-") as folder:
            exported = Path(folder) / "production.ckdb"
            result = self.run(["xcrun", "cktool", "export-schema", "--team-id", TEAM_ID, "--container-id", CONTAINER,
                               "--environment", "production", "--output-file", exported],
                              capture=True, check=False, timeout=180)
            if result.returncode != 0 or not exported.exists():
                problems = ["Could not read the production schema. Save a CloudKit management token with "
                            "`xcrun cktool save-token`, then try again."]
            else:
                problems = schema_problems((self.root / SCHEMA_FILE).read_text(), exported.read_text())
        report("CloudKit production schema matches the file", problems, str(SCHEMA_FILE))

        notes = self.notes_path
        problems = notes_problems(notes.read_text(), self.version) if notes.exists() else \
            [f"There are no notes at {notes}. Copy Docs/release-notes-template.md there and fill it in."]
        report("Release notes", problems, str(notes))
        self.state["notes"] = str(notes.resolve()) if notes.exists() else None

        project = (self.root / PROJECT_FILE).read_text()
        marketing, builds = project_versions(project)
        current_build = builds[0] if builds else "0"
        already = bool(marketing) and marketing[0] == self.version
        build = self.args.build or (current_build if already else str(int(current_build) + 1 if current_build.isdigit() else 1))
        last_release = None
        if last:
            tagged = self.git("show", f"{last}:{PROJECT_FILE}", check=False)
            tag_marketing, tag_builds = project_versions(tagged)
            if tag_marketing and tag_builds:
                last_release = (tag_marketing[0], tag_builds[0])
        local_tag = self.git("tag", "--list", self.tag)
        remote_tag = self.run(["git", "ls-remote", "--tags", "origin", f"refs/tags/{self.tag}"], cwd=self.root,
                              capture=True, check=False, timeout=60).stdout.strip()
        problems = version_problems(project, self.version, build, last_release, bool(local_tag or remote_tag))
        problems += info_plist_problems(project, lambda path: (self.root / path).read_bytes())
        report("Versions", problems, f"{marketing[0] if marketing else '?'} ({current_build}) now, "
               f"{self.version} ({build}) next; last release {last or 'none'}"
               + ("; already bumped" if already else ""))
        self.state["build"] = str(build)
        self.state["branch"] = branch

        env_file = self.root / RELEASE_ENV
        values = release_guard.release_environment(env_file, environ={}) if env_file.exists() else {}
        problems = release_env_problems(values) if env_file.exists() else [f"There is no {RELEASE_ENV}."]
        if not NOTARY_KEY_PATH.exists():
            problems.append(f"The notarization key is not at {NOTARY_KEY_PATH}.")
        if not notary_issuer():
            problems.append(f"No issuer ID for {NOTARY_KEY_ID}: set NOLLIE_NOTARY_ISSUER_ID.")
        warnings = []
        if self.dry and not env_file.exists():
            # A dry run never uploads, so it can go on without the upload key; a real run cannot.
            warnings.append(f"A real run needs {RELEASE_ENV}; this dry run does not use it.")
            problems = [line for line in problems if RELEASE_ENV.name not in line]
        report("Keys: Corey's own for uploads, the team key only for notarization", problems,
               f"uploads as {OWNER}, notarizes with {NOTARY_KEY_ID}", warnings)

        report("Site", self.site_problems(), f"{SITE}")

        failed = [name for name, problems in results if problems]
        (self.out / "preflight.txt").write_text(
            "".join(f"{'ok' if not p else 'no'}  {n}\n" + "".join(f"    {line}\n" for line in p) for n, p in results))
        self.state["preflight_failed"] = failed
        if failed and not self.dry:
            self.save()
            raise ShipError("Preflight found problems (above). Nothing was changed.")
        if failed:
            print(f"\nA real run would stop here: {', '.join(failed)}. The dry run goes on so you can see the rest.")
        self.done("preflight", build=self.build)

    def step_bump(self):
        print(f"\n== Version {self.version} ({self.build})")
        if self.dry:
            checkout = self.out / "checkout"
            if not checkout.exists():
                self.git("worktree", "add", "--detach", str(checkout), "HEAD")
            self.state["checkout"] = str(checkout)
            self.save()
            print(f"Dry run: the bump is committed in a throwaway checkout, {checkout}.")
        work = self.work
        if self.git("status", "--porcelain", cwd=work):
            raise ShipError(f"{work} has uncommitted changes.")
        project_path = work / PROJECT_FILE
        text = project_path.read_text()
        if project_versions(text) == ([self.version] * len(project_versions(text)[0]),
                                      [self.build] * len(project_versions(text)[1])):
            print("Already at this version.")
        else:
            project_path.write_text(bump_project(text, self.version, self.build))
            message = f"Nollie {self.version}: version {self.version} ({self.build})"
            self.git("add", str(PROJECT_FILE), cwd=work)
            self.git("commit", "--quiet", "-m", message, cwd=work)
            print(f"Committed: {message}")
        commit = self.git("rev-parse", "HEAD", cwd=work)
        problems = commit_problems(self.commits(["-1", commit], cwd=work))
        if problems:
            raise ShipError(" ".join(problems))
        self.state["commit"] = commit
        self.done("bump", commit=commit)

    def step_check(self):
        stages = self.args.check_stages or list(CHECK_STAGES)
        print(f"\n== Full check: {' '.join(stages)}")
        self.run(self.locked([sys.executable, "Tools/dev/verify.py", *stages]), env=self.clean_env())
        self.done("check", stages=stages)

    def notary_env(self):
        issuer = notary_issuer()
        if not issuer or not NOTARY_KEY_PATH.exists():
            if self.dry:
                return self.clean_env(DRY_RUN=1)
            raise ShipError(f"The notarization key {NOTARY_KEY_ID} or its issuer is missing.")
        env = self.clean_env(ASC_KEY_ID=NOTARY_KEY_ID, ASC_KEY_PATH=NOTARY_KEY_PATH, ASC_ISSUER_ID=issuer)
        if self.dry:
            env["DRY_RUN"] = "1"
        return env

    def step_mac(self):
        mac = self.out / "mac"
        name = f"Nollie-{self.version}-{self.build}"
        sends = [f"Nollie.app {self.version} ({self.build}) for Mac, to Apple's notary service through the Apple "
                 "Account signed in to Xcode",
                 f"{name}.dmg, to Apple's notary service with notarytool and the team key {NOTARY_KEY_ID} "
                 "(notarization only), then stapled"]
        command = [f"lockf {LOCK} Tools/release/direct-release.sh {mac}",
                   f"Tools/release/sparkle-appcast.sh {mac} {self.tag}   (again, once the checksums are in the notes)"]
        if not self.dry:
            self.checkpoint("notarize the Mac download", sends, command)
        print("\n== Mac download")
        self.run(self.locked(["Tools/release/direct-release.sh", mac]), env=self.notary_env())
        dmg, archive = mac / f"{name}.dmg", mac / f"{name}.zip"
        if not dmg.exists() or not archive.exists():
            raise ShipError(f"{name}.dmg and {name}.zip are not both in {mac}. The app's version is not {self.version} "
                            f"({self.build}).")
        notes = fill_notes(self.notes_path.read_text(), self.build, sha256(dmg), sha256(archive))
        (self.out / "notes.md").write_text(notes)
        (mac / "notes.md").write_text(notes)
        print("\n== The appcast again, now the notes have their checksums")
        appcast_env = self.clean_env(**({"DRY_RUN": 1} if self.dry else {}))
        self.run(["Tools/release/sparkle-appcast.sh", mac, self.tag], env=appcast_env)
        assets = self.out / "assets"
        shutil.rmtree(assets, ignore_errors=True)
        assets.mkdir(parents=True)
        for source, target in ((dmg, "Nollie.dmg"), (archive, "Nollie.zip")):
            shutil.copy2(source, assets / target)
            (assets / f"{target}.sha256").write_text(f"{sha256(assets / target)}  {target}\n")
        shutil.copy2(mac / "appcast.xml", assets / "appcast.xml")
        self.require_fit_appcast(assets / "appcast.xml", (assets / "Nollie.zip").stat().st_size)
        if self.dry:
            self.checkpoint("notarize the Mac download (in a real run this comes before the build)",
                            [f"Nollie.app, as in {describe(archive)}, to the notary service through Xcode",
                             f"{describe(dmg)}, to notarytool with the team key {NOTARY_KEY_ID}"],
                            command)
        self.done("mac", assets=str(assets))

    def require_fit_appcast(self, path, zip_size):
        problems = check_appcast.problems(Path(path).read_text(), self.tag, zip_size)
        if problems:
            raise ShipError("The appcast is not fit: " + " ".join(problems))
        print(f"appcast.xml is fit for {self.tag}.")

    def step_store(self, step, platform):
        folder = self.out / step
        prefix, kind = ("Nollie", "ipa") if platform == "ios" else ("Nollie-mac", "pkg")
        product = Path(self.state["products"].get(step) or folder / "missing")
        what = "iPhone, iPad and Watch" if platform == "ios" else "Mac App Store"
        print(f"\n== TestFlight, {what}")
        if not product.exists():
            shutil.rmtree(folder, ignore_errors=True)
            env = self.clean_env(PLATFORM=platform, BUILD_NUMBER=self.build, ARCHIVE_DIR=folder,
                                 MARKETING_VERSION=self.version, DRY_RUN=1, **({"OFFLINE": 1} if self.dry else {}))
            self.run(self.locked(["bash", "Tools/release/testflight.sh"]), env=env)
            found = sorted((folder / f"export-{prefix}-{self.build}").glob(f"*.{kind}"))
            if len(found) != 1:
                raise ShipError(f"Expected one .{kind} in {folder}.")
            product = found[0]
            self.state["products"][step] = str(product)
            self.save()
        else:
            print(f"Built earlier: {product}")
        sends = [f"{describe(product)}, to App Store Connect as {what} build {self.build} of {self.version}, "
                 "with Corey's own key so it shows his name"]
        if platform == "ios":
            sends.append(f"then the App Store listing: build {self.build} attached to version {self.version}, and the "
                         "screenshots in Tools/release/screenshots")
        command = [f"env PLATFORM={platform} BUILD_NUMBER={self.build} UPLOAD_PRODUCT={product} "
                   "bash Tools/release/testflight.sh"]
        if self.checkpoint(f"upload to TestFlight ({what})", sends, command):
            env = self.clean_env(PLATFORM=platform, BUILD_NUMBER=self.build, UPLOAD_PRODUCT=product,
                                 MARKETING_VERSION=self.version)
            self.run(["bash", "Tools/release/testflight.sh"], env=env)
        self.done(step, product=str(product))

    def step_ios(self):
        self.step_store("ios", "ios")

    def step_macstore(self):
        self.step_store("macstore", "macos")

    def assets(self):
        folder = self.out / "assets"
        paths = [folder / name for name in ASSETS]
        missing = [path.name for path in paths if not path.exists()]
        if missing:
            raise ShipError(f"{', '.join(missing)} missing from {folder}. Run the mac step first.")
        return paths

    def step_draft(self):
        commit, branch = self.state.get("commit"), self.state.get("branch")
        if not commit or not branch:
            raise ShipError("No release commit or branch yet. Run the bump step on a branch first.")
        assets, notes = self.assets(), self.out / "notes.md"
        print(f"\n== GitHub release {self.tag}, as a draft")
        if self.dry:
            print(f"Dry run: no tag is made. A real run tags {commit[:7]} as {self.tag} here first.")
        else:
            existing = self.git("rev-parse", "--verify", "--quiet", f"refs/tags/{self.tag}^{{commit}}", check=False)
            if existing and existing != commit:
                raise ShipError(f"{self.tag} already points at {existing[:7]}, not the release commit {commit[:7]}.")
            if not existing:
                self.git("tag", self.tag, commit)
        unpushed = self.git("rev-list", commit, "--not", "--remotes=origin", cwd=self.work).split()
        problems = commit_problems(self.commits(["--no-walk=unsorted", *unpushed], cwd=self.work)) if unpushed else []
        if problems:
            raise ShipError("Not pushing: " + " ".join(problems))
        print(f"{len(unpushed)} commits would go to GitHub, every one Corey's with no attribution.")
        title = f"Nollie {self.version}"
        create = ["gh", "release", "create", self.tag, "--repo", REPO, "--draft", "--target", commit,
                  "--title", title, "--notes-file", notes, *assets]
        first_line = notes.read_text().strip().splitlines()[0]
        sends = [f"{len(unpushed)} commits to github.com/{REPO}, branch {branch}, ending with {commit[:7]}",
                 f"a draft release {self.tag}, \"{title}\", only Corey can see until it is published. Notes: "
                 f"\"{first_line[:90]}{'...' if len(first_line) > 90 else ''}\"",
                 *[f"  {describe(path)}" for path in assets],
                 f"the tag {self.tag} (the Release workflow sees the draft is there and changes nothing)"]
        commands = [f"git push origin {commit}:refs/heads/{branch}", shlex.join(map(str, create)),
                    f"git push origin {self.tag}"]
        if self.checkpoint(f"push and draft the GitHub release {self.tag}", sends, commands):
            self.run(["git", "push", "origin", f"{commit}:refs/heads/{branch}"], cwd=self.root)
            view = self.run(["gh", "release", "view", self.tag, "--repo", REPO, "--json", "isDraft"],
                            cwd=self.root, capture=True, check=False)
            if view.returncode == 0:
                if not json.loads(view.stdout).get("isDraft"):
                    raise ShipError(f"{self.tag} is already published. Nothing was changed on it.")
                self.run(["gh", "release", "edit", self.tag, "--repo", REPO, "--title", title, "--notes-file", notes],
                         cwd=self.root)
                self.run(["gh", "release", "upload", self.tag, "--repo", REPO, "--clobber", *assets], cwd=self.root)
            else:
                self.run(create, cwd=self.root)
            self.run(["git", "push", "origin", self.tag], cwd=self.root)
        self.done("draft")

    def step_appcast(self):
        print("\n== The appcast and the files")
        assets = self.assets()
        folder = assets[0].parent
        for name in ("Nollie.dmg", "Nollie.zip"):
            listed = (folder / f"{name}.sha256").read_text().split()[0]
            if listed != sha256(folder / name):
                raise ShipError(f"{name}.sha256 does not match {name}.")
        self.require_fit_appcast(folder / "appcast.xml", (folder / "Nollie.zip").stat().st_size)
        reads = [f"gh release download {self.tag} --repo {REPO} --dir <folder> " +
                 " ".join(f"--pattern {name}" for name in ASSETS),
                 f"gh release view {self.tag} --repo {REPO} --json isDraft,body"]
        if self.dry:
            print("Dry run: the local files are checked. A real run then reads the draft back and checks it:")
            for line in reads:
                print(f"  {line}")
            self.done("appcast")
            return
        check = self.out / "draft-check"
        shutil.rmtree(check, ignore_errors=True)
        check.mkdir(parents=True)
        self.run(["gh", "release", "download", self.tag, "--repo", REPO, "--dir", check,
                  *[part for name in ASSETS for part in ("--pattern", name)]], cwd=self.root)
        for path in assets:
            if sha256(check / path.name) != sha256(path):
                raise ShipError(f"The draft's {path.name} is not the one made here.")
        self.require_fit_appcast(check / "appcast.xml", (check / "Nollie.zip").stat().st_size)
        view = json.loads(self.run(["gh", "release", "view", self.tag, "--repo", REPO, "--json", "isDraft,body"],
                                   cwd=self.root, capture=True).stdout)
        if not view.get("isDraft"):
            raise ShipError(f"{self.tag} is no longer a draft.")
        if view.get("body", "").replace("\r\n", "\n").strip() != (self.out / "notes.md").read_text().strip():
            raise ShipError("The draft's notes are not the ones in the appcast. Put them back, or run "
                            f"Tools/release/sparkle-appcast.sh again and upload the new appcast.xml.")
        print("The draft has every file, unchanged, and the notes match.")
        self.done("appcast")

    def step_publish(self):
        print(f"\n== Publish {self.tag}")
        command = ["gh", "release", "edit", self.tag, "--repo", REPO, "--draft=false", "--latest"]
        sends = [f"publishes {self.tag}: the download link gets Nollie {self.version}, and every copy of Nollie for "
                 f"Mac that checks for updates is offered {self.version} ({self.build})"]
        if self.checkpoint(f"publish {self.tag}", sends, [shlex.join(command)]):
            self.run(command, cwd=self.root)
            size = (self.out / "assets" / "Nollie.zip").stat().st_size
            for attempt in range(12):
                try:
                    problems = check_appcast.problems(fetch(LATEST_APPCAST).decode(), self.tag, size)
                except OSError:
                    problems = ["could not read it"]
                if not problems:
                    print(f"The live appcast offers {self.version}.")
                    break
                time.sleep(15)
            else:
                raise ShipError(f"The live appcast is not {self.tag}'s yet: {' '.join(problems)}")
        self.done("publish")

    def site_problems(self):
        if not (SITE / "public" / "index.html").exists():
            return [f"There is no site at {SITE}."]
        found = []
        dirty = self.run(["git", "status", "--porcelain", "--", "public"], cwd=SITE, capture=True, check=False).stdout
        if dirty.strip():
            found.append("public/ has uncommitted changes.")
        if SITE_DOWNLOAD not in (SITE / "public" / "index.html").read_text():
            found.append(f"index.html no longer links to {SITE_DOWNLOAD}.")
        return found

    def step_site(self):
        print("\n== nollie.app")
        problems = self.site_problems()
        if problems:
            raise ShipError(" ".join(problems))
        branch = self.run(["git", "symbolic-ref", "--short", "HEAD"], cwd=SITE, capture=True, check=False).stdout.strip()
        commit = self.run(["git", "rev-parse", "--short", "HEAD"], cwd=SITE, capture=True).stdout.strip()
        files = [path for path in (SITE / "public").rglob("*") if path.is_file()]
        size = sum(path.stat().st_size for path in files)
        command = ["npx", "wrangler", "pages", "deploy", "public", "--project-name", "nollie", "--branch", "main"]
        sends = [f"{SITE}/public at {commit} on {branch}: {len(files)} files, {size_text(size)}, to Cloudflare Pages "
                 "project nollie (nollie.app)"]
        if branch != "main":
            sends.append(f"note: the site is on {branch}, not main")
        if self.checkpoint("deploy nollie.app", sends, [f"cd {SITE} && {shlex.join(command)}"]):
            self.run(command, cwd=SITE)
            local = sha256(SITE / "public" / "index.html")
            for attempt in range(12):
                try:
                    live = hashlib.sha256(fetch(SITE_URL)).hexdigest()
                except OSError:
                    live = ""
                if live == local:
                    print("nollie.app serves this index.html.")
                    break
                time.sleep(10)
            else:
                raise ShipError("nollie.app does not serve this index.html yet. Check it in a browser.")
        self.done("site")


# --- Running ---------------------------------------------------------------------------------------------

def plan(state, start=None, only=None):
    if only:
        return [only]
    if start:
        return list(STEPS[STEPS.index(start):])
    done = state.get("steps", {})
    return [step for step in STEPS if step not in done]


def status(ship):
    print(f"Nollie {ship.version}{' (dry run)' if ship.dry else ''}: {ship.state_path}")
    for step in STEPS:
        entry = ship.state["steps"].get(step)
        print(f"  {'done' if entry else '    '}  {step}{('  ' + entry['done']) if entry else ''}")


def clean(ship):
    """Removes what a dry run built: its checkout, the builds and Xcode's caches for them. Keeps the reports."""
    if not ship.dry:
        raise ShipError("--clean is for dry runs. A real release folder is kept.")
    checkout = ship.state.get("checkout")
    if checkout and Path(checkout).exists():
        ship.git("worktree", "remove", "--force", checkout)
    derived = Path.home() / "Library" / "Developer" / "Xcode" / "DerivedData"
    for info in derived.glob("*/info.plist") if checkout else []:
        try:
            workspace = plistlib.loads(info.read_bytes()).get("WorkspacePath", "")
        except Exception:
            continue
        if workspace.startswith(checkout):
            shutil.rmtree(info.parent, ignore_errors=True)
    for name in ("mac", "ios", "macstore", "assets"):
        shutil.rmtree(ship.out / name, ignore_errors=True)
    ship.state.pop("checkout", None)
    ship.state["products"] = {}
    ship.save()
    print(f"Removed the dry run's builds. Kept {ship.out}/preflight.txt, would-send.txt and state.json.")


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("version", help="the version to release, such as 1.3")
    parser.add_argument("--dry-run", action="store_true", help="every local step on a throwaway copy; sends nothing")
    parser.add_argument("--from", dest="start", choices=STEPS, help="start at this step")
    parser.add_argument("--only", choices=STEPS, help="run only this step")
    parser.add_argument("--approve", action="append", choices=STEPS, default=[],
                        help="Corey has said yes to this step's checkpoint (for runs without a terminal)")
    parser.add_argument("--build", help="the build number (default: one more than the project's)")
    parser.add_argument("--notes", help="the release notes (default: Docs/releases/<version>.md)")
    parser.add_argument("--check-stages", nargs="+", choices=CHECK_STAGES, help="verify.py stages (default: all)")
    parser.add_argument("--status", action="store_true", help="show what is done")
    parser.add_argument("--clean", action="store_true", help="remove a dry run's checkout and builds")
    return parser.parse_args(argv)


def main(argv=None):
    args = arguments(argv)
    # Lines in order with the tools' own output, even into a log file.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(line_buffering=True)
    try:
        ship = Ship(args)
        if args.status:
            status(ship)
            return 0
        if args.clean:
            clean(ship)
            return 0
        steps = plan(ship.state, args.start, args.only)
        if not steps:
            print(f"Every step of {ship.version} is done. --from <step> runs one again.")
            return 0
        if steps[0] != "preflight" and "preflight" not in ship.state["steps"]:
            raise ShipError("Run the preflight first.")
        if steps[0] == "preflight" and ship.dry:
            ship.out.mkdir(parents=True, exist_ok=True)
            (ship.out / "would-send.txt").write_text(
                f"# What a real run of Nollie {ship.version} would send. This dry run sent none of it.\n\n")
        ship.save()
        for step in steps:
            ship.step = step
            getattr(ship, f"step_{step}")()
    except Stop as stop:
        print(f"\nStopped before {stop.step} sends anything. Nothing has left this Mac for it.")
        print(f"Once Corey says yes: Tools/release/ship.sh {args.version} --from {stop.step} --approve {stop.step}")
        return 2
    except ShipError as error:
        print(f"\nStopped: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nStopped.", file=sys.stderr)
        return 130
    if ship.dry:
        failed = ship.state.get("preflight_failed") or []
        print(f"\nDry run finished. What a real run would send: {ship.out / 'would-send.txt'}")
        missing = [step for step in STEPS if step not in ship.state["steps"]]
        if missing:
            print(f"Not done yet in this rehearsal: {', '.join(missing)}.")
        if failed:
            print(f"A real run would stop at the preflight: {', '.join(failed)}.")
            return 1
        print(f"Run `Tools/release/ship.sh {ship.version} --dry-run --clean` to remove its builds.")
    else:
        print(f"\nNollie {ship.version}: {', '.join(steps)} done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
