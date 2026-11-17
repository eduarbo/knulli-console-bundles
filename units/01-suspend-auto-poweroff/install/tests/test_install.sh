#!/bin/bash
# Off-device test of install.sh / rollback.sh / the service in a fake root.
set -u
SH=${SH:-sh}
HERE=$(cd "$(dirname "$0")" && pwd); UNIT_DIR="$HERE/.."
. "$HERE/sandbox.sh"
STOCK="$HERE/fixtures/knulli-suspend.stock"
PATCHED_SHA=$(sha_of "$UNIT_DIR/files/knulli-suspend"); STOCK_SHA=$(sha_of "$STOCK")
T=/usr/bin/knulli-suspend

new_root "$T=$STOCK"
conf="$ROOT/userdata/system/knulli.conf"; before=$(cat "$conf")
expect "install succeeds" $SH "$UNIT_DIR/install.sh"
[ "$(sha_of "$ROOT$T")" = "$PATCHED_SHA" ] && ok "target now patched" || ko "target not patched"
grep -q '^system.suspend.shutdowntimer=10800$' "$conf" && grep -q '^system.suspend.shutdownbattery=5$' "$conf" && ok "owner defaults written" || ko "defaults missing"
grep -q '^system.services=connman_pmf brightness_persist romm_autosync suspend_poweroff$' "$conf" && ok "service enabled, others kept" || ko "services: $(grep services "$conf")"
[ "$(cat "$conf.bak-suspend_poweroff")" = "$before" ] && ok "knulli.conf backup is the original" || ko "backup"
snap=$(cat "$conf")
expect "install again succeeds" $SH "$UNIT_DIR/install.sh"
[ "$(cat "$conf")" = "$snap" ] && [ "$(grep -c ' /usr/bin/knulli-suspend ' "$ROOT/proc/mounts")" = 1 ] && ok "second install changes nothing" || ko "second install changed state"
umount "$ROOT$T"; [ "$(sha_of "$ROOT$T")" = "$STOCK_SHA" ] && ok "simulated reboot back to stock" || ko "reboot sim"
expect "service start re-binds at boot" $SH "$ROOT/userdata/system/services/suspend_poweroff" start
[ "$(sha_of "$ROOT$T")" = "$PATCHED_SHA" ] && ok "patched after service start" || ko "service start"
expect "service status reports active" $SH "$ROOT/userdata/system/services/suspend_poweroff" status
expect "rollback succeeds" $SH "$UNIT_DIR/rollback.sh"
[ "$(sha_of "$ROOT$T")" = "$STOCK_SHA" ] && ok "stock after rollback" || ko "not stock after rollback"
[ "$(cat "$conf")" = "$before" ] && ok "knulli.conf back to original" || ko "conf after rollback: $(cat "$conf" | tr '\n' ';')"
[ ! -e "$ROOT/userdata/system/services/suspend_poweroff" ] && [ ! -e "$ROOT/userdata/system/patches/suspend_poweroff" ] && ok "unit files removed" || ko "unit files left"
expect "rollback again succeeds" $SH "$UNIT_DIR/rollback.sh"
drop_root

new_root "$T=$STOCK"; conf="$ROOT/userdata/system/knulli.conf"
echo 'system.suspend.shutdowntimer=7200' >> "$conf"
$SH "$UNIT_DIR/install.sh" >/dev/null
grep -q '^system.suspend.shutdowntimer=7200$' "$conf" && ok "existing owner value kept" || ko "owner value overwritten"
knulli-settings-set -f "$conf" system.suspend.shutdownbattery 10
$SH "$UNIT_DIR/rollback.sh" >/dev/null
grep -q '^system.suspend.shutdowntimer=7200$' "$conf" && grep -q '^system.suspend.shutdownbattery=10$' "$conf" && ok "rollback keeps values the owner set" || ko "rollback dropped owner values: $(tr '\n' ';' < "$conf")"
drop_root

new_root "$T=$STOCK"; echo 'scarab 2026/09/01 00:00' > "$ROOT/usr/share/knulli/knulli.version"; snap=$(cat "$ROOT/userdata/system/knulli.conf")
$SH "$UNIT_DIR/install.sh" >/dev/null 2>&1 && ko "other firmware accepted" || ok "other firmware refused"
[ "$(cat "$ROOT/userdata/system/knulli.conf")" = "$snap" ] && [ ! -e "$ROOT/userdata/system/patches/suspend_poweroff" ] && ok "nothing changed on refusal" || ko "changes on refusal"
expect "service refuses other firmware" bash -c "! $SH '$UNIT_DIR/files/suspend_poweroff' start"
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q notify "$ROOT.calls" 2>/dev/null && break; sleep 0.2; done
grep -q 'notify -d Apagado tras suspensión desactivado' "$ROOT.calls" 2>/dev/null && ok "refusal is shown in ES (/notify)" || ko "no ES notice on refusal"
drop_root

new_root "$T=$UNIT_DIR/files/suspend_poweroff"
$SH "$UNIT_DIR/install.sh" >/dev/null 2>&1 && ko "unknown target accepted" || ok "unknown target refused"
drop_root

new_root "$T=$STOCK"; cp -R "$UNIT_DIR" "$ROOT.unit"; echo '# tampered' >> "$ROOT.unit/files/knulli-suspend"
$SH "$ROOT.unit/install.sh" >/dev/null 2>&1 && ko "tampered files accepted" || ok "tampered files refused (SHA256SUMS)"
rm -rf "$ROOT.unit"; drop_root
echo "passed=$pass failed=$fail"; [ "$fail" = 0 ]
