#!/bin/sh
# Unit 20 (RG35XX-H, Knulli scarab 2026/05/11): battery log at every suspend and
# resume, and a Wi-Fi watchdog after every resume. Called by the pm-utils hook
# /etc/pm/sleep.d/05suspend-log (put there at boot by the suspend_log service),
# so it runs for every suspend: power button, menu, idle, lid, RTC tests.
#
#   suspend   one JSON line of the gauge to /userdata/system/logs/suspend-drain.jsonl
#   resume    the same, then the watchdog (detached) when Wi-Fi had a route before
#   watch     the watchdog: wait until the default route's gateway answers a ping;
#             if it does not,
#             restart ConnMan the way the ES menu's Wi-Fi switch does
#             (S08connman reload: fresh connmand, then "enable wifi" and scans),
#             again after 60 s; if there is still no route, no game is open and no
#             watchdog reboot happened in the last 6 h, reboot through
#             knulli-shutdown -r (the boot path always brought Wi-Fi up). Once
#             the link is back after a suspend of 2 min or more, it starts a RomM
#             quick sync (romm-sync/autosync.sh quick) when ES is not frozen and no
#             game runs: the autosync daemon's own "after a resume" test compares
#             date with /proc/uptime, and on this kernel both include suspended time
#   status    one line
#
# The radios are not touched for suspend: the 8821cs driver already disconnects
# and powers the chip down itself (VALIDATION.md). Every path exits 0, so a
# suspend is never refused because of this hook. system.suspend.wifiwatch=0
# turns the watchdog off; the log stays.
R="${UNIT_ROOT:-}"
RUN="$R/var/run/suspend-log"
LOG="$R/var/log/suspend-log.log"
DRAIN="$R/userdata/system/logs/suspend-drain.jsonl"
BATTERY="$R/sys/class/power_supply/axp2202-battery"
ME="$R/userdata/system/suspend-log/suspend-log.sh"
LAST_REBOOT="$R/userdata/system/suspend-log/last-watchdog-reboot"
FIRST_WAIT=${SUSPEND_LOG_FIRST_WAIT:-60}    # s for the driver's own reconnect
STEP_WAIT=${SUSPEND_LOG_STEP_WAIT:-60}      # s after each ConnMan restart
SIMULATE="$R/var/run/suspend-log.simulate-no-route"   # test aid: first wait fails
ENGINES="retroarch drastic advanced_drastic flycast mupen64plus PPSSPPSDL gzdoom eduke32 grout pico8 pico8_64"

log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG" 2>/dev/null; }
up() { cut -d ' ' -f 1 "$R/proc/uptime" 2>/dev/null || cut -d ' ' -f 1 /proc/uptime; }
since() { awk -v a="$1" -v b="$(up)" 'BEGIN { printf "%.0f", b - a }'; }
notify() { curl -s -m 3 http://localhost:1234/notify -d "$1" >/dev/null 2>&1; }
setting() { timeout 3 knulli-settings-get "$1" 2>/dev/null; }
has_route() { [ -n "$(ip route show default 2>/dev/null)" ]; }
link_ok() {  # default route and its gateway answers (a stale route is not enough)
  gw=$(ip route show default 2>/dev/null | awk '$1 == "default" { print $3; exit }')
  [ -n "$gw" ] && ping -c 1 -W 2 "$gw" >/dev/null 2>&1
}
AUTOSYNC="$R/userdata/system/romm-sync/autosync.sh"
es_frozen() { p=$(pidof emulationstation 2>/dev/null | awk '{ print $1 }'); [ -z "$p" ] || [ "$(ps -o stat= -p "$p" 2>/dev/null | cut -c1)" = T ]; }
kick_autosync() {
  at=$(cat "$RUN/suspend-at" 2>/dev/null)
  case "$at" in ''|*[!0-9]*) return 0 ;; esac
  [ $(( $(date +%s) - at )) -ge 120 ] && [ -f "$AUTOSYNC" ] || return 0
  if game_open || es_frozen; then
    log "watch: RomM quick sync left to the autosync daemon (game open or ES frozen)"
    return 0
  fi
  setsid /bin/sh "$AUTOSYNC" quick </dev/null >/dev/null 2>&1 &
  log "watch: RomM quick sync started after resume"
}
game_open() { pidof $ENGINES >/dev/null 2>&1 || pgrep -f '[e]mulatorlauncher' >/dev/null 2>&1; }

record() {  # <suspend|resume>
  printf '{"ev": "%s", "t": %s, "up": %s, "boot": "%s", "cap": %s, "uv": %s, "status": "%s", "temp": %s, "tte": %s, "route": %s}\n' \
    "$1" "$(date +%s)" "$(up)" "$(cat "$R/proc/sys/kernel/random/boot_id" 2>/dev/null || cat /proc/sys/kernel/random/boot_id)" \
    "$(cat "$BATTERY/capacity" 2>/dev/null || echo null)" "$(cat "$BATTERY/voltage_now" 2>/dev/null || echo null)" \
    "$(cat "$BATTERY/status" 2>/dev/null)" "$(cat "$BATTERY/temp" 2>/dev/null || echo null)" \
    "$(cat "$BATTERY/time_to_empty_now" 2>/dev/null || echo null)" "$(has_route && echo true || echo false)" >> "$DRAIN" 2>/dev/null
}

wait_route() {  # <seconds>; the simulate file makes the first wait fail once
  if [ -f "$SIMULATE" ]; then
    rm -f "$SIMULATE"
    log "watch: simulated missing route"
    return 1
  fi
  i=0
  while [ "$i" -lt "$1" ]; do
    link_ok && return 0
    sleep 1
    i=$((i + 1))
  done
  link_ok
}

watch() {
  exec 8> "$R/var/run/suspend-log.lock"
  flock -n 8 || exit 0
  t=$(up)
  if wait_route "$FIRST_WAIT"; then
    log "watch: link back $(since "$t")s after resume"
    kick_autosync
    return 0
  fi
  for step in 1 2; do
    log "watch: no link $(since "$t")s after resume; ConnMan restart $step (as the ES Wi-Fi switch)"
    timeout 60 "$R/etc/init.d/S08connman" reload >/dev/null 2>&1
    if wait_route "$STEP_WAIT"; then
      log "watch: link back after ConnMan restart $step, $(since "$t")s after resume"
      kick_autosync
      return 0
    fi
  done
  last=$(cat "$LAST_REBOOT" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if game_open; then
    log "watch: FAILED, no link $(since "$t")s after resume; a game is open, no reboot"
    notify "Wi-Fi no volvió tras suspender; apágalo y préndelo en el menú de red."
  elif [ $(( $(date +%s) - last )) -lt 21600 ]; then
    log "watch: FAILED, no link $(since "$t")s after resume; watchdog rebooted less than 6 h ago"
    notify "Wi-Fi no volvió tras suspender; apágalo y préndelo en el menú de red."
  else
    date +%s > "$LAST_REBOOT"
    sync
    log "watch: no link $(since "$t")s after resume; rebooting"
    notify "Wi-Fi no volvió tras suspender: reiniciando."
    sleep 5
    knulli-shutdown -r
  fi
}

case "${1:-}" in
  suspend|hibernate)
    mkdir -p "$RUN"
    has_route && : > "$RUN/route-before" || rm -f "$RUN/route-before"
    date +%s > "$RUN/suspend-at"
    record suspend
    ;;
  resume|thaw)
    record resume
    if [ -f "$RUN/route-before" ] && [ "$(setting system.suspend.wifiwatch)" != 0 ] &&
       [ "$(setting wifi.enabled)" = 1 ]; then
      setsid /bin/sh "$ME" watch </dev/null >/dev/null 2>&1 &
    fi
    ;;
  watch)
    watch
    ;;
  status)
    echo "route=$(has_route && echo yes || echo no) watchdog=$([ "$(setting system.suspend.wifiwatch)" = 0 ] && echo off || echo on) log_lines=$(cat "$DRAIN" 2>/dev/null | wc -l)"
    ;;
esac
exit 0
