#!/bin/sh
# Install the battery saver with holds on the RG35XX-H (Knulli scarab
# 2026/05/11): EmulationStation's API can be kept answering for background
# tools, /var/run/emulationstation.suspended marks a stopped ES, and scrapes
# pause the saver as intended. Run as root on the device from this folder:
# sh install.sh   Idempotent; stops at the first failed check.
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

(cd "$HERE" && sha256sum --status -c SHA256SUMS) || fail "unit files do not match SHA256SUMS"
check_device
IDLE_PATCHED=$(sha "$HERE/files/01idle-hooks")
ACTIVE_PATCHED=$(sha "$HERE/files/01active-hooks")
idle=$(sha "$IDLE"); active=$(sha "$ACTIVE")
[ "$idle" = "$IDLE_STOCK" ] || [ "$idle" = "$IDLE_PATCHED" ] || fail "$IDLE is not the Scarab file"
[ "$active" = "$ACTIVE_STOCK" ] || [ "$active" = "$ACTIVE_PATCHED" ] || fail "$ACTIVE is not the Scarab file"
grep -q "^IDLE_PATCHED=$IDLE_PATCHED\$" "$HERE/files/es_api_hold" && grep -q "^ACTIVE_PATCHED=$ACTIVE_PATCHED\$" "$HERE/files/es_api_hold" || fail "service and hook hashes disagree"
for f in knulli-aggressive-saver 01idle-hooks 01active-hooks; do
  bash -n "$HERE/files/$f" || fail "syntax of $f"
done

mkdir -p "$UNIT" "$SERVICES_DIR" "$ES_SCRIPTS/scraper-start" "$ES_SCRIPTS/scraper-stop" && chmod 700 "$UNIT" || fail "folders"
for f in knulli-aggressive-saver 01idle-hooks 01active-hooks; do
  install_file "$HERE/files/$f" "$UNIT/$f" 755 "$(sha "$HERE/files/$f")"
done
install_file "$HERE/files/es_api_hold" "$SERVICES_DIR/es_api_hold" 755 "$(sha "$HERE/files/es_api_hold")"
install_file "$HERE/files/battery-saver-pause.sh" "$ES_SCRIPTS/scraper-start/battery-saver-pause.sh" 755 "$(sha "$HERE/files/battery-saver-pause.sh")"
install_file "$HERE/files/battery-saver-unpause.sh" "$ES_SCRIPTS/scraper-stop/battery-saver-unpause.sh" 755 "$(sha "$HERE/files/battery-saver-unpause.sh")"

backup_conf
services_add "$UNIT_NAME"
sync

sh "$SERVICES_DIR/es_api_hold" start || fail "service start"
sh "$SERVICES_DIR/es_api_hold" status || fail "hooks are not the patched ones after start"
say "installed: idle/active hooks use $UNIT/knulli-aggressive-saver (holds), scraper pause fixed, service enabled"
