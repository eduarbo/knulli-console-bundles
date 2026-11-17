#!/bin/bash
# Off-device test of install.sh / rollback.sh in a fake root.
set -u
SH=${SH:-sh}
HERE=$(cd "$(dirname "$0")" && pwd); UNIT_DIR="$HERE/.."
. "$HERE/sandbox.sh"
prep() {
  P="$ROOT/sys/devices/system/cpu/cpufreq/policy0"; mkdir -p "$P" "$ROOT/sys/class/devfreq/gpu" "$ROOT/var/log"
  echo "480000 792000 1008000 1200000 1320000 1416000 1512000 1600000 1704000" > "$P/scaling_available_frequencies"
  echo 1512000 > "$P/scaling_max_freq"
  echo "interactive conservative ondemand userspace powersave performance schedutil" > "$P/scaling_available_governors"
  echo "240000000 336000000 420000000 504000000 600000000 696000000" > "$ROOT/sys/class/devfreq/gpu/available_frequencies"
  echo 0 > "$ROOT/sys/class/devfreq/gpu/min_freq"
}
new_root; prep; H="$ROOT/userdata/system/scripts/game-performance.sh"
conf="$ROOT/userdata/system/knulli.conf"; before=$(cat "$conf")
expect "install succeeds" $SH "$UNIT_DIR/install.sh"
[ "$(sha_of "$H")" = "$(sha_of "$UNIT_DIR/files/game-performance.sh")" ] && [ -x "$H" ] && ok "hook in scripts/" || ko "hook"
[ "$(sha_of "$ROOT/userdata/system/game-performance/profiles.tsv")" = "$(sha_of "$UNIT_DIR/files/profiles.tsv")" ] && ok "table installed" || ko "table"
[ "$(cat "$conf")" = "$before" ] && ok "knulli.conf untouched" || ko "conf changed"
expect "install again succeeds" $SH "$UNIT_DIR/install.sh"
expect "rollback succeeds" $SH "$UNIT_DIR/rollback.sh"
[ ! -e "$H" ] && [ ! -e "$ROOT/userdata/system/game-performance" ] && ok "hook and table removed" || ko "leftovers"
expect "rollback again succeeds" $SH "$UNIT_DIR/rollback.sh"
drop_root

new_root; prep; mkdir -p "$ROOT/userdata/system/scripts"; printf '#!/bin/sh\n# other\n' > "$ROOT/userdata/system/scripts/game-performance.sh"
$SH "$UNIT_DIR/install.sh" >/dev/null 2>&1 && ko "foreign hook overwritten" || ok "foreign hook refused"
drop_root

new_root; prep; echo 'scarab 2026/09/01 00:00' > "$ROOT/usr/share/knulli/knulli.version"
$SH "$UNIT_DIR/install.sh" >/dev/null 2>&1 && ko "other firmware accepted" || ok "other firmware refused"
drop_root
echo "passed=$pass failed=$fail"; [ "$fail" = 0 ]
