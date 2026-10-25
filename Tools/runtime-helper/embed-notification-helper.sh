#!/bin/sh
set -eu

: "${CONFIGURATION:?}" "${BUILT_PRODUCTS_DIR:?}" "${TARGET_BUILD_DIR:?}" "${CONTENTS_FOLDER_PATH:?}"

. "$(/usr/bin/dirname "$0")/embedding-paths.sh"
build_root=$(embedding_directory "$TARGET_BUILD_DIR")
products_root=$(embedding_directory "$BUILT_PRODUCTS_DIR")
helper_relative="$CONTENTS_FOLDER_PATH/Library/LoginItems/Nollie Notifications.app"
embedding_check_path "$build_root" "$helper_relative"
helper="$build_root/$helper_relative"
case "$CONFIGURATION" in
  DirectDebug|DirectRelease) ;;
  *)
    if [ -e "$helper" ] || [ -L "$helper" ]; then
      echo "Unexpected background helper in the client edition. Use a clean build folder." >&2
      exit 1
    fi
    exit 0
    ;;
esac

source=$(embedding_product "$products_root" "Nollie Notifications.app")
embedding_check_distinct "$source" "$helper"
for required in "Contents/MacOS/Nollie Notifications" "Contents/Info.plist" "Contents/_CodeSignature/CodeResources"; do
  embedding_check_path "$source" "$required"
  if [ ! -f "$source/$required" ] || [ -L "$source/$required" ]; then
    echo "The built notification helper is incomplete." >&2
    exit 1
  fi
done
if [ "$source" = "$helper" ]; then
  echo "The notification helper packaging paths are invalid." >&2
  exit 1
fi

/bin/mkdir -p "$(/usr/bin/dirname "$helper")"
/bin/rm -rf "$helper"
/usr/bin/ditto "$source" "$helper"
if ! /usr/bin/diff -qr "$source" "$helper" >/dev/null; then
  echo "The embedded notification helper differs from the built artifact." >&2
  exit 1
fi
echo "Verified embedded Nollie Notifications matches the built helper."
