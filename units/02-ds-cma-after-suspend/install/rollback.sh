#!/bin/sh
# Undo install.sh: put the previous guard back (or remove ours), disable the
# relaunch service and restore system.dsguard.recovery unless changed since.
# Run as root on the device from this folder: sh rollback.sh   (idempotent)
set -u
UNIT_NAME=ds_guard
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/unit.sh"

DIR="$R/userdata/system/ds-guard"
GUARD="$R/userdata/system/scripts/ds-ion-guard.sh"
BEFORE="$DIR/unit-before"
OURS=$(sha "$HERE/files/ds-ion-guard.sh")

check_device
services_remove ds_guard
rm -f "$SERVICES_DIR/ds_guard"
if [ -f "$DIR/ds-ion-guard.sh.before-unit" ]; then
  cp -p "$DIR/ds-ion-guard.sh.before-unit" "$GUARD.tmp" && mv -f "$GUARD.tmp" "$GUARD" || fail "restoring the previous guard"
  rm -f "$DIR/ds-ion-guard.sh.before-unit"
elif [ -f "$GUARD" ] && [ "$(sha "$GUARD")" = "$OURS" ]; then
  rm -f "$GUARD"
fi
if grep -q '^check=absent$' "$BEFORE" 2>/dev/null; then
  rm -f "$DIR/ion_check.py"
fi
if [ -f "$DIR/settings-before" ]; then
  restore_setting "$DIR/settings-before" system.dsguard.recovery 1
fi
rm -f "$DIR/settings-before" "$BEFORE" "$DIR/relaunch" "$DIR/last-recovery" "$R/var/run/ds-guard.reboot"
rmdir "$DIR" 2>/dev/null
sync
say "rolled back: previous guard restored, relaunch service removed"
