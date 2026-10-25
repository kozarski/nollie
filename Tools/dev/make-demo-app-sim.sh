#!/bin/bash
# Puts the demo version of the iPhone app onto a simulator that is already booted.
#
# The installed app is a Debug simulator build under a bundle id of its own, signed ad hoc and
# stripped of its extensions. Just like the Mac demo version (make-demo-app.sh), it has settings
# of its own and keeps credentials only in memory (the logic is in Apps/Nollie/App/DemoMode.swift), which makes
# it safe to point at the mock gateway and to film.
#
#   usage: make-demo-app-sim.sh <built Nollie.app (Debug, simulator)> <simulator udid>
#
# After starting the mock gateway (mock_gateway.py from Tools/mock-gateway, given --port and
# --token), launch the demo copy like this:
#   xcrun simctl launch <udid> com.coreykozarski.nollie.demo \
#       -nollie-demo-gateway <gateway url> <token> <label>
# Adding -companionPromptShown YES hides the Companion prompt for a recording. Every run begins
# from scratch, because any earlier install is removed first.
set -eu -o pipefail

fail() { echo "$1" >&2; exit 1; }

BUILT_APP=${1:?path to the Debug simulator Nollie.app}
SIMULATOR=${2:?simulator udid}
DEMO_ID=com.coreykozarski.nollie.demo

test -d "$BUILT_APP" || fail "no app at $BUILT_APP"
LC_ALL=C grep -qa -- "-nollie-demo-gateway" "$BUILT_APP/Nollie" \
    || fail "that build lacks demo mode, so it has to be a Debug build"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
copy=$workdir/Nollie.app
cp -R "$BUILT_APP" "$copy"

plist_set() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "$copy/Info.plist"; }

# Extensions are tied to the real bundle id, so leave them out.
rm -rf "$copy/PlugIns" "$copy/_CodeSignature"
plist_set CFBundleIdentifier "$DEMO_ID"
plist_set CFBundleName "Nollie Demo"
plist_set CFBundleDisplayName "Nollie Demo"
codesign -f --deep -s - "$copy" 2>/dev/null

# A fresh start: whatever is installed under the demo id goes first.
simctl_quietly() { xcrun simctl "$@" >/dev/null 2>&1 || true; }
simctl_quietly terminate "$SIMULATOR" "$DEMO_ID"
simctl_quietly uninstall "$SIMULATOR" "$DEMO_ID"
xcrun simctl install "$SIMULATOR" "$copy"
printf '%s installed on %s\n' "$DEMO_ID" "$SIMULATOR"
