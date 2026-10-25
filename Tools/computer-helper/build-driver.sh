#!/bin/bash
# Build the Nollie Computer helper from the pinned Cua Driver source (Tools/computer-helper/pin.env).
#
# Everything lives in a cache outside the checkout (rebuildable, safe to delete):
#   $NOLLIE_COMPUTER_CACHE (default ~/Library/Caches/Nollie/computer-helper)
#     rust-<version>/   the pinned Rust release, checked against its SHA-256
#     source/           a sparse clone of the tag, checked against its commit and tree ids
#     crates/           every locked crate, checked against Cargo.lock
#     out/<tag>/        "Nollie Computer", its .sha256, and the driver's licence files
#
# Optional seeds that skip downloads (each is still checked): NOLLIE_RUST_ARCHIVE (the Rust
# .tar.xz) and NOLLIE_CRATE_SEED (a folder of .crate files).
# Never touches ~/.cargo, ~/.rustup, ~/.cua, ~/.cua-driver or any installed Cua Driver.
#
# --check   only report whether the pinned helper is already built (exit 0) or not (exit 1).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=pin.env
. "$here/pin.env"
cache="${NOLLIE_COMPUTER_CACHE:-$HOME/Library/Caches/Nollie/computer-helper}"
out="$cache/out/$DRIVER_TAG"
binary="$out/Nollie Computer"

# Which pin a build came from: a changed pin (a new tag, commit or Rust) never reuses an old binary.
pin_stamp=$(/usr/bin/shasum -a 256 "$here/pin.env" | /usr/bin/awk '{print $1}')

# The binary must hash to the value pinned in pin.env, not just to a note the cache wrote itself.
built() {
  [ -f "$binary" ] && [ -f "$out/THIRD_PARTY_NOTICES.txt" ] &&
    [ "$(/bin/cat "$out/pin.sha256" 2>/dev/null)" = "$pin_stamp" ] &&
    [ "$(/usr/bin/shasum -a 256 "$binary" | /usr/bin/awk '{print $1}')" = "$DRIVER_BINARY_SHA256" ]
}

if [ "${1:-}" = "--check" ]; then
  built && { echo "$binary"; exit 0; }
  exit 1
fi
# One build at a time per cache: worktrees side by side share it, and two pins building into
# one source folder at once each get the other's files.
if [ -z "${NOLLIE_COMPUTER_LOCKED:-}" ]; then
  /bin/mkdir -p "$cache"
  NOLLIE_COMPUTER_LOCKED=1 exec /usr/bin/lockf -t 3600 "$cache/.build.lock" "$0" "$@"
fi
if built; then
  echo "Already built: $binary"
  exit 0
fi

check_sha256() {
  [ "$(/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}')" = "$2" ] || { echo "Checksum mismatch: $1" >&2; exit 1; }
}

/bin/mkdir -p "$cache"
/bin/chmod 700 "$cache"

# 1. Rust, the exact release the driver pins.
rust="$cache/rust-$RUST_VERSION"
if [ ! -x "$rust/bin/cargo" ]; then
  archive="$cache/$RUST_ARCHIVE"
  if [ -n "${NOLLIE_RUST_ARCHIVE:-}" ]; then
    /bin/cp "$NOLLIE_RUST_ARCHIVE" "$archive"
  fi
  # A partial or tampered download is fetched again once, then refused.
  for attempt in 1 2; do
    [ -f "$archive" ] || /usr/bin/curl -fL --proto '=https' --tlsv1.2 -o "$archive" "$RUST_URL"
    [ "$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')" = "$RUST_SHA256" ] && break
    /bin/rm -f "$archive"
    [ "$attempt" = 2 ] && { echo "Checksum mismatch: $RUST_ARCHIVE" >&2; exit 1; }
  done
  unpack="$cache/rust-unpack"
  /bin/rm -rf "$unpack" && /bin/mkdir -p "$unpack"
  /usr/bin/tar -xJf "$archive" -C "$unpack"
  "$unpack/${RUST_ARCHIVE%.tar.xz}/install.sh" --prefix="$rust" \
    --components=rustc,cargo,rust-std-aarch64-apple-darwin --disable-ldconfig >/dev/null
  /bin/rm -rf "$unpack"
fi
"$rust/bin/cargo" --version | /usr/bin/grep -q " $RUST_VERSION " || { echo "Unexpected cargo version" >&2; exit 1; }

# 2. Source: only the driver workspace, the telemetry crate it links, and the licence files.
source="$cache/source"
source_matches() {
  [ "$(/usr/bin/git -C "$source" rev-parse HEAD 2>/dev/null)" = "$DRIVER_COMMIT" ] &&
    [ -z "$(/usr/bin/git -C "$source" status --porcelain 2>/dev/null)" ]
}
# A clone of another pin (or a damaged one) is replaced, never reused.
if [ -d "$source" ] && ! source_matches; then
  /bin/rm -rf "$source"
fi
if [ ! -d "$source/.git" ]; then
  /usr/bin/git clone --quiet --depth 1 --branch "$DRIVER_TAG" --filter=blob:none --no-checkout "$DRIVER_REPO" "$source"
  /usr/bin/git -C "$source" sparse-checkout set --no-cone /LICENSE.md /LICENSING.md /TRADEMARKS.md \
    /THIRD_PARTY_NOTICES.md /.cargo/ /libs/cua-driver/rust/ /libs/cua/crates/cua-telemetry/ /libs/cua/Cargo.toml \
    /libs/images/sandbox-images.json /libs/cua/crates/cua-teleport/src/ux/targets.json
  /usr/bin/git -C "$source" checkout --quiet "$DRIVER_COMMIT"
fi
[ "$(/usr/bin/git -C "$source" rev-parse HEAD)" = "$DRIVER_COMMIT" ] || { echo "Source is not the pinned commit" >&2; exit 1; }
[ "$(/usr/bin/git -C "$source" rev-parse HEAD:libs/cua-driver/rust)" = "$DRIVER_TREE" ] || { echo "Driver tree mismatch" >&2; exit 1; }
[ "$(/usr/bin/git -C "$source" rev-parse HEAD:libs/cua/crates/cua-telemetry)" = "$TELEMETRY_TREE" ] || { echo "Telemetry tree mismatch" >&2; exit 1; }
[ -z "$(/usr/bin/git -C "$source" status --porcelain)" ] || { echo "Source has local changes" >&2; exit 1; }
workspace="$source/libs/cua-driver/rust"
check_sha256 "$workspace/Cargo.lock" "$DRIVER_LOCK_SHA256"
# Cargo reads .cargo/config files in every folder above the build: none may exist but the source's own.
dir="$workspace"
while [ "$dir" != "/" ]; do
  dir=$(/usr/bin/dirname "$dir")
  case "$dir" in "$source"|"$source"/*) continue ;; esac
  if [ -e "$dir/.cargo/config.toml" ] || [ -e "$dir/.cargo/config" ]; then
    echo "A Cargo config at $dir/.cargo would change this build. Move it aside, or set NOLLIE_COMPUTER_CACHE outside $dir." >&2
    exit 1
  fi
done

# 3. Crates, fetched with curl (cargo's own network access is not needed) and checked.
/usr/bin/python3 -I "$here/vendor-crates.py" "$workspace/Cargo.lock" "$cache/crates" ${NOLLIE_CRATE_SEED:+"$NOLLIE_CRATE_SEED"}

# 4. Build offline, exactly the locked graph.
# A clean environment, so a build from Xcode (which exports its own SDK and deployment
# settings) and one from Terminal produce the same binary.
# The crates source and offline mode go on the command line, and the flags and target folder in
# the environment, so they outrank any Cargo config a person keeps in their home folder.
cargo() {
  /usr/bin/env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" LANG=en_US.UTF-8 \
    PATH="$rust/bin:/usr/bin:/bin:/usr/sbin:/sbin" CARGO_HOME="$cache/cargo-home" CARGO_TARGET_DIR="$cache/target" \
    CARGO_ENCODED_RUSTFLAGS="--remap-path-prefix=$cache=/nollie-computer$(printf '\037')--remap-path-prefix=$HOME=/home" \
    CARGO_BUILD_RUSTC_WRAPPER= CARGO_PROFILE_RELEASE_STRIP=none CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP=none \
    "$rust/bin/cargo" --config 'source.crates-io.replace-with="vendored"' \
    --config "source.vendored.directory=\"$cache/crates\"" --config 'net.offline=true' "$@"
}
/bin/mkdir -p "$cache/cargo-home"
/bin/rm -f "$cache/cargo-home/config.toml"
# Symbols stay in (STRIP=none above): the system strip on macOS 27.2 writes dylibs dyld rejects
# when a deployment target is set, which breaks proc macros. See Docs/nollie-computer.md.
(cd "$workspace" && cargo build -p cua-driver --release --locked --offline --target aarch64-apple-darwin)

/bin/mkdir -p "$out"
/bin/cp "$cache/target/aarch64-apple-darwin/release/cua-driver" "$binary"
/bin/cp "$source/LICENSE.md" "$out/LICENSE.md"
/bin/cp "$workspace/THIRD_PARTY_NOTICES.md" "$out/Cua-Driver-THIRD_PARTY_NOTICES.md"
# Every crate linked into the helper, with its licence text. Stops on anything unexpected.
(cd "$workspace" && cargo tree -p cua-driver --target aarch64-apple-darwin -e normal,build --prefix none --offline --locked) > "$out/crates.txt"
/usr/bin/python3 -I "$here/third-party-notices.py" "$out/crates.txt" "$cache/crates" "$workspace/crates" "$out"
got=$(/usr/bin/shasum -a 256 "$binary" | /usr/bin/awk '{print $1}')
echo "$got" > "$binary.sha256"
if [ "$got" != "$DRIVER_BINARY_SHA256" ]; then
  echo "The build is $got, not the pinned $DRIVER_BINARY_SHA256. After a deliberate pin change, record the new hash in pin.env." >&2
  exit 1
fi
echo "$pin_stamp" > "$out/pin.sha256"
echo "Built: $binary"
