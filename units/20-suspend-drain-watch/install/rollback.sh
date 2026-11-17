#!/bin/sh
# Undo install.sh: hook removed, any drain test stopped, service removed. The battery
# log /userdata/system/logs/suspend-drain.jsonl (and drain-test-*.txt) is kept as
# evidence. Run as root on the device from this folder: sh rollback.sh  (idempotent)
set -u
UNIT_NAME=suspend_log
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/unit.sh"

DIR="$R/userdata/system/suspend-log"
HOOK="$R/etc/pm/sleep.d/05suspend-log"

check_device
if [ -f "$HOOK" ] && [ "$(sha "$HOOK")" = "$(sha "$HERE/files/05suspend-log")" ]; then
  rm -f "$HOOK" || fail "removing the hook"
fi
[ -f "$DIR/drain-test.sh" ] && sh "$DIR/drain-test.sh" stop > /dev/null 2>&1
services_remove suspend_log
sync
rm -f "$SERVICES_DIR/suspend_log"
rm -rf "$DIR" "$R/var/run/suspend-log"
say "rolled back: hook and service removed (knulli.conf backup at $CONF.bak-$UNIT_NAME)"
