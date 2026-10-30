#!/usr/bin/env python3
"""Syncs a version's App Store listing with what is on TestFlight.

    asc-listing.py attach <version> <build>   link a processed build to that version's listing
    asc-listing.py screenshots                swap the iPhone screenshots for the PNGs found in
                                              Tools/release/screenshots, sorted by name

A listing that does not exist yet is created in "Prepare for Submission". Nothing is submitted for
review by this script. The screenshots go into the 6.9-inch iPhone slot, and a PNG made for another
iPhone size is first scaled to 1320x2868 with `sips`. The App Store Connect key comes from
Tools/release/.env.
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

from release_guard import GuardError, release_environment, require_app_identity

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
BASE = "https://api.appstoreconnect.apple.com/v1"
SHOT_DIR = os.path.join(HERE, "screenshots")
SCREEN_SIZE = ("2868", "1320")   # height, width for sips -z
DISPLAY_TYPE = "APP_IPHONE_67"

settings = release_environment(os.path.join(HERE, ".env"))
APP_ID = os.environ.get("ASC_APP_ID") or settings.get("ASC_APP_ID")
if not APP_ID:
    sys.exit("Set ASC_APP_ID to your App Store Connect app ID.")


def die(message):
    print("error:", message)
    sys.exit(1)


def make_token():
    # ASC_KEY_KIND too: Corey's own key signs as him only with it, and Apple refuses its token without it.
    keys = {name: settings[name] for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH", "ASC_KEY_KIND")
            if settings.get(name)}
    out = subprocess.check_output(["swift", os.path.join(HERE, "asc-jwt.swift")], env={**os.environ, **keys})
    return out.decode().strip()


def api(verb, path, json_body=None, data=None, extra_headers=None):
    """One request. Returns (status, decoded JSON or {})."""
    headers = {"Authorization": "Bearer " + make_token(), **(extra_headers or {})}
    payload = data
    if json_body is not None:
        headers["Content-Type"] = "application/json"
        payload = json.dumps(json_body).encode()
    url = path if path.startswith("http") else BASE + path
    request = urllib.request.Request(url, method=verb, data=payload, headers=headers)
    try:
        with urllib.request.urlopen(request) as reply:
            text = reply.read()
            is_json = reply.headers.get("Content-Type", "").startswith("application/json")
            return reply.status, (json.loads(text) if text and is_json else {})
    except urllib.error.HTTPError as err:
        return err.code, json.loads(err.read() or b"{}")


def resource(kind, attributes=None, relationship=None):
    """A JSON:API body creating `kind`, optionally pointing at a parent."""
    body = {"type": kind}
    if attributes:
        body["attributes"] = attributes
    if relationship:
        name, parent_kind, parent_id = relationship
        body["relationships"] = {name: {"data": {"type": parent_kind, "id": parent_id}}}
    return {"data": body}


def listing_for(version):
    status, found = api("GET", f"/apps/{APP_ID}/appStoreVersions?filter[platform]=IOS&filter[versionString]={version}")
    if found.get("data"):
        return found["data"][0]["id"]
    status, made = api("POST", "/appStoreVersions",
                       resource("appStoreVersions", {"platform": "IOS", "versionString": version}, ("app", "apps", APP_ID)))
    if status >= 400:
        die(f"creating version {version} failed: {made.get('errors')}")
    print(f"created App Store version {version}")
    return made["data"]["id"]


def wait_for_build(version, build):
    query = f"/builds?filter[app]={APP_ID}&filter[version]={build}&filter[preReleaseVersion.version]={version}&limit=1"
    for _ in range(60):
        _, reply = api("GET", query)
        rows = reply.get("data", [])
        state = rows[0]["attributes"]["processingState"] if rows else None
        if state == "VALID":
            return rows[0]["id"]
        print("waiting for build to process…", state or "not seen yet")
        time.sleep(60)
    die("build never became VALID")


def attach(version, build):
    build_id = wait_for_build(version, build)
    listing = listing_for(version)
    status, reply = api("PATCH", f"/appStoreVersions/{listing}/relationships/build",
                        {"data": {"type": "builds", "id": build_id}})
    if status >= 400:
        die(f"attach failed: {reply.get('errors')}")
    print(f"linked build {build} to version {version} in the App Store listing")


def find_or_create(list_path, matches, create_path, body):
    """The first listed row that matches, or a new one made with `body`."""
    _, listed = api("GET", list_path)
    for row in listed.get("data", []):
        if matches(row["attributes"]):
            return row["id"]
    _, made = api("POST", create_path, body)
    return made["data"]["id"]


def upload_one(name, set_id):
    """Reserve, send and commit one screenshot. Returns its id."""
    scaled = os.path.join(tempfile.mkdtemp(prefix="nollie-shots-"), name)
    subprocess.run(["sips", "-z", *SCREEN_SIZE, os.path.join(SHOT_DIR, name), "--out", scaled],
                   check=True, capture_output=True)
    with open(scaled, "rb") as handle:
        pixels = handle.read()

    status, reserved = api("POST", "/appScreenshots",
                           resource("appScreenshots", {"fileName": name, "fileSize": len(pixels)},
                                    ("appScreenshotSet", "appScreenshotSets", set_id)))
    if status >= 400:
        die(f"reserve {name}: {reserved.get('errors')}")
    shot = reserved["data"]

    for part in shot["attributes"]["uploadOperations"]:
        piece = pixels[part["offset"]:part["offset"] + part["length"]]
        sent_headers = {h["name"]: h["value"] for h in part["requestHeaders"]}
        urllib.request.urlopen(urllib.request.Request(part["url"], method=part["method"], data=piece,
                                                      headers=sent_headers)).read()

    commit = {"data": {"type": "appScreenshots", "id": shot["id"],
                       "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(pixels).hexdigest()}}}
    status, reply = api("PATCH", f"/appScreenshots/{shot['id']}", commit)
    if status >= 400:
        die(f"commit {name}: {reply.get('errors')}")
    print("uploaded", name)
    return shot["id"]


def screenshots():
    names = sorted(n for n in os.listdir(SHOT_DIR) if n.lower().endswith(".png"))
    if not names:
        die(f"no PNGs in {SHOT_DIR}")

    _, versions = api("GET", f"/apps/{APP_ID}/appStoreVersions?filter[platform]=IOS&limit=1")
    if not versions.get("data"):
        die("there is no App Store version yet; run attach first")
    version_id = versions["data"][0]["id"]

    locale_id = find_or_create(
        f"/appStoreVersions/{version_id}/appStoreVersionLocalizations",
        lambda a: a["locale"] == "en-US",
        "/appStoreVersionLocalizations",
        resource("appStoreVersionLocalizations", {"locale": "en-US"},
                 ("appStoreVersion", "appStoreVersions", version_id)))
    set_id = find_or_create(
        f"/appStoreVersionLocalizations/{locale_id}/appScreenshotSets",
        lambda a: a["screenshotDisplayType"] == DISPLAY_TYPE,
        "/appScreenshotSets",
        resource("appScreenshotSets", {"screenshotDisplayType": DISPLAY_TYPE},
                 ("appStoreVersionLocalization", "appStoreVersionLocalizations", locale_id)))

    # Replace the set: clear what is there, then upload the folder in order.
    _, existing = api("GET", f"/appScreenshotSets/{set_id}/appScreenshots")
    for old in existing.get("data", []):
        api("DELETE", f"/appScreenshots/{old['id']}")
    uploaded = [upload_one(name, set_id) for name in names]
    api("PATCH", f"/appScreenshotSets/{set_id}/relationships/appScreenshots",
        {"data": [{"type": "appScreenshots", "id": i} for i in uploaded]})
    print(f"{len(uploaded)} screenshots on the listing")


if __name__ == "__main__":
    words = sys.argv[1:] or ["help"]
    wants_attach = words[0] == "attach" and len(words) == 3
    if not (wants_attach or words == ["screenshots"]):
        print(__doc__)
        sys.exit(0)
    try:
        require_app_identity(APP_ID, lambda path: api("GET", path))
    except GuardError as error:
        die(str(error))
    if wants_attach:
        attach(words[1], words[2])
    else:
        screenshots()
