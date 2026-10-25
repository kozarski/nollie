#!/bin/sh
# Copy the Setup Kit (Nollie's reviewed Hermes changes and its own add-ons, Tools/dev/setup-kit.py)
# into Contents/Resources/Setup Kit, in the Direct Mac edition only. Runs on every build, so the
# app never carries an older kit than its source. The app checks every file by SHA-256 before use.
set -eu

: "${CONFIGURATION:?}" "${TARGET_BUILD_DIR:?}" "${CONTENTS_FOLDER_PATH:?}" "${SRCROOT:?}"

. "$SRCROOT/Tools/runtime-helper/embedding-paths.sh"
build_root=$(embedding_directory "$TARGET_BUILD_DIR")
kit_relative="$CONTENTS_FOLDER_PATH/Resources/Setup Kit"
embedding_check_path "$build_root" "$kit_relative"
kit="$build_root/$kit_relative"

case "$CONFIGURATION" in
  DirectDebug|DirectRelease) ;;
  *)
    if [ -e "$kit" ] || [ -L "$kit" ]; then
      echo "Unexpected Setup Kit in the client edition. Use a clean build folder." >&2
      exit 1
    fi
    exit 0
    ;;
esac

/bin/mkdir -p "$(/usr/bin/dirname "$kit")"
/usr/bin/python3 -I "$SRCROOT/Tools/dev/setup-kit.py" "$kit"
# The overlay the app carries must be the one its code expects.
expected=$(/usr/bin/sed -n 's/.*static let hermesOverlayDigest = "\([0-9a-f]\{64\}\)".*/\1/p' \
  "$SRCROOT/Apps/Nollie/Connect/NativeDependencyInstaller.swift")
actual=$(/usr/bin/shasum -a 256 "$kit/hermes-overlay/overlay.json" | /usr/bin/awk '{print $1}')
if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
  echo "error: Services/Runtime/HermesOverlay does not match NativeSetupPlan.hermesOverlayDigest." >&2
  exit 1
fi
echo "Embedded the Setup Kit (overlay $actual)."
