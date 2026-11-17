#!/bin/bash
# Off-device test of install.sh / rollback.sh / the service in a fake root.
set -u
SH=${SH:-sh}
HERE=$(cd "$(dirname "$0")" && pwd); UNIT_DIR="$HERE/.."
. "$HERE/sandbox.sh"
I=/etc/idlewatcher/idle.d/01idle-hooks; A=/etc/idlewatcher/active.d/01active-hooks
IS="$HERE/fixtures/01idle-hooks.stock"; AS="$HERE/fixtures/01active-hooks.stock"
ESS=/userdata/system/configs/emulationstation/scripts

new_root "$I=$IS" "$A=$AS"
conf="$ROOT/userdata/system/knulli.conf"; before=$(cat "$conf")
expect "install succeeds" $SH "$UNIT_DIR/install.sh"
[ "$(sha_of "$ROOT$I")" = "$(sha_of "$UNIT_DIR/files/01idle-hooks")" ] && [ "$(sha_of "$ROOT$A")" = "$(sha_of "$UNIT_DIR/files/01active-hooks")" ] && ok "both hooks patched" || ko "hooks"
[ -x "$ROOT$ESS/scraper-start/battery-saver-pause.sh" ] && [ -x "$ROOT$ESS/scraper-stop/battery-saver-unpause.sh" ] && ok "scraper hooks installed" || ko "scraper hooks"
grep -q '^system.services=connman_pmf brightness_persist romm_autosync es_api_hold$' "$conf" && ok "service enabled, others kept" || ko "services"
snap=$(cat "$conf")
expect "install again succeeds" $SH "$UNIT_DIR/install.sh"
[ "$(cat "$conf")" = "$snap" ] && [ "$(wc -l < "$ROOT/proc/mounts" | tr -d ' ')" = 2 ] && ok "second install changes nothing" || ko "second install: $(cat "$ROOT/proc/mounts")"
umount "$ROOT$I"; umount "$ROOT$A"
expect "service start re-binds at boot" $SH "$ROOT/userdata/system/services/es_api_hold" start
expect "service status after boot" $SH "$ROOT/userdata/system/services/es_api_hold" status
expect "rollback succeeds" $SH "$UNIT_DIR/rollback.sh"
[ "$(sha_of "$ROOT$I")" = "$(sha_of "$IS")" ] && [ "$(sha_of "$ROOT$A")" = "$(sha_of "$AS")" ] && ok "stock hooks after rollback" || ko "not stock"
[ "$(cat "$conf")" = "$before" ] && ok "knulli.conf back to original" || ko "conf"
[ ! -e "$ROOT/userdata/system/patches/es_api_hold" ] && [ ! -e "$ROOT$ESS/scraper-start/battery-saver-pause.sh" ] && [ ! -e "$ROOT/userdata/system/services/es_api_hold" ] && ok "unit files removed" || ko "leftovers"
expect "rollback again succeeds" $SH "$UNIT_DIR/rollback.sh"
drop_root

new_root "$I=$IS" "$A=$UNIT_DIR/files/es_api_hold"
$SH "$UNIT_DIR/install.sh" >/dev/null 2>&1 && ko "unknown active hook accepted" || ok "unknown active hook refused"
[ "$(sha_of "$ROOT$I")" = "$(sha_of "$IS")" ] && ok "idle hook untouched on refusal" || ko "idle hook changed"
drop_root

new_root "$I=$IS" "$A=$AS"; echo 'scarab 2026/09/01 00:00' > "$ROOT/usr/share/knulli/knulli.version"
$SH "$UNIT_DIR/install.sh" >/dev/null 2>&1 && ko "other firmware accepted" || ok "other firmware refused"
mkdir -p "$ROOT/userdata/system/patches/es_api_hold"; cp "$UNIT_DIR"/files/knulli-aggressive-saver "$UNIT_DIR"/files/01*-hooks "$ROOT/userdata/system/patches/es_api_hold/"
$SH "$UNIT_DIR/files/es_api_hold" start && ko "service accepted other firmware" || ok "service refuses other firmware"
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q notify "$ROOT.calls" 2>/dev/null && break; sleep 0.2; done
grep -q 'notify -d Ahorro de batería con retenciones desactivado' "$ROOT.calls" 2>/dev/null && [ "$(sha_of "$ROOT$I")" = "$(sha_of "$IS")" ] && ok "refusal is shown in ES (/notify), hooks untouched" || ko "no ES notice on refusal"
drop_root
echo "passed=$pass failed=$fail"; [ "$fail" = 0 ]
