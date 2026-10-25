#!/bin/bash
# Fetch the pinned Sparkle release (Tools/sparkle/pin.env) into a cache outside the checkout.
#
#   Tools/sparkle/fetch-sparkle.sh           download if needed, check, and print the folder
#   Tools/sparkle/fetch-sparkle.sh --check   only report whether it is already there (exit 0 or 1)
#
# The folder holds Sparkle.xcframework (what the Direct Mac edition links) and bin/ (the key,
# signing and appcast tools the release uses). Nothing is used until its size and SHA-256 match the pin.
# The cache is safe to delete. NOLLIE_SPARKLE_CACHE moves it (the Xcode project looks in the default).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=pin.env
. "$here/pin.env"
cache="${NOLLIE_SPARKLE_CACHE:-$HOME/Library/Caches/Nollie/sparkle}"
dir="$cache/$SPARKLE_VERSION"
framework="$dir/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

ready() {
  [ -d "$framework" ] && [ -x "$dir/bin/sign_update" ] && [ -x "$dir/bin/generate_appcast" ] &&
    [ -x "$dir/bin/generate_keys" ] && [ -f "$dir/LICENSE" ] &&
    [ "$(/bin/cat "$dir/.sha256" 2>/dev/null)" = "$SPARKLE_SHA256" ]
}

if [ "${1:-}" = "--check" ]; then
  ready && { echo "$dir"; exit 0; }
  exit 1
fi
if [ -z "${NOLLIE_SPARKLE_LOCKED:-}" ]; then
  /bin/mkdir -p "$cache"
  NOLLIE_SPARKLE_LOCKED=1 exec /usr/bin/lockf -t 600 "$cache/.fetch.lock" "$0" "$@"
fi
if ready; then
  echo "$dir"
  exit 0
fi

work=$(/usr/bin/mktemp -d "$cache/.fetch.XXXXXX")
trap '/bin/rm -rf "$work"' EXIT
echo "Fetching Sparkle $SPARKLE_VERSION" >&2
/usr/bin/curl --fail --silent --show-error --location --proto '=https' --max-time 300 \
  --output "$work/sparkle.zip" "$SPARKLE_URL"
size=$(/usr/bin/stat -f %z "$work/sparkle.zip")
sum=$(/usr/bin/shasum -a 256 "$work/sparkle.zip" | /usr/bin/awk '{print $1}')
if [ "$size" != "$SPARKLE_BYTES" ] || [ "$sum" != "$SPARKLE_SHA256" ]; then
  echo "error: the Sparkle download does not match its pinned size and SHA-256 (Tools/sparkle/pin.env)." >&2
  exit 1
fi
# ditto keeps the framework's symbolic links, which an ordinary unzip may not.
/usr/bin/ditto -x -k "$work/sparkle.zip" "$work/out"
/bin/rm -rf "$dir"
/bin/mv "$work/out" "$dir"
printf '%s\n' "$SPARKLE_SHA256" > "$dir/.sha256"
ready || { echo "error: the Sparkle download is missing a part." >&2; exit 1; }
echo "$dir"
