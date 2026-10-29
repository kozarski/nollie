#!/usr/bin/env bash
# Builds Nollie and uploads it to TestFlight with no interactive steps.
#
# Signing goes through the Apple Account signed in to Xcode (Corey's), so every certificate carries his
# name; the key is never handed to Xcode, which would make its own "Created via API" certificate.
# Uploads use Corey's individual App Store Connect API key, so App Store Connect shows his name rather
# than "API user". Define the following in Tools/release/.env (git ignores that file) or export them:
#
#   ASC_APP_ID=<the app's ID in App Store Connect>
#   ASC_KEY_ID=ABCD123456                 # ID of the key
#   ASC_ISSUER_ID=aaaaaaaa-bbbb-....      # shown at the top of the keys screen
#   ASC_KEY_PATH=$HOME/.asc/keys/ApiKey_ABCD123456.p8
#   ASC_KEY_KIND=individual               # Corey's own key, from Edit Profile; leave out for a team key
#
# Two one-time chores that need a browser:
#   1. Accept any agreements that are waiting in your App Store Connect account.
#   2. Make an app record for the bundle id given below, named "Nollie App" ("Nollie" on its own is
#      taken; the icon still reads Nollie).
# Afterwards each build can go out unattended.
#
# Releasing the Mac app uses this script too, against the same app record:
#
#   env PLATFORM=macos bash Tools/release/testflight.sh
#
# On the Mac the script archives the NollieMac scheme, then exports a .pkg and uploads it as a Mac build.
# First add a macOS platform to the app record. Export signs automatically through Corey's Xcode account,
# which makes the App Store profiles and uses his installer certificate for the Mac.
#
# Set DRY_RUN=1 on either platform to stop once the export and its checks are done; nothing is uploaded.

set -e -u -o pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
if [ -f Tools/release/.env ]; then
    . Tools/release/.env
fi

PROJECT=Nollie.xcodeproj
RELEASE_DIR=Tools/release
ASC_API=https://api.appstoreconnect.apple.com/v1
BUNDLE_ID=com.coreykozarski.nollie
PLATFORM="${PLATFORM:-ios}"
BUILD_DIR="$ROOT/build"
ARCHIVE_DIR="${ARCHIVE_DIR:-$BUILD_DIR/archives}"

case "$PLATFORM" in
    ios)
        SCHEME="Nollie"; DESTINATION="generic/platform=iOS"
        EXPORT_OPTIONS="$RELEASE_DIR/ExportOptions.plist"; PREFIX="Nollie"
        PRODUCT_GLOB="*.ipa"; UPLOAD_TYPE="ios" ;;
    macos)
        SCHEME="NollieMac"; DESTINATION="generic/platform=macOS"
        EXPORT_OPTIONS="$RELEASE_DIR/ExportOptions-macOS.plist"; PREFIX="Nollie-mac"
        PRODUCT_GLOB="*.pkg"; UPLOAD_TYPE="macos" ;;
    *)
        printf 'PLATFORM has to be ios or macos (got %s)\n' "$PLATFORM" >&2
        exit 1 ;;
esac

die() { printf '\n%s\n' "$1" >&2; exit 1; }

# The key settings travel together to anything that talks to App Store Connect.
with_key() {
    ASC_KEY_ID="$ASC_KEY_ID" ASC_ISSUER_ID="$ASC_ISSUER_ID" ASC_KEY_PATH="$ASC_KEY_PATH" \
        ASC_KEY_KIND="${ASC_KEY_KIND:-}" "$@"
}

# --- Checks before anything is built ---------------------------------------------------------

for name in ASC_APP_ID ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do
    [ -n "${!name:-}" ] || die "$name is not set. See the top of this script."
done
[ -f "$ASC_KEY_PATH" ] || die "There is no API key file at $ASC_KEY_PATH"
with_key python3 Tools/release/release_guard.py app "$ASC_APP_ID"

# The project file holds the real version; Info.plist only has the $(MARKETING_VERSION) macro.
MARKETING_VERSION="${MARKETING_VERSION:-$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' "$PROJECT/project.pbxproj" | head -1)}"

# Each build number is one more than the biggest small number already recorded for this app in App
# Store Connect, which turns down any number it has seen. Early builds had date-style numbers (up to
# 2609240140), and those are skipped. BUILD_NUMBER overrides all of this.
next_build_number() {
    local token
    token="$(with_key swift Tools/release/asc-jwt.swift)" || return 1
    curl -sS --fail -H "Authorization: Bearer $token" \
        "$ASC_API/builds?filter%5Bapp%5D=$ASC_APP_ID&limit=200&fields%5Bbuilds%5D=version" |
    python3 -c '
import json, sys
held = [row["attributes"]["version"] for row in json.load(sys.stdin)["data"]]
small = [int(v) for v in held if v.isdigit() and int(v) < 100000]
print(max(small) + 1 if small else len(held) + 1)'
}

if [ -z "${BUILD_NUMBER:-}" ]; then
    BUILD_NUMBER="$(next_build_number)" ||
        die "Reading the existing builds from App Store Connect failed, so no build number could be chosen. Pass BUILD_NUMBER=<n> to set one yourself."
fi
[[ "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "BUILD_NUMBER must be a numeric build version."

ARCHIVE="$ARCHIVE_DIR/$PREFIX-$BUILD_NUMBER.xcarchive"
EXPORT_DIR="$ARCHIVE_DIR/export-$PREFIX-$BUILD_NUMBER"
LOG="$ARCHIVE_DIR/archive-$PREFIX-$BUILD_NUMBER.log"

for leftover in "$ARCHIVE" "$EXPORT_DIR"; do
    if [ -e "$leftover" ] || [ -L "$leftover" ]; then
        die "$(basename "$leftover") already exists. Use a new build number or move the old one."
    fi
done
mkdir -p "$ARCHIVE_DIR"

# Xcode signs with the account signed in to it. The API key is never passed here: given one, Xcode
# makes and uses its own "Created via API" development certificate.
SIGNING=()

# --- Archive ----------------------------------------------------------------------------------

echo "==> Archiving $BUNDLE_ID $MARKETING_VERSION (build $BUILD_NUMBER) for $PLATFORM"
if ! xcodebuild archive \
        -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
        -destination "$DESTINATION" -archivePath "$ARCHIVE" \
        -allowProvisioningUpdates ${SIGNING[@]+"${SIGNING[@]}"} \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" MARKETING_VERSION="$MARKETING_VERSION" \
        2>&1 | tee "$LOG" | awk '/error:|warning: .*(signing|provision)|ARCHIVE/'; then
    die "Archive failed. See the saved archive log. Nothing was exported or uploaded."
fi

python3 Tools/release/release_guard.py archive "$ARCHIVE" "$BUILD_NUMBER"

# A delegate method that only almost matches its protocol never gets called (once, a card's links
# opened within the chat because of such a method). No release may ship with that warning.
near_misses=$(grep -F "nearly matches" "$LOG" | grep -F "optional requirement" | sort -u || true)
if test -n "$near_misses"; then
    echo "$near_misses" >&2
    die "A delegate method doesn't match its protocol (shown above), so the system will never call it. Fix this before shipping."
fi

# --- Export and check --------------------------------------------------------------------------

echo "==> Exporting, signing for manual distribution"
export_archive() {
    local options=$1 destination=$2
    shift 2
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$options" -exportPath "$destination" "$@"
}
export_archive "$EXPORT_OPTIONS" "$EXPORT_DIR" -allowProvisioningUpdates

# Check the exported file's real signature and profile, not only what the project asked for.
PRODUCT=$(find "$EXPORT_DIR" -maxdepth 1 -name "$PRODUCT_GLOB")
count=$(printf '%s\n' "$PRODUCT" | grep -c . || true)
test "$count" -eq 1 || die "Expected exactly one exported product."
python3 Tools/release/release_guard.py export "$PRODUCT" "$PLATFORM" "$BUILD_NUMBER"

if [ "${DRY_RUN:-}" ]; then
    printf '\nDry run: %s passed identity and production signing checks. Nothing was uploaded.\n' "$PRODUCT"
    exit 0
fi

# --- Upload -------------------------------------------------------------------------------------

echo "==> Uploading to TestFlight"
upload_product() {
    local who=()
    # An individual key uploads as the person who made it; a team key shows as "API user".
    [ "${ASC_KEY_KIND:-}" = individual ] && who=(--api-key-subject user)
    xcrun altool --upload-app --api-issuer "$ASC_ISSUER_ID" --api-key "$ASC_KEY_ID" \
        --p8-file-path "$ASC_KEY_PATH" ${who[@]+"${who[@]}"} --file "$1" --type "$UPLOAD_TYPE"
}
upload_product "$PRODUCT"

# Then the App Store listing: attach this build (making the version if needed) and refresh the
# screenshots from Tools/release/screenshots. SKIP_LISTING=1 skips it. The script only knows the
# iOS version; the Mac listing is still kept by hand.
listing() { python3 Tools/release/asc-listing.py "$@"; }
if [ "$PLATFORM" = ios ] && [ -z "${SKIP_LISTING:-}" ]; then
    echo "==> Refreshing the App Store listing (build and screenshots)"
    if ! { listing attach "$MARKETING_VERSION" "$BUILD_NUMBER" && listing screenshots; }; then
        echo "(the listing update failed; run Tools/release/asc-listing.py yourself)"
    fi
fi

cat <<DONE

Uploaded build $BUILD_NUMBER of version $MARKETING_VERSION.

Apple now processes it, usually within a few minutes. Internal testers receive it as soon as
processing ends, with no review. Export compliance is already answered in Info.plist, so nothing
should be waiting on you.
DONE
