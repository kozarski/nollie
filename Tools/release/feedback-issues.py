#!/usr/bin/env python3
"""Turns TestFlight feedback and crash reports into GitHub issues.

    feedback-issues.py                       create an issue for each report that is new
    feedback-issues.py --dry-run             list what would be created, create nothing
    feedback-issues.py --since 2026-10-01    ignore reports dated before that day

Sources are the App Store Connect screenshot feedback and crash submissions, and the issues land in
the tracker used for everything else. Every issue has a hidden `<!-- asc:ID -->` line, which tells
the next run that it already exists. Because the tracker is public, testers' email addresses are
never copied over, and a crash log is trimmed to the thread that crashed. It needs the App Store
Connect key in Tools/release/.env and a `gh` login with write access to the repository.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

from release_guard import GuardError, release_environment, require_app_identity

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = "https://api.appstoreconnect.apple.com/v1"
DRY_RUN = "--dry-run" in sys.argv


def option_value(flag, default=""):
    if flag in sys.argv:
        at = sys.argv.index(flag) + 1
        return sys.argv[at] if at < len(sys.argv) else default
    return default


SINCE = option_value("--since")
MARKER = re.compile(r"<!-- asc:([\w-]+) -->")

settings = release_environment(os.path.join(HERE, ".env"))


def configured(name, why):
    value = os.environ.get(name) or settings.get(name)
    if not value:
        sys.exit(why)
    return value


APP_ID = configured("ASC_APP_ID", "Set ASC_APP_ID to your App Store Connect app ID.")
REPO = configured("NOLLIE_GITHUB_REPO", "Set NOLLIE_GITHUB_REPO to the issue repository (owner/name).")
PROJECT_OWNER = os.environ.get("NOLLIE_GITHUB_PROJECT_OWNER") or settings.get("NOLLIE_GITHUB_PROJECT_OWNER")
PROJECT_NUMBER = os.environ.get("NOLLIE_GITHUB_PROJECT_NUMBER") or settings.get("NOLLIE_GITHUB_PROJECT_NUMBER")

_keys = {name: settings[name] for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH")}
TOKEN = subprocess.check_output(["swift", os.path.join(HERE, "asc-jwt.swift")], env={**os.environ, **_keys}).decode().strip()


def fetch(path):
    url = path if path.startswith("http") else BASE + path
    with urllib.request.urlopen(urllib.request.Request(url, headers={"Authorization": "Bearer " + TOKEN})) as reply:
        return json.loads(reply.read() or b"{}")


def github(*args):
    done = subprocess.run(["gh", *args], capture_output=True, text=True)
    if done.returncode:
        print("gh error:", done.stderr.strip()[:300], file=sys.stderr)
    return done.stdout.strip()


try:
    require_app_identity(APP_ID, lambda path: (200, fetch(path)))
except GuardError as error:
    sys.exit("Release blocked: " + str(error))


def already_filed():
    raw = github("issue", "list", "--repo", REPO, "--state", "all", "--limit", "1000", "--json", "body")
    seen = set()
    for issue in json.loads(raw or "[]"):
        seen.update(MARKER.findall(issue.get("body") or ""))
    return seen


def build_label(reply, relationships):
    wanted = ((relationships.get("build") or {}).get("data") or {}).get("id")
    for row in reply.get("included", []):
        if row.get("type") == "builds" and row.get("id") == wanted:
            return row.get("attributes", {}).get("version") or "?"
    return "?"


def crashed_thread(log):
    """Keeps the header and the crashed thread from an Apple crash log, up to 60 lines."""
    lines = log.split("\n")
    starts = [i for i, line in enumerate(lines) if re.match(r"^Thread \d+ Crashed", line)]
    block = []
    if starts:
        for line in lines[starts[0]:]:
            if block and re.match(r"^Thread \d+", line):
                break
            block.append(line)
    top = log.split("\n\n", 1)[0]
    return f"{top}\n\n" + "\n".join(block[:60])


def crash_issue(sid, attrs, comment, build, device):
    if comment:
        first = comment.splitlines()[0][:70]
    else:
        first = "%s on build %s" % (attrs.get("deviceModel", "?"), build)
    parts = [f"<!-- asc:{sid} -->", f"TestFlight crash report. {device}. {attrs.get('createdDate', '')}", ""]
    if comment:
        parts += [f"> {comment}", ""]
    log = None
    try:
        answer = fetch(f"/betaFeedbackCrashSubmissions/{sid}/crashLog")
        log = answer.get("data", {}).get("attributes", {}).get("logText")
    except Exception:
        pass
    text = "\n".join(parts) + "\n"
    if log:
        text += "<details><summary>Thread that crashed</summary>\n\n```\n" + crashed_thread(log) + "\n```\n</details>\n"
    return "Crash: " + first, ["crash", "from-testflight"], text


def feedback_issue(sid, attrs, comment, device):
    title = (comment.splitlines()[0] if comment else "Screenshot with no note")[:80]
    body = (f"<!-- asc:{sid} -->\nTestFlight report from {device}. {attrs.get('createdDate', '')}\n\n> "
            + comment.replace("\n", "\n> "))
    count = len(attrs.get("screenshots") or [])
    if count:
        body += f"\n\n{count} screenshot(s) can be found in App Store Connect."
    return title, ["from-testflight", "needs-approval"], body


def file_issue(kind, title, labels, body):
    print(("DRY " if DRY_RUN else "filing ") + f"[{kind}] {title}")
    if DRY_RUN:
        return
    command = ["issue", "create", "--repo", REPO, "--title", title, "--body", body, "--milestone", "Backlog"]
    for label in labels:
        command += ["--label", label]
    url = github(*command)
    # Also onto the project board, whose "Item added" workflow puts it under Inbox.
    if url and PROJECT_OWNER and PROJECT_NUMBER:
        github("project", "item-add", PROJECT_NUMBER, "--owner", PROJECT_OWNER, "--url", url)
    time.sleep(0.5)


def main():
    seen = already_filed()
    count = 0
    for endpoint, kind in (("betaFeedbackScreenshotSubmissions", "feedback"), ("betaFeedbackCrashSubmissions", "crash")):
        reply = fetch(f"/apps/{APP_ID}/{endpoint}?limit=50&sort=-createdDate&include=build")
        for item in reply.get("data", []):
            sid, attrs = item["id"], item.get("attributes", {})
            if sid in seen or (SINCE and (attrs.get("createdDate") or "") < SINCE):
                continue
            build = build_label(reply, item.get("relationships", {}))
            comment = (attrs.get("comment") or "").strip()
            device = f"{attrs.get('deviceModel', '?')} · iOS {attrs.get('osVersion', '?')} · build {build}"
            if kind == "crash":
                made = crash_issue(sid, attrs, comment, build, device)
            else:
                made = feedback_issue(sid, attrs, comment, device)
            count += 1
            file_issue(kind, *made)
    print(f"{count} new report(s)" + (" (dry run)" if DRY_RUN else " filed"))


main()
