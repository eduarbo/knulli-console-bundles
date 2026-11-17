#!/bin/sh
# Undo install.sh: values of a running listed game put back, hook and table removed.
# Run as root on the device from this folder: sh rollback.sh   (idempotent)
set -u
UNIT_NAME=game_performance
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/unit.sh"

DIR="$R/userdata/system/game-performance"
HOOK="$R/userdata/system/scripts/game-performance.sh"

check_device
if [ -f "$HOOK" ] && [ -f "$DIR/hook.installed" ]; then
  sh "$HOOK" gameStop rollback "" "" ""   # puts back whatever a running listed game raised
  rm -f "$HOOK"
fi
rm -rf "$DIR"
sync
say "rolled back: hook and table removed"
