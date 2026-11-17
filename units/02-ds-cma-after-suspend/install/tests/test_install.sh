#!/bin/bash
# Off-device test of install.sh / rollback.sh in a fake root that already has
# the notice-only guard deployed on 2026-11-16.
set -u
SH=${SH:-sh}
HERE=$(cd "$(dirname "$0")" && pwd); UNIT_DIR="$HERE/.."
. "$HERE/sandbox.sh"
OLD="$HERE/fixtures/ds-ion-guard.sh.deployed"; NEW="$UNIT_DIR/files/ds-ion-guard.sh"

new_root "/userdata/system/scripts/ds-ion-guard.sh=$OLD" "/userdata/system/ds-guard/ion_check.py=$UNIT_DIR/files/ion_check.py"
conf="$ROOT/userdata/system/knulli.conf"; before=$(cat "$conf"); G="$ROOT/userdata/system/scripts/ds-ion-guard.sh"
expect "install succeeds" $SH "$UNIT_DIR/install.sh"
[ "$(sha_of "$G")" = "$(sha_of "$NEW")" ] && [ -x "$G" ] && ok "new guard in place" || ko "guard"
[ "$(ls "$ROOT/userdata/system/scripts")" = "ds-ion-guard.sh" ] && ok "no extra hook files in scripts/" || ko "scripts/ has: $(ls "$ROOT/userdata/system/scripts" | tr '\n' ' ')"
ls "$ROOT/userdata/system/patches/backups/" | grep -q "^_userdata_system_scripts_ds-ion-guard.sh\." && ok "replaced guard backed up outside scripts/" || ko "no backup"
[ "$(sha_of "$ROOT/userdata/system/ds-guard/ds-ion-guard.sh.before-unit")" = "$(sha_of "$OLD")" ] && ok "old guard kept for rollback" || ko "old guard backup"
grep -q '^system.dsguard.recovery=1$' "$conf" && grep -q ' ds_guard$' "$conf" && ok "setting and service enabled" || ko "conf: $(tr '\n' ';' < "$conf")"
snap=$(cat "$conf")
expect "install again succeeds" $SH "$UNIT_DIR/install.sh"
[ "$(cat "$conf")" = "$snap" ] && [ "$(sha_of "$ROOT/userdata/system/ds-guard/ds-ion-guard.sh.before-unit")" = "$(sha_of "$OLD")" ] && ok "second install changes nothing" || ko "second install"
expect "boot service is quiet without a request" $SH "$ROOT/userdata/system/services/ds_guard" start
expect "rollback succeeds" $SH "$UNIT_DIR/rollback.sh"
[ "$(sha_of "$G")" = "$(sha_of "$OLD")" ] && ok "old guard restored" || ko "old guard not restored"
[ -f "$ROOT/userdata/system/ds-guard/ion_check.py" ] && ok "pre-existing ion_check.py kept" || ko "ion_check removed"
[ "$(cat "$conf")" = "$before" ] && ok "knulli.conf back to original" || ko "conf after rollback: $(tr '\n' ';' < "$conf")"
[ ! -e "$ROOT/userdata/system/services/ds_guard" ] && ok "service removed" || ko "service left"
expect "rollback again succeeds" $SH "$UNIT_DIR/rollback.sh"
[ "$(sha_of "$G")" = "$(sha_of "$OLD")" ] && ok "second rollback keeps old guard" || ko "second rollback"
drop_root

new_root
expect "install on a clean device" $SH "$UNIT_DIR/install.sh"
expect "rollback on a clean device" $SH "$UNIT_DIR/rollback.sh"
[ ! -e "$ROOT/userdata/system/scripts/ds-ion-guard.sh" ] && [ ! -e "$ROOT/userdata/system/ds-guard" ] && ok "clean device left clean" || ko "leftovers: $(find "$ROOT/userdata/system" -type f | tr '\n' ' ')"
drop_root

new_root; echo 'scarab 2026/09/01 00:00' > "$ROOT/usr/share/knulli/knulli.version"
$SH "$UNIT_DIR/install.sh" >/dev/null 2>&1 && ko "other firmware accepted" || ok "other firmware refused"
[ ! -e "$ROOT/userdata/system/scripts/ds-ion-guard.sh" ] && ok "nothing installed on refusal" || ko "installed on refusal"
drop_root
echo "passed=$pass failed=$fail"; [ "$fail" = 0 ]
