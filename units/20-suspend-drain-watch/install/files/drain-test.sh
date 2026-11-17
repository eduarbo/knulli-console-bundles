#!/bin/sh
# Unattended suspend-drain measurement for unit 20 (RG35XX-H, Knulli 20260511).
#
#   drain-test.sh arm [cycles] [minutes]   wait (up to 24 h) until the console runs on
#                                          battery with no game, then run the test
#   drain-test.sh status | stop | report
#
# The test suspends <cycles> times (default 2) for <minutes> each (default 60)
# through pm-suspend, the same hooks as the power button, with the RTC armed to wake
# it; unit 20's hook logs the gauge at suspend and resume to
# /userdata/system/logs/suspend-drain.jsonl and its watchdog checks Wi-Fi after each
# resume. Between suspends it stays awake 120 s and records whether the default route
# and SSH came back. It stops early, and says why, when the charger is plugged in,
# the console wakes early (power button), a game starts, or the battery is below
# 25 %. The battery saver is paused for the run only. Unit 01's shutdown alarm is
# not armed by this path (pm-suspend, not knulli-suspend); the test's own RTC alarm
# and the 25 % floor take its place.
# Result: /userdata/system/logs/drain-test-<UTC date>.txt and an ES notice.
R="${UNIT_ROOT:-}"
HERE="$R/userdata/system/suspend-log"
LOG="$R/var/log/drain-test.log"
PIDFILE="$R/var/run/drain-test.pid"
PAUSE="$R/var/run/battery-saver/drain-test.pause"
BATTERY="$R/sys/class/power_supply/axp2202-battery"
RTC=rtc1
ENGINES="retroarch drastic advanced_drastic flycast mupen64plus PPSSPPSDL gzdoom eduke32 grout pico8 pico8_64"

log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }
notify() { curl -s -m 3 http://localhost:1234/notify -d "$1" >/dev/null 2>&1; }
status_now() { cat "$BATTERY/status" 2>/dev/null; }
capacity() { cat "$BATTERY/capacity" 2>/dev/null; }
game_open() { pidof $ENGINES >/dev/null 2>&1 || pgrep -f '[e]mulatorlauncher' >/dev/null 2>&1; }

finish() {
  rm -f "$PAUSE" "$PIDFILE"
  out="$R/userdata/system/logs/drain-test-$(date -u +%Y%m%dT%H%MZ).txt"
  { echo "drain test: $1"; echo; cat "$LOG.run" 2>/dev/null; echo
    python3 "$HERE/drain_report.py" "$R/userdata/system/logs/suspend-drain.jsonl" --since "$RUN_START" 2>&1; } > "$out"
  log "finished: $1 ($out)"
  notify "Prueba de batería: $1"
}

run() {
  cycles=$1 minutes=$2
  RUN_START=$(date +%s)
  : > "$LOG.run"
  mkdir -p "$(dirname "$PAUSE")" && : > "$PAUSE"
  i=1
  while [ "$i" -le "$cycles" ]; do
    [ "$(status_now)" = Discharging ] || { finish "stopped: charger connected"; return; }
    [ "$(capacity)" -ge 25 ] 2>/dev/null || { finish "stopped: battery below 25 %"; return; }
    game_open && { finish "stopped: a game is open"; return; }
    secs=$((minutes * 60))
    echo 0 > "$R/sys/class/rtc/$RTC/wakealarm" 2>/dev/null
    echo enabled > "$R/sys/class/rtc/$RTC/device/power/wakeup" 2>/dev/null
    rtcwake -d "$RTC" -m no -s "$secs" >/dev/null 2>&1 || { finish "stopped: RTC alarm could not be armed"; return; }
    start=$(date +%s)
    log "cycle $i/$cycles suspend for ${secs}s cap=$(capacity)"
    pm-suspend
    echo 0 > "$R/sys/class/rtc/$RTC/wakealarm" 2>/dev/null
    slept=$(( $(date +%s) - start ))
    sleep 120
    line="cycle $i slept=${slept}s cap=$(capacity) route=$( [ -n "$(ip route show default 2>/dev/null)" ] && echo yes || echo no) ssh=$(netstat -ltn 2>/dev/null | grep -q ':22 ' && echo listening || echo no)"
    echo "$line" >> "$LOG.run"
    log "$line"
    if [ "$slept" -lt $((secs - 120)) ]; then
      finish "stopped: woken early after ${slept}s (power button?)"
      return
    fi
    i=$((i + 1))
  done
  finish "done, $cycles suspends of $minutes min"
}

case "${1:-}" in
  arm)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then echo "already armed"; exit 1; fi
    cycles=${2:-2} minutes=${3:-60}
    case "$cycles$minutes" in *[!0-9]*) echo "numbers only"; exit 2 ;; esac
    [ "$cycles" -ge 1 ] && [ "$cycles" -le 8 ] && [ "$minutes" -ge 10 ] && [ "$minutes" -le 180 ] || { echo "1-8 cycles of 10-180 min"; exit 2; }
    setsid /bin/sh "$0" _wait "$cycles" "$minutes" </dev/null >/dev/null 2>&1 &
    echo "armed: $cycles x $minutes min once on battery and idle"
    ;;
  _wait)
    echo $$ > "$PIDFILE"
    log "armed: $2 cycles of $3 min"
    deadline=$(( $(date +%s) + 86400 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      if [ "$(status_now)" = Discharging ] && ! game_open && [ "$(capacity)" -ge 25 ] 2>/dev/null; then
        sleep 60   # unplugged just now: let the gauge settle
        [ "$(status_now)" = Discharging ] && ! game_open && { run "$2" "$3"; exit 0; }
      fi
      sleep 30
    done
    rm -f "$PIDFILE"
    log "gave up: never on battery and idle within 24 h"
    ;;
  stop)
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null
    rm -f "$PIDFILE" "$PAUSE"
    log "stopped by hand"
    echo stopped
    ;;
  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then echo "running (pid $(cat "$PIDFILE"))"; else echo "not running"; fi
    tail -5 "$LOG" 2>/dev/null
    ;;
  report)
    python3 "$HERE/drain_report.py" "$R/userdata/system/logs/suspend-drain.jsonl"
    ;;
  *)
    sed -n '2,19p' "$0"
    exit 2
    ;;
esac
