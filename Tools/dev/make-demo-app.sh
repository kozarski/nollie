#!/bin/bash
# Turns a Debug build of the Mac app into its demo version.
#
# What comes out is the same program under a bundle id of its own, signed ad hoc and without
# extensions. It has settings of its own and keeps credentials only in memory (the logic is in
# Apps/Nollie/App/DemoMode.swift), so it can be pointed at the mock gateway and recorded with none
# of your real gateways or chats in view.
#
#   usage: make-demo-app.sh <Debug Nollie.app> <output folder>
#
# After starting the mock gateway (mock_gateway.py from Tools/mock-gateway, given --port and
# --token), launch the result like this:
#   <output folder>/Nollie.app/Contents/MacOS/Nollie \
#       -nollie-demo-gateway <gateway url> <token> <label>
# Its settings live in the preferences domain com.coreykozarski.nollie.demo, and running `defaults delete`
# on that domain resets them.
set -eu -o pipefail

fail() { echo "$1" >&2; exit 1; }

BUILT_APP=${1:?path to the Debug Nollie.app}
DEST=${2:?output folder}
DEMO_ID=com.coreykozarski.nollie.demo

test -d "$BUILT_APP" || fail "no app at $BUILT_APP"
LC_ALL=C grep -qra -- "-nollie-demo-gateway" "$BUILT_APP/Contents/MacOS" \
    || fail "that build lacks demo mode, so it has to be a Debug build"

copy=$DEST/Nollie.app
rm -rf "$copy"
mkdir -p "$DEST"
cp -R "$BUILT_APP" "$copy"

contents=$copy/Contents
plist_set() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "$contents/Info.plist"; }

# Extensions, login items and the signing profile belong to the real bundle identity.
(cd "$contents" && rm -rf PlugIns Library/LoginItems embedded.provisionprofile _CodeSignature)
plist_set CFBundleIdentifier "$DEMO_ID"
plist_set CFBundleName "Nollie Demo"
plist_set CFBundleDisplayName "Nollie Demo"

# Signed ad hoc, no entitlements at all: no sandbox, keychain group, iCloud or push.
codesign -f --deep -s - "$copy" 2>/dev/null
codesign -v --deep "$copy"
printf '%s (%s)\n' "$copy" "$DEMO_ID"
