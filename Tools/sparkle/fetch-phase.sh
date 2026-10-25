#!/bin/sh
# Build phase ahead of compiling: make sure the pinned Sparkle is in the cache (Direct Mac edition only).
set -eu
case "${CONFIGURATION:?}" in
  DirectDebug|DirectRelease) "${SRCROOT:?}/Tools/sparkle/fetch-sparkle.sh" >/dev/null ;;
esac
