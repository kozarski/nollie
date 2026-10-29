#!/usr/bin/env python3
"""Fail-closed identity and signing checks shared by Nollie's release tools."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import posixpath
import re
import stat
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

BUNDLE_ID = "com.coreykozarski.nollie"
OWNER = "Corey Kozarski"
TEAM_ID = "5985LRZFZS"
CLOUD_CONTAINER = "iCloud.com.coreykozarski.nollie"
API = "https://api.appstoreconnect.apple.com/v1"


class GuardError(Exception):
    pass


def require_app_identity(app_id, fetch):
    """fetch(path) returns (status, decoded JSON); no mutation is needed to verify identity."""
    if not isinstance(app_id, str) or not re.fullmatch(r"[0-9]+", app_id):
        raise GuardError("ASC_APP_ID must be the numeric Nollie app ID.")
    try:
        status, payload = fetch(f"/apps/{app_id}?fields[apps]=bundleId")
        data = payload.get("data", {})
        valid = (status == 200 and isinstance(data, dict) and data.get("type") == "apps"
                 and data.get("id") == app_id
                 and data.get("attributes", {}).get("bundleId") == BUNDLE_ID)
    except Exception:
        raise GuardError("Could not verify the App Store Connect app identity.") from None
    if not valid:
        raise GuardError(f"ASC_APP_ID does not resolve to {BUNDLE_ID}. Nothing was changed.")


def release_environment(path, environ=None):
    """Runtime configuration only. Environment values take precedence over the optional file."""
    values = {}
    path = Path(path)
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if line.startswith("export "):
                line = line[7:]
            if "=" in line and not line.startswith("#"):
                key, value = line.split("=", 1)
                values[key.strip()] = os.path.expandvars(value.strip().strip('"').strip("'"))
    values.update(os.environ if environ is None else environ)
    return values


def command(args):
    """Capture diagnostics so tool errors never print key material or signed profile contents."""
    try:
        return subprocess.run(args, check=True, capture_output=True).stdout
    except (OSError, subprocess.CalledProcessError):
        raise GuardError(f"{Path(args[0]).name} verification failed.") from None


def verify_remote_app(app_id):
    required = ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH")
    if not all(os.environ.get(key) for key in required):
        raise GuardError("Set the App Store Connect key configuration before releasing.")
    token = command(["swift", str(Path(__file__).with_name("asc-jwt.swift"))]).decode().strip()

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None

    def fetch(path):
        request = urllib.request.Request(API + path, headers={"Authorization": "Bearer " + token})
        with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
            return response.status, json.load(response)
    require_app_identity(app_id, fetch)


def read_plist(path):
    try:
        with Path(path).open("rb") as stream:
            value = plistlib.load(stream)
        if not isinstance(value, dict):
            raise ValueError()
        return value
    except (OSError, ValueError, plistlib.InvalidFileException):
        raise GuardError("A required release plist is missing or invalid.") from None


def app_info(app):
    path = app / "Contents" / "Info.plist" if (app / "Contents").is_dir() else app / "Info.plist"
    return read_plist(path)


def require_client_contents(app):
    """Store exports contain the client, never the Direct edition's local services."""
    contents = Path(app) / "Contents"
    library = contents / "Library"
    forbidden = (
        contents / "Helpers" / "Nollie Runtime.app",
        library / "Helpers" / "Nollie Runtime.app",
        library / "LaunchAgents" / "com.coreykozarski.nollie.runtime.plist",
        library / "LoginItems" / "Nollie Notifications.app",
    )
    if any(path.exists() or path.is_symlink() for path in forbidden):
        raise GuardError("The Store export contains a Direct-edition background service.")


def require_archive(archive, build_number):
    archive = Path(archive)
    metadata = read_plist(archive / "Info.plist").get("ApplicationProperties", {})
    if not isinstance(metadata, dict) or metadata.get("CFBundleIdentifier") != BUNDLE_ID or str(metadata.get("CFBundleVersion")) != build_number:
        raise GuardError("Archive identity or build number does not match this Nollie release.")
    relative = metadata.get("ApplicationPath")
    if not isinstance(relative, str) or Path(relative).is_absolute() or ".." in Path(relative).parts:
        raise GuardError("Archive application path is invalid.")
    app = archive / "Products" / relative
    products = (archive / "Products").resolve()
    if products not in app.resolve().parents or not app.is_dir():
        raise GuardError("Archive application is missing or outside the archive.")
    info = app_info(app)
    if info.get("CFBundleIdentifier") != BUNDLE_ID or str(info.get("CFBundleVersion")) != build_number:
        raise GuardError("Archived app identity or build number is incorrect.")
    details = subprocess.run(["codesign", "-d", "--verbose=2", str(app)], capture_output=True)
    require_named_signer(line.split("=", 1)[1] for line in details.stderr.decode().splitlines()
                         if line.startswith("Authority="))


def require_named_signer(authorities):
    """The archive is signed with one of Corey's own certificates, never one an API key created."""
    leaf = next(iter(authorities), "")
    if "Created via API" in leaf or OWNER not in leaf:
        raise GuardError(f"The archive is signed by \"{leaf or 'nothing'}\", not one of {OWNER}'s certificates. "
                         "Sign in to Xcode with his Apple Account and archive again.")


def require_export_metadata(info, identifier, team, entitlements, profile, platform, build_number):
    if platform not in ("ios", "macos"):
        raise GuardError("Unsupported release platform.")
    if not all(isinstance(value, dict) for value in (info, entitlements, profile)):
        raise GuardError("Exported signing metadata is invalid.")
    if info.get("CFBundleIdentifier") != BUNDLE_ID or identifier != BUNDLE_ID:
        raise GuardError("The exported app is not Nollie.")
    if str(info.get("CFBundleVersion")) != build_number:
        raise GuardError("The exported build number does not match this release.")
    if team != TEAM_ID or entitlements.get("com.apple.developer.team-identifier") != TEAM_ID:
        raise GuardError("The exported app is signed by the wrong team.")
    app_key = "com.apple.application-identifier" if platform == "macos" else "application-identifier"
    aps_key = "com.apple.developer.aps-environment" if platform == "macos" else "aps-environment"
    expected_identifier = TEAM_ID + "." + BUNDLE_ID
    if entitlements.get(app_key) != expected_identifier:
        raise GuardError("The signed application identifier is incorrect.")
    if entitlements.get(aps_key) != "production":
        raise GuardError("The exported signature does not use production APNs.")
    containers = entitlements.get("com.apple.developer.icloud-container-identifiers")
    if containers != [CLOUD_CONTAINER]:
        raise GuardError("The exported signature must contain only Nollie's iCloud container.")
    if (entitlements.get("com.apple.developer.icloud-container-environment") != "Production"
            or not isinstance(entitlements.get("com.apple.developer.icloud-services"), list)
            or "CloudKit" not in entitlements["com.apple.developer.icloud-services"]):
        raise GuardError("The exported signature is not configured for production CloudKit.")
    if entitlements.get("get-task-allow") or entitlements.get("com.apple.security.get-task-allow"):
        raise GuardError("The exported app still permits debugging.")
    grants = profile.get("Entitlements", {})
    if (not isinstance(grants, dict) or profile.get("TeamIdentifier") != [TEAM_ID]
            or grants.get(app_key) != expected_identifier
            or grants.get(aps_key) != "production"):
        raise GuardError("The provisioning profile does not match Nollie's production identity.")
    allowed = grants.get("com.apple.developer.icloud-container-identifiers", [])
    environment = grants.get("com.apple.developer.icloud-container-environment")
    production_allowed = environment == "Production" or (isinstance(environment, list) and "Production" in environment)
    # Profiles Xcode makes grant every iCloud service as "*"; a hand-made one lists them.
    services = grants.get("com.apple.developer.icloud-services")
    cloudkit_allowed = services == "*" or (isinstance(services, list) and "CloudKit" in services)
    if not isinstance(allowed, list) or CLOUD_CONTAINER not in allowed or not production_allowed or not cloudkit_allowed:
        raise GuardError("The provisioning profile does not grant production Nollie CloudKit access.")


def require_safe_ipa(path):
    """Check paths before ditto preserves the bundle's framework symlinks."""
    with zipfile.ZipFile(path) as archive:
        for item in archive.infolist():
            name = item.filename
            if name.startswith("/") or ".." in name.split("/") or "\\" in name:
                raise GuardError("The export contains an unsafe archive path.")
            if stat.S_ISLNK(item.external_attr >> 16):
                target = archive.read(item).decode("utf-8")
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
                if target.startswith("/") or resolved == ".." or resolved.startswith("../"):
                    raise GuardError("The export contains an unsafe symbolic link.")


def verify_export(product, platform, build_number):
    product = Path(product).resolve()
    if not product.is_file() or product.suffix != (".pkg" if platform == "macos" else ".ipa"):
        raise GuardError("The exported product is missing or has the wrong format.")
    with tempfile.TemporaryDirectory(prefix="nollie-release-check-") as directory:
        root = Path(directory)
        if platform == "macos":
            signature = command(["pkgutil", "--check-signature", str(product)]).decode()
            leaf = re.search(r"^\s*1\.\s+(.+)$", signature, re.MULTILINE)
            if not leaf or not leaf.group(1).rstrip().endswith("(" + TEAM_ID + ")"):
                raise GuardError("The installer is signed by the wrong team.")
            expanded = root / "package"
            command(["pkgutil", "--expand-full", str(product), str(expanded)])
            apps = [p for p in expanded.rglob("*.app") if not any(x.suffix == ".app" for x in p.parents)]
        else:
            require_safe_ipa(product)
            command(["ditto", "-x", "-k", str(product), str(root)])
            apps = list((root / "Payload").glob("*.app"))
        if len(apps) != 1:
            raise GuardError("Expected exactly one main app in the exported product.")
        app = apps[0]
        require_client_contents(app)
        command(["codesign", "--verify", "--deep", "--strict", str(app)])
        try:
            details = subprocess.run(["codesign", "-d", "--verbose=4", str(app)], check=True, capture_output=True)
            metadata = dict(line.split("=", 1) for line in details.stderr.decode().splitlines() if "=" in line)
            entitlements = plistlib.loads(command(["codesign", "-d", "--entitlements", ":-", str(app)]))
            profile_path = app / "Contents" / "embedded.provisionprofile" if platform == "macos" else app / "embedded.mobileprovision"
            profile = plistlib.loads(command(["security", "cms", "-D", "-i", str(profile_path)]))
        except (OSError, ValueError, subprocess.CalledProcessError, plistlib.InvalidFileException):
            raise GuardError("Could not read the exported signing metadata.") from None
        require_export_metadata(app_info(app), metadata.get("Identifier"), metadata.get("TeamIdentifier"),
                                entitlements, profile, platform, build_number)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("app").add_argument("app_id")
    archive = commands.add_parser("archive")
    archive.add_argument("path"); archive.add_argument("build_number")
    export = commands.add_parser("export")
    export.add_argument("path"); export.add_argument("platform", choices=["ios", "macos"]); export.add_argument("build_number")
    args = parser.parse_args()
    try:
        if args.action == "app": verify_remote_app(args.app_id)
        elif args.action == "archive": require_archive(args.path, args.build_number)
        else: verify_export(args.path, args.platform, args.build_number)
    except (GuardError, OSError, ValueError, zipfile.BadZipFile) as error:
        print("Release blocked: " + (str(error) if isinstance(error, GuardError) else "Invalid release metadata."), file=sys.stderr)
        return 1
    print("Verified Nollie " + args.action + ".")
    return 0


if __name__ == "__main__":
    sys.exit(main())
