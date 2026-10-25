#!/usr/bin/env python3
"""The Direct Mac edition's update settings (Tools/sparkle/update-feed.env) and the checks a release makes on them.

    python3 -I Tools/sparkle/sparkle_config.py check-release           the settings are fit to ship
    python3 -I Tools/sparkle/sparkle_config.py check-app <Nollie.app>  a built app carries them
    python3 -I Tools/sparkle/sparkle_config.py write-key <public key> [--replace]

Standard library only. Nothing here reads or prints a private key.
"""
import base64
import binascii
from pathlib import Path
import plistlib
import re
import sys

HERE = Path(__file__).resolve().parent
FEED_ENV = HERE / "update-feed.env"
EXPECTED_FEED = "https://github.com/kozarski/nollie/releases/latest/download/appcast.xml"
PLACEHOLDER = "PLACEHOLDER_RUN_TOOLS_RELEASE_SPARKLE_KEYS_SH"


def read_env(path=FEED_ENV):
    values = {}
    for line in Path(path).read_text().splitlines():
        match = re.fullmatch(r"([A-Z0-9_]+)=(.*)", line.strip())
        if match:
            values[match.group(1)] = match.group(2).strip()
    return values


def valid_public_key(key):
    """An EdDSA public key is 32 bytes in base64. The placeholder is not one."""
    try:
        return len(base64.b64decode(key.strip(), validate=True)) == 32
    except (binascii.Error, ValueError, AttributeError):
        return False


def release_problems(env):
    """What stops these settings from shipping. Empty when they are fit."""
    problems = []
    key = env.get("SPARKLE_PUBLIC_ED_KEY", "")
    if key == PLACEHOLDER:
        problems.append("SPARKLE_PUBLIC_ED_KEY is still the placeholder. Run Tools/release/sparkle-keys.sh once.")
    elif not valid_public_key(key):
        problems.append("SPARKLE_PUBLIC_ED_KEY is not a 32-byte public key in base64.")
    if env.get("SPARKLE_FEED_URL") != EXPECTED_FEED:
        problems.append(f"SPARKLE_FEED_URL is not {EXPECTED_FEED}.")
    return problems


def app_problems(info, env):
    """What is wrong with the update settings inside a built app's Info.plist."""
    problems = []
    if info.get("SUPublicEDKey") != env.get("SPARKLE_PUBLIC_ED_KEY"):
        problems.append("The app's SUPublicEDKey is not the one in Tools/sparkle/update-feed.env.")
    if info.get("SUFeedURL") != env.get("SPARKLE_FEED_URL"):
        problems.append("The app's SUFeedURL is not the one in Tools/sparkle/update-feed.env.")
    if info.get("SUEnableAutomaticChecks") is not True:
        problems.append("Automatic checks are not on by default.")
    if info.get("SUAllowsAutomaticUpdates") is not False:
        problems.append("The app may install updates without asking.")
    return problems + release_problems({"SPARKLE_PUBLIC_ED_KEY": str(info.get("SUPublicEDKey", "")),
                                        "SPARKLE_FEED_URL": str(info.get("SUFeedURL", ""))})


def write_key(key, replace=False, path=FEED_ENV):
    """Writes the public key into the settings. Replacing a real key is refused unless asked: apps
    already out there only trust the key they shipped with."""
    if not valid_public_key(key):
        raise ValueError("That is not a 32-byte public key in base64.")
    path = Path(path)
    text = path.read_text()
    current = read_env(path).get("SPARKLE_PUBLIC_ED_KEY", PLACEHOLDER)
    if current not in (PLACEHOLDER, key) and not replace:
        raise ValueError("update-feed.env already has a different key. Apps out there trust it; "
                         "replacing it would stop their updates. Pass --replace only if that is intended.")
    path.write_text(re.sub(r"^SPARKLE_PUBLIC_ED_KEY=.*$", f"SPARKLE_PUBLIC_ED_KEY={key.strip()}", text, flags=re.M))


def main(argv):
    if len(argv) >= 2 and argv[1] == "check-release":
        problems = release_problems(read_env())
    elif len(argv) == 3 and argv[1] == "check-app":
        with open(Path(argv[2]) / "Contents/Info.plist", "rb") as handle:
            problems = app_problems(plistlib.load(handle), read_env())
    elif len(argv) >= 3 and argv[1] == "write-key":
        try:
            write_key(argv[2], replace="--replace" in argv[3:])
        except ValueError as error:
            print(error, file=sys.stderr)
            return 1
        return 0
    else:
        print(__doc__, file=sys.stderr)
        return 2
    for problem in problems:
        print("error: " + problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
