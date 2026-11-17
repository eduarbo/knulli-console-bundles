#!/bin/sh
# Install unit 18 (per-game CPU clock ceiling / GPU floor) on the RG35XX-H (Knulli
# scarab 2026/05/11): the gameStart/gameStop hook in /userdata/system/scripts and
# its table in /userdata/system/game-performance (outside knulli.conf, so a settings
# reset keeps it). Run as root on the device from this folder: sh install.sh
# Idempotent; rollback.sh undoes it. Safe while no game runs.
set -u
UNIT_NAME=game_performance
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/unit.sh"

DIR="$R/userdata/system/game-performance"
HOOK="$R/userdata/system/scripts/game-performance.sh"

(cd "$HERE" && sha256sum --status -c SHA256SUMS) || fail "unit files do not match SHA256SUMS"
check_device
sh -n "$HERE/files/game-performance.sh" || fail "syntax of game-performance.sh"
[ ! -e "$HOOK" ] || [ "$(sha "$HOOK")" = "$(sha "$HERE/files/game-performance.sh")" ] || [ -f "$DIR/hook.installed" ] || fail "$HOOK exists and is not this unit's"
# every value in the table must be one the drivers list
freqs=$(cat "$R/sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies" 2>/dev/null)
while IFS='	' read -r system rom fields; do
  case "$system" in ''|'#'*) continue ;; esac
  for kv in $fields; do
    case "$kv" in
      maxfreq=*) echo " $freqs " | grep -q " ${kv#maxfreq=} " || fail "table: $system/$rom $kv not available" ;;
      governor=*) grep -qw "${kv#governor=}" "$R/sys/devices/system/cpu/cpufreq/policy0/scaling_available_governors" || fail "table: $system/$rom $kv not available" ;;
      gpu_min=max) ;;
      gpu_min=*) grep -qw "${kv#gpu_min=}" "$R/sys/class/devfreq/gpu/available_frequencies" || fail "table: $system/$rom $kv not available" ;;
      *) fail "table: unknown field $kv" ;;
    esac
  done
done < "$HERE/files/profiles.tsv"

mkdir -p "$DIR" "$R/userdata/system/scripts" || fail "folders"
install_file "$HERE/files/profiles.tsv" "$DIR/profiles.tsv" 644 "$(sha "$HERE/files/profiles.tsv")"
install_file "$HERE/files/game-performance.sh" "$HOOK" 755 "$(sha "$HERE/files/game-performance.sh")"
: > "$DIR/hook.installed"
sync
say "installed: hook $HOOK, $(grep -c '^[^#]' "$DIR/profiles.tsv") games in $DIR/profiles.tsv"
