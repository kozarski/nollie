#!/bin/sh

embedding_fail() {
  echo "Unsafe helper packaging path. Use a clean build folder." >&2
  exit 1
}

embedding_directory() (
  [ -d "$1" ] || embedding_fail
  CDPATH= cd "$1" || embedding_fail
  /bin/pwd -P
)

# Trust the physical build root, including normal /var aliases, then reject links
# within the product. Nothing below the app may redirect removal or copying.
embedding_check_path() (
  embedding_current=$1
  embedding_relative=$2
  case "$embedding_relative" in
    ""|/*|.|..|./*|../*|*/./*|*/../*|*/.|*/..|*//*|*/) embedding_fail ;;
  esac
  set -f
  IFS=/
  for embedding_component in $embedding_relative; do
    embedding_current="$embedding_current/$embedding_component"
    [ ! -L "$embedding_current" ] || embedding_fail
  done
)

embedding_check_distinct() {
  case "$1/" in "$2/"*) embedding_fail ;; esac
  case "$2/" in "$1/"*) embedding_fail ;; esac
}

# A built helper inside the products folder. Archives leave a link there to Xcode's own
# uninstalled-products folder; that one link is followed, nothing else.
embedding_product() (
  embedding_root=$1
  embedding_name=$2
  embedding_candidate="$embedding_root/$embedding_name"
  if [ -L "$embedding_candidate" ]; then
    [ -n "${UNINSTALLED_PRODUCTS_DIR:-}" ] && [ -n "${PLATFORM_NAME:-}" ] || embedding_fail
    embedding_trusted=$(embedding_directory "$UNINSTALLED_PRODUCTS_DIR/$PLATFORM_NAME")
    embedding_resolved=$(embedding_directory "$embedding_candidate")
    [ "$embedding_resolved" = "$embedding_trusted/$embedding_name" ] || embedding_fail
    embedding_check_path "$embedding_trusted" "$embedding_name"
    echo "$embedding_resolved"
  else
    embedding_check_path "$embedding_root" "$embedding_name"
    echo "$embedding_candidate"
  fi
)
