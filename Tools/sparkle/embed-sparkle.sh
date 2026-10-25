#!/bin/sh
# Embed Sparkle in the Direct Mac edition only: the framework (signed here, inside out, with the
# build's own identity), Sparkle's licence, and the update settings in the app's Info.plist.
# The store edition carries none of it, and refuses to build on top of leftovers from a Direct build.
set -eu

: "${CONFIGURATION:?}" "${TARGET_BUILD_DIR:?}" "${CONTENTS_FOLDER_PATH:?}" "${FRAMEWORKS_FOLDER_PATH:?}" \
  "${INFOPLIST_PATH:?}" "${SRCROOT:?}"

. "$SRCROOT/Tools/runtime-helper/embedding-paths.sh"
build_root=$(embedding_directory "$TARGET_BUILD_DIR")
framework_relative="$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
notices_relative="$CONTENTS_FOLDER_PATH/Resources/Notices/Sparkle"
embedding_check_path "$build_root" "$framework_relative"
embedding_check_path "$build_root" "$notices_relative"
embedding_check_path "$build_root" "$INFOPLIST_PATH"
framework="$build_root/$framework_relative"
notices="$build_root/$notices_relative"
plist="$build_root/$INFOPLIST_PATH"
here="$SRCROOT/Tools/sparkle"
buddy=/usr/libexec/PlistBuddy

case "$CONFIGURATION" in
  DirectDebug|DirectRelease) ;;
  *)
    if [ -e "$framework" ] || [ -L "$framework" ] || [ -e "$notices" ] || "$buddy" -c "Print :SUFeedURL" "$plist" >/dev/null 2>&1; then
      echo "Unexpected updater in the client edition. Use a clean build folder." >&2
      exit 1
    fi
    exit 0
    ;;
esac

source=$("$here/fetch-sparkle.sh") || { echo "error: Sparkle is not available. Run Tools/sparkle/fetch-sparkle.sh." >&2; exit 1; }
. "$here/pin.env"
. "$here/update-feed.env"
# A build for trying the updater on this Mac can bring its own public key. Shipping ignores it.
key="${NOLLIE_SPARKLE_PUBLIC_ED_KEY:-$SPARKLE_PUBLIC_ED_KEY}"

# Identity and pin make the stamp: the same ones again need no new copy (and no new signature on the app).
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
timestamp="--timestamp=none"
case "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" in "Developer ID Application"*) timestamp="--timestamp" ;; esac
stamp_file="${TEMP_DIR:-$build_root}/sparkle-embedded.stamp"
stamp="$SPARKLE_SHA256 $identity $timestamp"
if [ "$(/bin/cat "$stamp_file" 2>/dev/null)" != "$stamp" ] || ! /usr/bin/codesign --verify --deep --strict "$framework" 2>/dev/null \
   || [ ! -f "$notices/LICENSE" ]; then
  /bin/mkdir -p "$(/usr/bin/dirname "$framework")" "$notices"
  /bin/rm -rf "$framework"
  /usr/bin/ditto "$source/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$framework"
  # Nollie is not sandboxed, so Sparkle's helper services for sandboxed apps have nothing to do.
  /bin/rm -rf "$framework/Versions/Current/XPCServices" "$framework/XPCServices"
  /bin/cp "$source/LICENSE" "$notices/LICENSE"

  # Inside out, with the hardened runtime, under the same team as the app (so macOS lets the app load it).
  for part in "$framework/Versions/Current/Autoupdate" "$framework/Versions/Current/Updater.app" "$framework"; do
    /usr/bin/codesign --force --options runtime $timestamp --sign "$identity" "$part"
  done
  /usr/bin/codesign --verify --deep --strict "$framework"
  printf '%s' "$stamp" > "$stamp_file"
fi

# Only touch the Info.plist when a value differs, so an unchanged build keeps an unchanged signature.
set_key() { # name type value, with the value as PlistBuddy prints it
  [ "$("$buddy" -c "Print :$1" "$plist" 2>/dev/null || true)" = "$3" ] && return 0
  "$buddy" -c "Delete :$1" "$plist" >/dev/null 2>&1 || true
  "$buddy" -c "Add :$1 $2 $3" "$plist"
}
set_key SUFeedURL string "$SPARKLE_FEED_URL"
set_key SUPublicEDKey string "$key"
set_key SUEnableAutomaticChecks bool true
set_key SUScheduledCheckInterval integer 86400
set_key SUAllowsAutomaticUpdates bool false
set_key SUVerifyUpdateBeforeExtraction bool true
echo "Embedded and signed Sparkle $SPARKLE_VERSION."
