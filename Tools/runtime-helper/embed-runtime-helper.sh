#!/bin/sh
set -eu

: "${CONFIGURATION:?}" "${BUILT_PRODUCTS_DIR:?}" "${TARGET_BUILD_DIR:?}" "${CONTENTS_FOLDER_PATH:?}" "${SRCROOT:?}"

. "$(/usr/bin/dirname "$0")/embedding-paths.sh"
build_root=$(embedding_directory "$TARGET_BUILD_DIR")
products_root=$(embedding_directory "$BUILT_PRODUCTS_DIR")
source_root=$(embedding_directory "$SRCROOT")
helper_relative="$CONTENTS_FOLDER_PATH/Helpers/Nollie Runtime.app"
agent_relative="$CONTENTS_FOLDER_PATH/Library/LaunchAgents/com.coreykozarski.nollie.runtime.plist"
embedding_check_path "$build_root" "$helper_relative"
embedding_check_path "$build_root" "$agent_relative"
helper="$build_root/$helper_relative"
agent="$build_root/$agent_relative"

case "$CONFIGURATION" in
  DirectDebug|DirectRelease) ;;
  *)
    if [ -e "$helper" ] || [ -L "$helper" ] || [ -e "$agent" ] || [ -L "$agent" ]; then
      echo "Unexpected local runtime in the client edition. Use a clean build folder." >&2
      exit 1
    fi
    exit 0
    ;;
esac

source=$(embedding_product "$products_root" "Nollie Runtime.app")
embedding_check_distinct "$source" "$helper"
entry="Contents/Resources/runtime_entry.py"
addons="Contents/Resources/managed_addons.py"
embedding_check_path "$source_root" "Services/Runtime/com.coreykozarski.nollie.runtime.plist.template"
embedding_check_path "$source_root" "Services/Runtime/runtime_entry.py"
embedding_check_path "$source_root" "Services/Runtime/managed_addons.py"
template="$source_root/Services/Runtime/com.coreykozarski.nollie.runtime.plist.template"
for required in "Contents/MacOS/Nollie Runtime" "Contents/Info.plist" "Contents/_CodeSignature/CodeResources" "$entry" "$addons"; do
  embedding_check_path "$source" "$required"
  if [ ! -f "$source/$required" ] || [ -L "$source/$required" ]; then
    echo "The built runtime helper is incomplete." >&2
    exit 1
  fi
done
if ! /usr/bin/cmp -s "$source_root/Services/Runtime/runtime_entry.py" "$source/$entry"; then
  echo "The built runtime entry point does not match the current source." >&2
  exit 1
fi
if ! /usr/bin/cmp -s "$source_root/Services/Runtime/managed_addons.py" "$source/$addons"; then
  echo "The built runtime add-on helper does not match the current source." >&2
  exit 1
fi
if [ ! -f "$template" ] || [ -L "$template" ] || [ "$source" = "$helper" ]; then
  echo "The runtime helper packaging paths are invalid." >&2
  exit 1
fi

/bin/mkdir -p "$(/usr/bin/dirname "$helper")" "$(/usr/bin/dirname "$agent")"
/bin/rm -rf "$helper"
/usr/bin/ditto "$source" "$helper"
/bin/rm -f "$agent"
/bin/cp "$template" "$agent"

# Compare the whole signed bundle, including executable, resources and signature seal.
if ! /usr/bin/diff -qr "$source" "$helper" >/dev/null || ! /usr/bin/cmp -s "$template" "$agent"; then
  echo "The embedded runtime helper differs from the built artifact." >&2
  exit 1
fi
echo "Verified embedded Nollie Runtime matches the built helper and current entry point."
