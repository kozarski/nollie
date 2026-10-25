#!/usr/bin/env bash
# Companions/hermes-push is the source. The app bundles a copy of the script, the installer and the
# plugin files (a unit test checks they match). Run this after changing any of them.
set -e
cd "$(dirname "$0")/.."
src=Companions/hermes-push
dest=Apps/Nollie/Resources/hermes-push
mkdir -p "$dest/plugin"
cp "$src/hermes_push.py" "$src/install.sh" "$dest/"
cp "$src/plugin/nollie-push/plugin.yaml" "$src/plugin/nollie-push/__init__.py" "$dest/plugin/"
echo synced
