#!/bin/sh
# Embed and sign Nollie Computer (the pinned Cua Driver build) as
# Contents/Helpers/Nollie Computer, with its notices, in the Direct Mac edition only.
# A bare executable, not an app: it has no identity of its own, so macOS charges its
# Accessibility and Screen Recording use to Nollie (Docs/nollie-computer.md).
set -eu

: "${CONFIGURATION:?}" "${TARGET_BUILD_DIR:?}" "${CONTENTS_FOLDER_PATH:?}" "${SRCROOT:?}"

. "$SRCROOT/Tools/runtime-helper/embedding-paths.sh"
build_root=$(embedding_directory "$TARGET_BUILD_DIR")
helper_relative="$CONTENTS_FOLDER_PATH/Helpers/Nollie Computer"
notices_relative="$CONTENTS_FOLDER_PATH/Resources/Notices/Nollie Computer"
embedding_check_path "$build_root" "$helper_relative"
embedding_check_path "$build_root" "$notices_relative"
helper="$build_root/$helper_relative"
notices="$build_root/$notices_relative"

case "$CONFIGURATION" in
  DirectDebug|DirectRelease) ;;
  *)
    if [ -e "$helper" ] || [ -L "$helper" ] || [ -e "$notices" ]; then
      echo "Unexpected Nollie Computer in the client edition. Use a clean build folder." >&2
      exit 1
    fi
    exit 0
    ;;
esac

here="$SRCROOT/Tools/computer-helper"
if ! built=$("$here/build-driver.sh" --check); then
  if [ "$CONFIGURATION" = DirectRelease ]; then
    echo "error: Nollie Computer is not built. Run Tools/computer-helper/build-driver.sh." >&2
    exit 1
  fi
  echo "warning: Nollie Computer is not built, so this build can't use the Mac. Run Tools/computer-helper/build-driver.sh."
  /bin/rm -rf "$helper" "$notices"
  exit 0
fi
out=$(/usr/bin/dirname "$built")

/bin/mkdir -p "$(/usr/bin/dirname "$helper")" "$notices"
/bin/rm -f "$helper"
/bin/cp "$built" "$helper"
/bin/chmod 755 "$helper"
. "$here/pin.env"
if [ "$(/usr/bin/shasum -a 256 "$helper" | /usr/bin/awk '{print $1}')" != "$DRIVER_BINARY_SHA256" ]; then
  echo "The embedded Nollie Computer differs from the pinned build." >&2
  exit 1
fi
/bin/cp "$here/NOTICE.txt" "$notices/NOTICE.txt"
/bin/cp "$out/LICENSE.md" "$notices/Cua-Driver-LICENSE.txt"
/bin/cp "$out/Cua-Driver-THIRD_PARTY_NOTICES.md" "$notices/Cua-Driver-THIRD_PARTY_NOTICES.md"
/bin/cp "$out/THIRD_PARTY_NOTICES.txt" "$notices/THIRD_PARTY_NOTICES.txt"

# Inside out: the helper is signed here, the app after this phase. Same team, hardened runtime,
# its own identifier under Nollie's, and the two entitlements the driver needs.
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
timestamp="--timestamp=none"
case "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" in "Developer ID Application"*) timestamp="--timestamp" ;; esac
/usr/bin/codesign --force --options runtime $timestamp \
  --identifier "${PRODUCT_BUNDLE_IDENTIFIER:-com.coreykozarski.nollie}.computer" \
  --entitlements "$here/NollieComputer.entitlements" \
  --sign "$identity" "$helper"
/usr/bin/codesign --verify --strict "$helper"
echo "Embedded and signed Nollie Computer ($DRIVER_BINARY_SHA256)."
