#!/bin/sh
# Undo install.sh: resume anything the saver stopped, unbind the patched
# hooks, disable the service and remove the unit's files.
# Run as root on the device from this folder: sh rollback.sh   (idempotent)
set -u
UNIT_NAME=es_api_hold
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/unit.sh"

UNIT="$PATCHES_DIR/$UNIT_NAME"
IDLE="$R/etc/idlewatcher/idle.d/01idle-hooks"
ACTIVE="$R/etc/idlewatcher/active.d/01active-hooks"
ES_SCRIPTS="$R/userdata/system/configs/emulationstation/scripts"
IDLE_STOCK=0eb6bf48a337f268c552c5b8b98e21e335100b746dab106e6e1b0775c0898dc0
ACTIVE_STOCK=96ff5c140572091d7993162d433a6c9aeaef26084324ff50e5e6d17a0010172b

check_device
# Leave nothing stopped behind; the stock hooks cannot see the unit's state
[ -x "$UNIT/knulli-aggressive-saver" ] && "$UNIT/knulli-aggressive-saver" off
rm -rf "$R/var/run/battery-saver/holds"
for target in "$IDLE" "$ACTIVE"; do
  while is_mounted "$target"; do
    umount "$target" || fail "umount $target"
  done
done
[ "$(sha "$IDLE")" = "$IDLE_STOCK" ] && [ "$(sha "$ACTIVE")" = "$ACTIVE_STOCK" ] || fail "hooks are not the stock files after umount"

services_remove "$UNIT_NAME"
rm -f "$SERVICES_DIR/es_api_hold"
for f in scraper-start/battery-saver-pause.sh scraper-stop/battery-saver-unpause.sh; do
  [ "$(sha "$ES_SCRIPTS/$f")" = "$(sha "$HERE/files/${f#*/}")" ] && rm -f "$ES_SCRIPTS/$f"
done
rm -rf "$UNIT"
sync
say "rolled back: stock battery saver hooks active, service and files removed"
