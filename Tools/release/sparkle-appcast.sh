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
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
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
cp "$STAGE/appcast.xml" "$OUT/appcast.xml"
python3 -I Tools/release/check_appcast.py "$OUT/appcast.xml" --tag "$TAG" --zip "$ZIP"
echo "Appcast: $OUT/appcast.xml"
