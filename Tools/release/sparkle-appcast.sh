#!/bin/bash
# Sign a finished Direct release for Sparkle and write its appcast.xml.
#
#   Tools/release/sparkle-appcast.sh <release folder> [tag]     tag defaults to v<version>
#
# direct-release.sh runs this at its end. Run it again, on the same folder, once the GitHub release
# notes are final, so the appcast carries them. It needs the update key: in your login keychain
# (Tools/release/sparkle-keys.sh), or in a file named by SPARKLE_KEY_FILE. From the keychain, macOS asks
# once whether sign_update may use it, and waits until someone answers. Every signature is checked
# against the key inside the app before anything is written, so a wrong key signs nothing that ships.
#
# Reads:   <folder>/notarized/Nollie.app, Nollie-<version>-<build>.zip and .dmg
# Notes:   the GitHub release's text (gh), else <folder>/notes.md, else a one-line stand-in
# Seeds:   the latest published appcast, so earlier versions stay in the feed
# Writes:  <folder>/appcast.xml and <folder>/sparkle-signatures.txt
#
# DRY_RUN=1 rehearses all of it with a stand-in key made for the run, so neither the keychain nor the
# update key is touched. Installed copies would refuse what it signs, which is the point: it cannot ship.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="$(cd "${1:?release folder}" && pwd)"
REPO="kozarski/nollie"

python3 -I Tools/sparkle/sparkle_config.py check-release
APP="$OUT/notarized/Nollie.app"
[ -d "$APP" ] || APP="$OUT/export/Nollie.app"
[ -d "$APP" ] || { echo "No Nollie.app in $OUT." >&2; exit 1; }
python3 -I Tools/sparkle/sparkle_config.py check-app "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
TAG="${2:-v$VERSION}"
ZIP="$OUT/Nollie-$VERSION-$BUILD.zip"
DMG="$OUT/Nollie-$VERSION-$BUILD.dmg"
[ -f "$ZIP" ] && [ -f "$DMG" ] || { echo "The zip or the DMG for $VERSION ($BUILD) is missing from $OUT." >&2; exit 1; }

TOOLS=$(Tools/sparkle/fetch-sparkle.sh)/bin
APP_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")
KEY=()
DRY="${DRY_RUN:-}"
if [ -n "$DRY" ]; then
  # A key that lives for this run only. Its signatures are checked against its own public half.
  STANDIN="$OUT/standin-key"
  mkdir -p "$STANDIN"
  cat > "$STANDIN/make.swift" <<'SWIFT'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
try! Data(key.rawRepresentation.base64EncodedString().utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
  ( umask 077; swift "$STANDIN/make.swift" "$STANDIN/private.txt" > "$STANDIN/public.txt" )
  KEY=(--ed-key-file "$STANDIN/private.txt")
  APP_KEY=$(cat "$STANDIN/public.txt")
  echo "Dry run: signing with a stand-in key. Installed copies of Nollie would refuse these signatures."
elif [ -n "${SPARKLE_KEY_FILE:-}" ]; then
  [ -f "$SPARKLE_KEY_FILE" ] || { echo "There is no key file at $SPARKLE_KEY_FILE." >&2; exit 1; }
  KEY=(--ed-key-file "$SPARKLE_KEY_FILE")
else
  # The key in the keychain must be the one the app trusts, or no installed copy would accept the update.
  KEYCHAIN_KEY=$("$TOOLS/generate_keys" -p | /usr/bin/tr -d '[:space:]') || { echo "No update key in your login keychain. Run Tools/release/sparkle-keys.sh." >&2; exit 1; }
  [ "$KEYCHAIN_KEY" = "$APP_KEY" ] || { echo "The key in your keychain is not the one inside this app. Nothing was signed." >&2; exit 1; }
  echo "Signing with the key in your keychain. If nothing happens, macOS is asking to allow it."
fi

echo "== Sign the downloads"
{
  echo "# EdDSA signatures for $TAG (public key $APP_KEY)"
  for file in "$ZIP" "$DMG"; do
    printf '%s  ' "$(basename "$file")"
    "$TOOLS/sign_update" ${KEY[@]+"${KEY[@]}"} "$file"
  done
} > "$OUT/sparkle-signatures.txt"
cat "$OUT/sparkle-signatures.txt"
# Check each signature the way an installed copy will, against the key inside the app.
for file in "$ZIP" "$DMG"; do
  signature=$(grep -F "$(basename "$file")" "$OUT/sparkle-signatures.txt" | sed -E 's/.*edSignature="([^"]+)".*/\1/')
  swift Tools/sparkle/verify-signature.swift "$APP_KEY" "$signature" "$file" \
    || { echo "That key is not the one inside this app. Nothing was written." >&2; rm -f "$OUT/sparkle-signatures.txt"; exit 1; }
done

echo "== Make the appcast"
STAGE="$OUT/appcast"
rm -rf "$STAGE" && mkdir -p "$STAGE"
# Sparkle updates from the zip: it unpacks without mounting anything. The name is the release's.
cp "$ZIP" "$STAGE/Nollie.zip"
if gh release download --repo "$REPO" --pattern appcast.xml --dir "$STAGE" > /dev/null 2>&1; then
  echo "Started from the latest published appcast."
else
  echo "No published appcast yet, so this one starts the feed."
fi
if notes=$(gh release view "$TAG" --repo "$REPO" --json body --jq .body 2> /dev/null) && [ -n "$notes" ]; then
  printf '%s\n' "$notes" > "$STAGE/Nollie.md"
elif [ -f "$OUT/notes.md" ]; then
  cp "$OUT/notes.md" "$STAGE/Nollie.md"
else
  echo "warning: no release notes found for $TAG. Once the draft release has its notes, run this again." >&2
  printf 'Nollie %s.\n' "$VERSION" > "$STAGE/Nollie.md"
fi
"$TOOLS/generate_appcast" ${KEY[@]+"${KEY[@]}"} \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --full-release-notes-url "https://github.com/$REPO/releases/tag/$TAG" \
  --link "https://nollie.app" \
  --embed-release-notes --maximum-deltas 0 \
  "$STAGE"
if [ -n "$DRY" ]; then
  # generate_appcast leaves the item unsigned when the key is not the app's, as with the stand-in. Put
  # the stand-in's checked signature on it, so the check below looks at a whole item.
  signature=$(grep -F "$(basename "$ZIP")" "$OUT/sparkle-signatures.txt" | sed -E 's/.*edSignature="([^"]+)".*/\1/')
  python3 -I - "$STAGE/appcast.xml" "$VERSION" "$signature" <<'PY'
import sys
import xml.etree.ElementTree as ET
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")
path, version, signature = sys.argv[1:]
tree = ET.parse(path)
for item in tree.getroot().findall("./channel/item"):
    enclosure = item.find("enclosure")
    if item.findtext(f"{{{SPARKLE}}}shortVersionString") == version and enclosure is not None:
        enclosure.set(f"{{{SPARKLE}}}edSignature", signature)
tree.write(path, xml_declaration=True, encoding="utf-8")
PY
  rm -rf "$STANDIN"
fi
cp "$STAGE/appcast.xml" "$OUT/appcast.xml"
python3 -I Tools/release/check_appcast.py "$OUT/appcast.xml" --tag "$TAG" --zip "$ZIP"
echo "Appcast: $OUT/appcast.xml"
