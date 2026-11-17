#!/bin/sh
# Install "shut down after a time suspended" on the RG35XX-H (Knulli scarab
# 2026/05/11). Run as root on the device from this folder: sh install.sh
# Idempotent. Stops at the first failed check; rollback.sh undoes it.
set -u
UNIT_NAME=suspend_poweroff
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/unit.sh"

UNIT="$PATCHES_DIR/$UNIT_NAME"
TARGET="$R/usr/bin/knulli-suspend"
STOCK_SHA=8884cb4736860bc1518670e736f3eb0ad43650a9d7add97815a1ff0ff5d32621
PATCHED_SHA=ce93c99c878d5a8434d3a7bec9982cf3fcc5d98b5e0bc415d6e4fe01c73c4f00
SERVICE_SHA=$(sha "$HERE/files/$UNIT_NAME")   # pinned by SHA256SUMS
# Owner defaults (knulli.conf, only written when the key is absent)
TIMER=10800    # system.suspend.shutdowntimer: 3 h
BATTERY=5      # system.suspend.shutdownbattery: %

(cd "$HERE" && sha256sum --status -c SHA256SUMS) || fail "unit files do not match SHA256SUMS"
check_device
current=$(sha "$TARGET")
[ "$current" = "$STOCK_SHA" ] || [ "$current" = "$PATCHED_SHA" ] || fail "$TARGET is not the Scarab file"
grep -q "^PATCHED_SHA=$PATCHED_SHA\$" "$HERE/files/$UNIT_NAME" || fail "service and script hashes disagree"
sh -n "$HERE/files/knulli-suspend" || fail "syntax of knulli-suspend"

mkdir -p "$UNIT" "$SERVICES_DIR" && chmod 700 "$UNIT" || fail "folders"
install_file "$HERE/files/knulli-suspend" "$UNIT/knulli-suspend" 555 "$PATCHED_SHA"
install_file "$HERE/files/$UNIT_NAME" "$SERVICES_DIR/$UNIT_NAME" 755 "$SERVICE_SHA"

backup_conf
set_default "$UNIT/settings-before" system.suspend.shutdowntimer "$TIMER"
set_default "$UNIT/settings-before" system.suspend.shutdownbattery "$BATTERY"
services_add "$UNIT_NAME"
sync

sh "$SERVICES_DIR/$UNIT_NAME" start || fail "service start"
[ "$(sha "$TARGET")" = "$PATCHED_SHA" ] || fail "$TARGET is not the patched script after start"

say "installed: knulli-suspend patched, timer=$(conf_get system.suspend.shutdowntimer)s battery_floor=$(conf_get system.suspend.shutdownbattery)% service=enabled"
