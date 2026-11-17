#!/bin/sh
# Knulli user script (/userdata/system/scripts, gameStart/gameStop hook):
# per-game CPU clock ceiling and GPU floor for the games listed in
# /userdata/system/game-performance/profiles.tsv, measured on the RG35XX-H with
# the probe harness (upstream/knulli/18-per-game-performance/VALIDATION.md).
#
# Knulli has a per-game governor (<system>["<rom>"].powermode, applied by the
# system powermode hook) but only a global clock ceiling (system.cpu.maxfreq)
# and no GPU setting. This hook adds both for the listed games only: on
# gameStart it records the current values, raises them, and starts a watcher;
# on gameStop (or, if emulatorlauncher dies without gameStop, the watcher) it
# puts the recorded values back. The table lives outside knulli.conf, so a
# settings reset does not drop it; system.gameperformance=0 turns it off.
#
# profiles.tsv: <system><TAB><rom file name><TAB>key=value ...
#   maxfreq=<kHz from scaling_available_frequencies>   gpu_min=max|<Hz>
#   governor=<one of scaling_available_governors>   (the system powermode hook
#   sets the global one again at gameStop; the watcher restores it otherwise)
#
# emulatorlauncher calls: <gameStart|gameStop> <system> <emulator> <core> <rom>
# internal: watch <emulatorlauncher pid>
R="${UNIT_ROOT:-}"
DIR="$R/userdata/system/game-performance"
TABLE="$DIR/profiles.tsv"
SAVED="$R/var/run/game-performance.saved"
WATCH="$R/var/run/game-performance.watch"
LOG="$R/var/log/game-performance.log"
CPUFREQ="$R/sys/devices/system/cpu/cpufreq"
GPU="$R/sys/class/devfreq/gpu"

log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG" 2>/dev/null; }
temps() {
  printf 'cpu=%s gpu=%s' "$(cat "$R/sys/class/thermal/thermal_zone0/temp" 2>/dev/null)" \
    "$(cat "$R/sys/class/thermal/thermal_zone1/temp" 2>/dev/null)"
}

# key=value fields for <system> <rom file name>, empty when not listed
profile() {
  [ -f "$TABLE" ] || return 0
  awk -F '\t' -v s="$1" -v r="$2" '$1 == s && $2 == r { $1 = ""; $2 = ""; print; exit }' "$TABLE"
}

field() {  # <fields> <key>
  for kv in $1; do
    case "$kv" in "$2="*) echo "${kv#*=}"; return 0 ;; esac
  done
}

restore() {
  [ -f "$SAVED" ] || return 0
  while read -r path value; do
    case "$path" in
      "$CPUFREQ"/policy*/scaling_max_freq|"$CPUFREQ"/policy*/scaling_governor|"$GPU"/min_freq)
        echo "$value" > "$path" 2>/dev/null ;;
    esac
  done < "$SAVED"
  rm -f "$SAVED"
  log "restored ($1) $(temps)"
}

apply() {  # <fields>
  maxfreq=$(field "$1" maxfreq)
  gpu_min=$(field "$1" gpu_min)
  governor=$(field "$1" governor)
  : > "$SAVED.tmp"
  for policy in "$CPUFREQ"/policy*; do
    [ -f "$policy/scaling_max_freq" ] || continue
    # governor first: restoring a lower ceiling after it keeps the order safe
    [ -f "$policy/scaling_governor" ] && echo "$policy/scaling_governor $(cat "$policy/scaling_governor")" >> "$SAVED.tmp"
    echo "$policy/scaling_max_freq $(cat "$policy/scaling_max_freq")" >> "$SAVED.tmp"
  done
  [ -f "$GPU/min_freq" ] && echo "$GPU/min_freq $(cat "$GPU/min_freq")" >> "$SAVED.tmp"
  mv -f "$SAVED.tmp" "$SAVED"
  if [ -n "$maxfreq" ]; then
    for policy in "$CPUFREQ"/policy*; do
      # only frequencies the cpufreq driver lists (it has their voltages)
      grep -qw "$maxfreq" "$policy/scaling_available_frequencies" 2>/dev/null || continue
      echo "$maxfreq" > "$policy/scaling_max_freq" 2>/dev/null
    done
  fi
  if [ -n "$governor" ]; then
    for policy in "$CPUFREQ"/policy*; do
      grep -qw "$governor" "$policy/scaling_available_governors" 2>/dev/null || continue
      echo "$governor" > "$policy/scaling_governor" 2>/dev/null
    done
  fi
  if [ -n "$gpu_min" ] && [ -f "$GPU/min_freq" ]; then
    [ "$gpu_min" = max ] && gpu_min=$(awk '{ print $NF }' "$GPU/available_frequencies")
    grep -qw "$gpu_min" "$GPU/available_frequencies" && echo "$gpu_min" > "$GPU/min_freq" 2>/dev/null
  fi
}

case "$1" in
  gameStart)
    restore "left over"
    [ "$(knulli-settings-get system.gameperformance 2>/dev/null)" = 0 ] && exit 0
    fields=$(profile "$2" "${5##*/}")
    # ES may name the system differently from its ROM folder (roms/<folder>/<file>)
    [ -n "$fields" ] || { folder=${5%/*}; fields=$(profile "${folder##*/}" "${5##*/}"); }
    [ -n "$fields" ] || exit 0
    apply "$fields"
    log "start $2/${5##*/}:$fields governor=$(cat "$CPUFREQ/policy0/scaling_governor" 2>/dev/null) max=$(cat "$CPUFREQ/policy0/scaling_max_freq" 2>/dev/null) gpu_min=$(cat "$GPU/min_freq" 2>/dev/null) $(temps)"
    setsid "$0" watch "$PPID" </dev/null >/dev/null 2>&1 &
    ;;
  gameStop)
    if [ -f "$WATCH" ]; then
      kill "$(cat "$WATCH")" 2>/dev/null
      rm -f "$WATCH"
    fi
    restore "game stopped"
    ;;
  watch)
    # emulatorlauncher ended without gameStop (crash, kill): put the values back
    echo $$ > "$WATCH"
    case "$2" in ''|*[!0-9]*) exit 0 ;; esac
    while kill -0 "$2" 2>/dev/null; do
      sleep 5
    done
    [ "$(cat "$WATCH" 2>/dev/null)" = $$ ] || exit 0
    rm -f "$WATCH"
    restore "emulatorlauncher gone"
    ;;
esac
exit 0
