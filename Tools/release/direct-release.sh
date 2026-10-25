#!/bin/bash
# Builds the Direct Mac edition for people outside the Mac App Store: archive, Developer ID
# signature, Apple's notarization, stapled ticket, then a signed DMG.
#
#   Tools/release/direct-release.sh [output folder]      (default build/release/<date-time>)
#
# It also signs the zip and the DMG for Sparkle and writes appcast.xml (Tools/release/sparkle-appcast.sh),
# so installed copies update themselves. That needs the update key (Tools/release/sparkle-keys.sh, once),
# and the script refuses to start while the app's update key is still the placeholder.
#
# The app is notarized through Xcode's signed-in account (no password needed here), or with notarytool
# when NOTARY_PROFILE names a notarytool keychain profile. The DMG needs notarytool: NOTARY_PROFILE, or
# the App Store Connect API key testflight.sh uses (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH). With
# neither, the DMG is signed but not notarized: Gatekeeper accepts the app inside, not the DMG, and the
# script says so at the end. Set SPARKLE_KEY_FILE to sign updates from a key file (sparkle-appcast.sh).
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
# Before anything is built: a placeholder update key means installed copies could never update.
# A build for trying the updater here may bring its own key; a shipped one never does.
unset NOLLIE_SPARKLE_PUBLIC_ED_KEY
python3 -I Tools/sparkle/sparkle_config.py check-release \
  || { echo "Not shipping: the app would not be able to update itself." >&2; exit 1; }
OUT="${1:-$ROOT/build/release/$(date +%Y%m%d-%H%M)}"
ARCHIVE="$OUT/Nollie.xcarchive"
EXPORT="$OUT/export"
NOTARIZED="$OUT/notarized"
mkdir -p "$OUT"
say() { printf '\n== %s\n' "$1"; }
NOTARY=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARY=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && [ -n "${ASC_KEY_PATH:-}" ]; then
  [ -f "$ASC_KEY_PATH" ] || { echo "There is no API key file at $ASC_KEY_PATH." >&2; exit 1; }
  NOTARY=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
fi

say "Archive"
xcodebuild -project Nollie.xcodeproj -scheme NollieMacDirect -configuration DirectRelease \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates archive > "$OUT/archive.log" 2>&1 \
  || { tail -20 "$OUT/archive.log"; exit 1; }

if [ -n "${NOTARY_PROFILE:-}" ]; then
  say "Export with Developer ID"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist Tools/release/ExportOptions-DeveloperID.plist -allowProvisioningUpdates > "$OUT/export.log" 2>&1
  say "Notarize with notarytool"
  ditto -c -k --keepParent "$EXPORT/Nollie.app" "$OUT/Nollie-upload.zip"
  xcrun notarytool submit "$OUT/Nollie-upload.zip" "${NOTARY[@]}" --wait
  xcrun stapler staple "$EXPORT/Nollie.app"
  mkdir -p "$NOTARIZED" && ditto "$EXPORT/Nollie.app" "$NOTARIZED/Nollie.app"
else
  say "Send to Apple through Xcode"
  UPLOAD_OPTIONS="$OUT/ExportOptions-upload.plist"
  sed 's#<string>export</string>#<string>upload</string>#' Tools/release/ExportOptions-DeveloperID.plist > "$UPLOAD_OPTIONS"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/upload" \
    -exportOptionsPlist "$UPLOAD_OPTIONS" -allowProvisioningUpdates > "$OUT/upload.log" 2>&1 \
    || { tail -20 "$OUT/upload.log"; exit 1; }
  say "Wait for notarization (usually minutes, sometimes hours)"
  for _ in $(seq 1 360); do
    rm -rf "$NOTARIZED"
    if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$NOTARIZED" > "$OUT/notarized.log" 2>&1; then break; fi
    if ! grep -q "not ready for distribution" "$OUT/notarized.log"; then tail -20 "$OUT/notarized.log"; exit 1; fi
    sleep 60
  done
fi

APP="$NOTARIZED/Nollie.app"
[ -d "$APP" ] || { echo "Notarization did not finish." >&2; exit 1; }

say "Check the app"
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv -t exec "$APP" > "$OUT/gatekeeper.txt" 2>&1 || true
cat "$OUT/gatekeeper.txt"
grep -q "source=Notarized Developer ID" "$OUT/gatekeeper.txt" || { echo "Gatekeeper did not accept the app." >&2; exit 1; }
for helper in "$APP/Contents/Helpers/Nollie Runtime.app" "$APP/Contents/Library/LoginItems/Nollie Notifications.app"; do
  signature=$(codesign -dvv "$helper" 2>&1)
  case "$signature" in *"Authority=Developer ID Application"*) ;; *) echo "Not Developer ID: $helper" >&2; exit 1 ;; esac
done
# Sparkle: signed by the same Developer ID as the rest, and the app carries the key and feed it should.
for part in "$APP/Contents/Frameworks/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate" \
            "$APP/Contents/Frameworks/Sparkle.framework/Versions/Current/Updater.app"; do
  [ -e "$part" ] || { echo "Sparkle is missing from the app: $part" >&2; exit 1; }
  signature=$(codesign -dvv "$part" 2>&1)
  case "$signature" in *"Authority=Developer ID Application"*) ;; *) echo "Not Developer ID: $part" >&2; exit 1 ;; esac
done
python3 -I Tools/sparkle/sparkle_config.py check-app "$APP" || { echo "The app's update settings are wrong." >&2; exit 1; }
entitlements=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)
if [[ "$entitlements" == *get-task-allow* ]]; then
  echo "The app still allows debugging." >&2; exit 1
fi

say "Make the DMG"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
STAGE="$OUT/dmg"
DMG="$OUT/Nollie-$VERSION-$BUILD.dmg"
rm -rf "$STAGE" "$DMG" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Nollie.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Nollie" -srcfolder "$STAGE" -format UDZO -fs APFS "$DMG" > /dev/null
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application: Corey Kozarski/ {print $2; exit}')
codesign --sign "$IDENTITY" --timestamp "$DMG"
if [ ${#NOTARY[@]} -gt 0 ]; then
  xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait
  xcrun stapler staple "$DMG"
fi
codesign --verify "$DMG"
DMG_NOTARIZED=""
spctl -a -t open --context context:primary-signature "$DMG" 2> /dev/null && DMG_NOTARIZED=yes
[ -n "$DMG_NOTARIZED" ] || [ ${#NOTARY[@]} -eq 0 ] || { echo "The DMG was sent to Apple but Gatekeeper does not accept it." >&2; exit 1; }
ditto -c -k --keepParent "$APP" "$OUT/Nollie-$VERSION-$BUILD.zip"
rm -rf "$STAGE"

say "Sign for Sparkle and write the appcast"
Tools/release/sparkle-appcast.sh "$OUT" \
  || { echo "The app, DMG and zip are made. Fix the above, then run: Tools/release/sparkle-appcast.sh \"$OUT\"" >&2; exit 1; }

say "Done"
echo "App: $APP"
echo "DMG: $DMG"
echo "Zip: $OUT/Nollie-$VERSION-$BUILD.zip"
echo "Appcast: $OUT/appcast.xml"
if [ -z "$DMG_NOTARIZED" ]; then
  echo
  echo "warning: the DMG is not notarized, so opening a downloaded copy shows a warning. Set NOTARY_PROFILE or" >&2
  echo "the ASC_KEY_* settings and run this again, or notarize and staple it by hand before it ships." >&2
fi
