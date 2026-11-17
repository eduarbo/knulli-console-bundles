#!/bin/bash
# Off-device test of install.sh / rollback.sh in a fake root with unit 02's guard.
set -u
SH=${SH:-sh}
HERE=$(cd "$(dirname "$0")" && pwd); UNIT_DIR="$HERE/.."
. "$HERE/sandbox.sh"
OLD="$HERE/fixtures/ds-ion-guard.sh.unit02"; NEW="$UNIT_DIR/files/ds-ion-guard.sh"
stub_python() {  # holder stand-in: hold/release/status on a state file
  cat > "$STUB/python3" <<S
#!/bin/sh
[ "\$1" = -c ] && exit 0   # syntax check: done on the host
st="$ROOT/var/run/cma-reserve.json"
case "\$2" in
  hold) echo '{"held": 3}' > "\$st"; cat "\$st" ;;
  release) rm -f "\$st"; echo '{"released": true}' ;;
  status) [ -f "\$st" ] ;;
esac
S
  chmod +x "$STUB/python3"
}
new_root "/userdata/system/scripts/ds-ion-guard.sh=$OLD"; stub_python
conf="$ROOT/userdata/system/knulli.conf"; before=$(cat "$conf"); G="$ROOT/userdata/system/scripts/ds-ion-guard.sh"
expect "install succeeds" $SH "$UNIT_DIR/install.sh"
[ "$(sha_of "$G")" = "$(sha_of "$NEW")" ] && [ -x "$G" ] && ok "guard with hand-over in place" || ko "guard"
[ "$(ls "$ROOT/userdata/system/scripts")" = "ds-ion-guard.sh" ] && ok "no extra hook files in scripts/" || ko "scripts/ has: $(ls "$ROOT/userdata/system/scripts" | tr '\n' ' ')"
[ "$(sha_of "$ROOT/userdata/system/cma-reserve/ds-ion-guard.sh.unit02")" = "$(sha_of "$OLD")" ] && ok "unit 02 guard kept" || ko "unit 02 copy"
[ -f "$ROOT/var/run/cma-reserve.json" ] && ok "holder started" || ko "holder not started"
grep -q ' cma_reserve$' "$conf" && ok "service enabled" || ko "conf: $(tr '\n' ';' < "$conf")"
snap=$(cat "$conf")
expect "install again succeeds" $SH "$UNIT_DIR/install.sh"
[ "$(cat "$conf")" = "$snap" ] && ok "second install changes nothing in knulli.conf" || ko "second install"
expect "rollback succeeds" $SH "$UNIT_DIR/rollback.sh"
[ "$(sha_of "$G")" = "$(sha_of "$OLD")" ] && ok "unit 02 guard restored" || ko "guard not restored"
[ ! -f "$ROOT/var/run/cma-reserve.json" ] && ok "buffers released" || ko "holder left"
[ "$(cat "$conf")" = "$before" ] && ok "knulli.conf back to original" || ko "conf after rollback: $(tr '\n' ';' < "$conf")"
[ ! -e "$ROOT/userdata/system/services/cma_reserve" ] && [ ! -e "$ROOT/userdata/system/cma-reserve" ] && ok "service and folder removed" || ko "leftovers"
expect "rollback again succeeds" $SH "$UNIT_DIR/rollback.sh"
drop_root

new_root; stub_python
$SH "$UNIT_DIR/install.sh" >/dev/null 2>&1 && ko "accepted without unit 02" || ok "refused without unit 02"
drop_root

printf '#!/bin/sh\n# someone else\n' > /tmp/other-guard.$$
new_root "/userdata/system/scripts/ds-ion-guard.sh=/tmp/other-guard.$$"; stub_python
$SH "$UNIT_DIR/install.sh" >/dev/null 2>&1 && ko "unknown guard accepted" || ok "unknown guard refused"
[ "$(sha_of "$ROOT/userdata/system/scripts/ds-ion-guard.sh")" = "$(sha_of /tmp/other-guard.$$)" ] && ok "unknown guard untouched" || ko "unknown guard changed"
drop_root; rm -f /tmp/other-guard.$$

new_root "/userdata/system/scripts/ds-ion-guard.sh=$OLD"; stub_python; echo 'scarab 2026/09/01 00:00' > "$ROOT/usr/share/knulli/knulli.version"
$SH "$UNIT_DIR/install.sh" >/dev/null 2>&1 && ko "other firmware accepted" || ok "other firmware refused"
drop_root

new_root "/userdata/system/scripts/ds-ion-guard.sh=$OLD"
printf '#!/bin/sh\n[ "$1" = -c ] && exit 0\necho "{\\"held\\": 0}"; exit 1\n' > "$STUB/python3"; chmod +x "$STUB/python3"
$SH "$UNIT_DIR/install.sh" >/dev/null 2>&1 && ko "install passed without buffers" || ok "install fails when the holder gets no buffers"
[ "$(sha_of "$ROOT/userdata/system/scripts/ds-ion-guard.sh")" = "$(sha_of "$OLD")" ] && ok "guard not switched when the hold failed" || ko "guard switched"
drop_root
echo "passed=$pass failed=$fail"; [ "$fail" = 0 ]
