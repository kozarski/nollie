#!/bin/bash
# Makes fixtures/live-desktop.hevclive, the picture the mock gateway's /nollie/live replays: four
# seconds of a synthetic desktop at 1280x800 and 15 fps. live-fixture/main.swift draws it and
# NollieCore's own LiveEncoder and LiveWire encode and frame it (no second copy of either).
# Needs VideoToolbox, so run it outside any sandbox. The result is checked in; make it again
# after a change to the wire format or the encoder.
#
#   Tools/mock-gateway/make-live-fixture.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
live="$here/../../Packages/NollieCore/Sources/NollieCore/Live"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

xcrun swiftc -O -parse-as-library -swift-version 6 -module-name LiveFixture -o "$work/live-fixture" \
  "$here/live-fixture/main.swift" \
  "$live/LiveWire.swift" "$live/LiveMailbox.swift" "$live/LiveQuality.swift" "$live/LiveEncoder.swift"
mkdir -p "$here/fixtures"
"$work/live-fixture" "$here/fixtures/live-desktop.hevclive"
