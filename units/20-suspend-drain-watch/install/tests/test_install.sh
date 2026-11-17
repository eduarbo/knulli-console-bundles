#!/bin/bash
# Off-device test of install.sh / rollback.sh in a fake root (Linux: flock).
set -u
SH=${SH:-sh}
HERE=$(cd "$(dirname "$0")" && pwd); UNIT_DIR="$HERE/.."
. "$HERE/sandbox.sh"
prep() {
  mkdir -p "$ROOT/etc/pm/sleep.d"
  printf '#!/bin/sh\nexit 0\n' > "$ROOT/etc/pm/sleep.d/10-hide-ui"; chmod 755 "$ROOT/etc/pm/sleep.d/10-hide-ui"
  # suspend-log.sh status needs connmanctl/ip; keep them quiet
  printf '#!/bin/sh\nexit 0\n' > "$STUB/connmanctl"; printf '#!/bin/sh\nexit 0\n' > "$STUB/ip"; chmod +x "$STUB/connmanctl" "$STUB/ip"
}
HOOK_SRC="$UNIT_DIR/files/05suspend-log"
new_root; prep
conf="$ROOT/userdata/system/knulli.conf"; before=$(cat "$conf"); H="$ROOT/etc/pm/sleep.d/05suspend-log"
expect "install succeeds" $SH "$UNIT_DIR/install.sh"
[ "$(sha_of "$H")" = "$(sha_of "$HOOK_SRC")" ] && [ -x "$H" ] && ok "hook in /etc/pm/sleep.d" || ko "hook"
[ "$(sha_of "$ROOT/etc/pm/sleep.d/10-hide-ui")" = "$(sha_of "$ROOT/etc/pm/sleep.d/10-hide-ui")" ] && ok "stock hooks untouched" || ko "stock hook"
grep -q ' suspend_log$' "$conf" && ! grep -q 'system.suspend' "$conf" && ok "only the service enabled" || ko "conf: $(tr '\n' ';' < "$conf")"
for f in suspend-log.sh 05suspend-log drain-test.sh drain_report.py; do
  [ "$(sha_of "$ROOT/userdata/system/suspend-log/$f")" = "$(sha_of "$UNIT_DIR/files/$f")" ] || ko "file $f"
done; ok "unit files in /userdata/system/suspend-log"
snap=$(cat "$conf")
expect "install again succeeds" $SH "$UNIT_DIR/install.sh"
[ "$(cat "$conf")" = "$snap" ] && ok "second install changes nothing" || ko "second install"
rm -f "$H"
expect "service start puts the hook back (boot)" $SH "$ROOT/userdata/system/services/suspend_log" start
[ "$(sha_of "$H")" = "$(sha_of "$HOOK_SRC")" ] && ok "hook back after boot" || ko "hook not back"
expect "rollback succeeds" $SH "$UNIT_DIR/rollback.sh"
[ ! -e "$H" ] && ok "hook removed" || ko "hook left"
[ "$(cat "$conf")" = "$before" ] && ok "knulli.conf back to original" || ko "conf after rollback: $(tr '\n' ';' < "$conf")"
[ ! -e "$ROOT/userdata/system/services/suspend_log" ] && [ ! -e "$ROOT/userdata/system/suspend-log" ] && ok "service and files removed" || ko "leftovers"
expect "rollback again succeeds" $SH "$UNIT_DIR/rollback.sh"
drop_root


new_root; prep; printf '#!/bin/sh\n# other\n' > "$ROOT/etc/pm/sleep.d/05suspend-log"
$SH "$UNIT_DIR/install.sh" >/dev/null 2>&1 && ko "foreign hook overwritten" || ok "foreign hook with our name refused"
drop_root

new_root; prep; echo 'scarab 2026/09/01 00:00' > "$ROOT/usr/share/knulli/knulli.version"
$SH "$UNIT_DIR/install.sh" >/dev/null 2>&1 && ko "other firmware accepted" || ok "other firmware refused"
[ ! -e "$ROOT/etc/pm/sleep.d/05suspend-log" ] && ok "nothing installed on refusal" || ko "installed on refusal"
drop_root
echo "passed=$pass failed=$fail"; [ "$fail" = 0 ]
