#!/bin/bash
# One time only: make the key that signs Nollie's updates, and tell the app which key to trust.
#
#   Tools/release/sparkle-keys.sh                  make the key (or find the one you have) and write its public half
#   Tools/release/sparkle-keys.sh --backup FILE    also save the private key to FILE, for 1Password
#   Tools/release/sparkle-keys.sh --replace        write a different public key over a real one (breaks updates for apps already out)
#
# Sparkle's generate_keys keeps the private key in your login keychain; macOS may ask whether to allow
# it. The public key goes into Tools/sparkle/update-feed.env, which the Direct build puts in the app.
# The private key never leaves the keychain unless you ask for --backup. Nothing is printed of it.
set -euo pipefail
cd "$(dirname "$0")/../.."

backup=""
replace=""
while [ $# -gt 0 ]; do
  case "$1" in
    --backup) backup="${2:?--backup needs a file name}"; shift 2 ;;
    --replace) replace="--replace"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

tools=$(Tools/sparkle/fetch-sparkle.sh)
if public=$("$tools/bin/generate_keys" -p 2>/dev/null) && [ -n "$public" ]; then
  echo "Found the update key already in your login keychain."
else
  "$tools/bin/generate_keys" > /dev/null
  public=$("$tools/bin/generate_keys" -p)
fi
public=$(printf '%s' "$public" | /usr/bin/tr -d '[:space:]')
python3 -I Tools/sparkle/sparkle_config.py write-key "$public" $replace
echo "Public key written to Tools/sparkle/update-feed.env."

if [ -n "$backup" ]; then
  [ ! -e "$backup" ] || { echo "$backup already exists. Pick a new file name." >&2; exit 1; }
  (umask 077 && "$tools/bin/generate_keys" -x "$backup" > /dev/null)
  echo "Private key saved to $backup. Put it in 1Password, then delete the file."
else
  echo
  echo "Back the private key up now, or a lost Mac means no more updates for anyone:"
  echo "  Tools/release/sparkle-keys.sh --backup ~/Desktop/nollie-sparkle-key.txt"
fi
echo
echo "Commit Tools/sparkle/update-feed.env. Only the public key is in it."
