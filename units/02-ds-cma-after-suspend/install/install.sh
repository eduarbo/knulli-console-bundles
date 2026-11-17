#!/bin/sh
# Install the DS video memory guard with automatic recovery on the RG35XX-H
# (Knulli scarab 2026/05/11). Replaces the notice-only gameStart guard (kept
# for rollback). Run as root on the device from this folder: sh install.sh
# Idempotent. Stops at the first failed check; rollback.sh undoes it.
set -u
UNIT_NAME=ds_guard
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/unit.sh"

DIR="$R/userdata/system/ds-guard"
GUARD="$R/userdata/system/scripts/ds-ion-guard.sh"
BEFORE="$DIR/unit-before"

(cd "$HERE" && sha256sum --status -c SHA256SUMS) || fail "unit files do not match SHA256SUMS"
check_device
for f in files/ds-ion-guard.sh files/ds_guard; do
  sh -n "$HERE/$f" || fail "syntax of $f"
done

mkdir -p "$DIR" "$R/userdata/system/scripts" "$SERVICES_DIR" || fail "folders"
if [ ! -f "$BEFORE" ]; then
  # First install: keep what was there for rollback.sh
  { [ -f "$GUARD" ] && echo "guard=present" || echo "guard=absent"
    [ -f "$DIR/ion_check.py" ] && echo "check=present" || echo "check=absent"; } > "$BEFORE.tmp" &&
    mv -f "$BEFORE.tmp" "$BEFORE" || fail "state"
  if [ -f "$GUARD" ]; then
    cp -p "$GUARD" "$DIR/ds-ion-guard.sh.before-unit" || fail "backup of the current guard"
  fi
fi
install_file "$HERE/files/ion_check.py" "$DIR/ion_check.py" 644 "$(sha "$HERE/files/ion_check.py")"
install_file "$HERE/files/ds-ion-guard.sh" "$GUARD" 755 "$(sha "$HERE/files/ds-ion-guard.sh")"
install_file "$HERE/files/ds_guard" "$SERVICES_DIR/ds_guard" 755 "$(sha "$HERE/files/ds_guard")"

backup_conf
set_default "$DIR/settings-before" system.dsguard.recovery 1
services_add ds_guard
sync

[ -x "$GUARD" ] && [ "$(sha "$GUARD")" = "$(sha "$HERE/files/ds-ion-guard.sh")" ] || fail "guard readback"
say "installed: gameStart/gameStop guard with recovery=$(conf_get system.dsguard.recovery), boot relaunch service enabled"
