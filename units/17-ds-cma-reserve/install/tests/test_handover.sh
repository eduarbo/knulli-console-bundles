#!/bin/bash
# Off-device test of the hand-over added to unit 02's guard: python3 is a stub
# that records its arguments; the order of calls is what matters.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GUARD="$HERE/../files/ds-ion-guard.sh"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $*"; }
ko() { fail=$((fail+1)); echo "FAIL $*"; }
for SH in /bin/dash /bin/bash; do
  T=$(mktemp -d "${TMPDIR:-/tmp}/ho.XXXXXX")
  mkdir -p "$T/stub" "$T/userdata/system/ds-guard" "$T/userdata/system/cma-reserve" "$T/var/log" "$T/var/run" "$T/usr/share/knulli"
  echo 'scarab 2026/05/11 00:09' > "$T/usr/share/knulli/knulli.version"
  : > "$T/userdata/system/cma-reserve/cma-reserve.py"
  cat > "$T/stub/python3" <<S
#!/bin/sh
echo "\${2:-check}" >> "$T/calls"
case "\$1" in *cma-reserve.py) echo '{"action": "'"\$2"'"}'; exit 0 ;; esac
echo '{"ok": true, "cma_free_kb": 49152}'
S
  printf '#!/bin/sh\nexit 0\n' > "$T/stub/curl"
  chmod +x "$T/stub/"*
  run() { UNIT_ROOT="$T" PATH="$T/stub:$PATH" $SH "$GUARD" "$@"; }
  rom=/userdata/roms/nds/Mega\ Man\ ZX.zip
  run gameStart nds advanced_drastic advanced_drastic "$rom"
  [ "$(tr '\n' ' ' < "$T/calls")" = "release check " ] && ok "$SH: release before the check" || ko "$SH: calls $(tr '\n' ' ' < "$T/calls")"
  : > "$T/calls"; run gameStop nds advanced_drastic advanced_drastic "$rom"
  [ "$(tr '\n' ' ' < "$T/calls")" = "hold " ] && ok "$SH: hold after the game" || ko "$SH: stop calls $(tr '\n' ' ' < "$T/calls")"
  : > "$T/calls"; run gameStart snes libretro snes9x /userdata/roms/snes/x.zip; run gameStop snes libretro snes9x /userdata/roms/snes/x.zip
  [ ! -s "$T/calls" ] && ok "$SH: other systems untouched" || ko "$SH: other system calls $(tr '\n' ' ' < "$T/calls")"
  grep -q 'reserve release {"action": "release"}' "$T/var/log/ds-ion-guard.log" && grep -q 'reserve hold' "$T/var/log/ds-ion-guard.log" && ok "$SH: hand-over logged" || ko "$SH: log $(cat "$T/var/log/ds-ion-guard.log")"
  rm -f "$T/userdata/system/cma-reserve/cma-reserve.py"; : > "$T/calls"
  run gameStart nds advanced_drastic advanced_drastic "$rom"
  [ "$(tr '\n' ' ' < "$T/calls")" = "check " ] && ok "$SH: without unit 17 only the check" || ko "$SH: calls without unit 17 $(tr '\n' ' ' < "$T/calls")"
  rm -rf "$T"
done
echo "passed=$pass failed=$fail"; [ "$fail" = 0 ]
