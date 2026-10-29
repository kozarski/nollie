#!/bin/bash
# One command for a Nollie release, with a checkpoint before anything leaves this Mac.
#
#   Tools/release/ship.sh 1.3 --dry-run     rehearse every local step; nothing is sent
#   Tools/release/ship.sh 1.3               the real thing, stopping for a yes at each send
#   Tools/release/ship.sh --help            every option
#
# The steps live in Tools/release/ship.py. Docs/releasing.md has the whole story.
exec python3 -I "$(dirname "$0")/ship.py" "$@"
