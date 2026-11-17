#!/bin/sh
# Undo install.sh: unbind the patched knulli-suspend, disable the service and
# restore the two settings unless the owner changed them since. Run as root on
# the device from this folder: sh rollback.sh   (idempotent)
set -u
UNIT_NAME=suspend_poweroff
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/unit.sh"

UNIT="$PATCHES_DIR/$UNIT_NAME"
TARGET="$R/usr/bin/knulli-suspend"
STOCK_SHA=8884cb4736860bc1518670e736f3eb0ad43650a9d7add97815a1ff0ff5d32621

check_device
while is_mounted "$TARGET"; do
  umount "$TARGET" || fail "umount $TARGET"
done
[ "$(sha "$TARGET")" = "$STOCK_SHA" ] || fail "$TARGET is not the stock file after umount"

services_remove "$UNIT_NAME"
if [ -f "$UNIT/settings-before" ]; then
  restore_setting "$UNIT/settings-before" system.suspend.shutdowntimer 10800
  restore_setting "$UNIT/settings-before" system.suspend.shutdownbattery 5
fi
sync

rm -f "$SERVICES_DIR/$UNIT_NAME"
rm -rf "$UNIT"
say "rolled back: stock knulli-suspend active, service removed (knulli.conf backup kept at $CONF.bak-$UNIT_NAME)"
