#!/bin/sh
# Puts Papertrail's network filter into the Direct edition, once Corey's developer portal has the
# Network Extensions capability and NOLLIE_NETWORK_FILTER_READY is YES. Until then it embeds nothing,
# and the client (store) edition never carries it.
set -eu

: "${CONFIGURATION:?}" "${BUILT_PRODUCTS_DIR:?}" "${TARGET_BUILD_DIR:?}" "${CONTENTS_FOLDER_PATH:?}"

. "$SRCROOT/Tools/runtime-helper/embedding-paths.sh"
build_root=$(embedding_directory "$TARGET_BUILD_DIR")
products_root=$(embedding_directory "$BUILT_PRODUCTS_DIR")
name="com.coreykozarski.nollie.network-filter.systemextension"
relative="$CONTENTS_FOLDER_PATH/Library/SystemExtensions/$name"
embedding_check_path "$build_root" "$relative"
embedded="$build_root/$relative"

case "$CONFIGURATION" in
  DirectDebug|DirectRelease) ;;
  *)
    if [ -e "$embedded" ] || [ -L "$embedded" ]; then
      echo "Unexpected network filter in the client edition. Use a clean build folder." >&2
      exit 1
    fi
    exit 0
    ;;
esac

if [ "${NOLLIE_NETWORK_FILTER_READY:-NO}" != "YES" ]; then
  /bin/rm -rf "$embedded"
  echo "Network filter not embedded: NOLLIE_NETWORK_FILTER_READY is not YES (the developer portal step is pending)."
  exit 0
fi

source=$(embedding_product "$products_root" "$name")
embedding_check_distinct "$source" "$embedded"
for required in "Contents/Info.plist" "Contents/MacOS/com.coreykozarski.nollie.network-filter"; do
  embedding_check_path "$source" "$required"
  if [ ! -f "$source/$required" ] || [ -L "$source/$required" ]; then
    echo "The built network filter is incomplete." >&2
    exit 1
  fi
done
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "YES" ] && ! /usr/bin/codesign --verify --strict "$source" >/dev/null 2>&1; then
  echo "The built network filter is not signed." >&2
  exit 1
fi

/bin/mkdir -p "$(/usr/bin/dirname "$embedded")"
/bin/rm -rf "$embedded"
/usr/bin/ditto "$source" "$embedded"
if ! /usr/bin/diff -qr "$source" "$embedded" >/dev/null; then
  echo "The embedded network filter differs from the built one." >&2
  exit 1
fi
echo "Embedded Papertrail's network filter."
