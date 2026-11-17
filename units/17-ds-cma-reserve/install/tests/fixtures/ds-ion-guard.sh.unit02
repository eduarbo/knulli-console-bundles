#!/bin/sh
# Knulli user script (/userdata/system/scripts, gameStart/gameStop hook) plus
# the boot step of the ds_guard service: DS video memory guard and recovery.
#
# After some long suspends the H700 kernel refuses the ION/CMA buffer that
# advanced_drastic's SDL needs (ION_IOC_ALLOC EPERM, dmesg "platform cma: Fail
# to allocate buffer") and every DS game fails with "could not find entry in
# file" until a reboot. Before each DS game this repeats that allocation
# (ion_check.py). When it is refused with EPERM for advanced_drastic, the
# failing launch is let end, the console reboots through knulli-shutdown -r
# (the power menu's path) once nothing is running, and after boot the same
# game is started again (once ES runs the patched build when unit 07 is
# installed, retried once). At most one such reboot per 30 min; other failures,
# other emulators or system.dsguard.recovery=0 only show the old notice.
#
# emulatorlauncher calls: <gameStart|gameStop> <system> <emulator> <core> <rom>
# internal: rebootWhenIdle | relaunch
R="${UNIT_ROOT:-}"
DIR="$R/userdata/system/ds-guard"
CHECK="$DIR/ion_check.py"
LOG="$R/var/log/ds-ion-guard.log"
PENDING="$R/var/run/ds-guard.reboot"
RELAUNCH="$DIR/relaunch"
LAST="$DIR/last-recovery"
FIRMWARE='scarab 2026/05/11 00:09'
LOOP_SECS=1800
RELAUNCH_SECS=600
ES=http://localhost:1234
ES_PATCHED="$R/userdata/system/es-patched"   # unit 07: it restarts the first ES

log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG" 2>/dev/null; }
notify() { curl -s -m 2 "$ES/notify" -d "$1" >/dev/null 2>&1; }
# Acceptance test aid: this tmpfs file (gone after a reboot) fakes the failure
SIMULATE="$R/var/run/ds-guard.simulate-eperm"
check() {
  if [ -f "$SIMULATE" ]; then
    echo '{"ok": false, "errno": "EPERM", "simulated": true}'
    return 1
  fi
  timeout 5 python3 "$CHECK" 2>&1
}

drop_request() {
  rm -f "$RELAUNCH"
  log "relaunch: $1"
}

api_code() {
  curl -s -o /dev/null -m 2 -w '%{http_code}' "$ES/runningGame"
}

# ES answers with no game running and, with unit 07 installed, is its patched
# build (the stock ES is quit and replaced shortly after boot); 180 s at most
wait_es_ready() {
  local i=0 pid ready
  while [ "$i" -lt 90 ]; do
    ready=""
    for pid in $(pidof emulationstation 2>/dev/null); do
      if [ ! -d "$ES_PATCHED" ] || [ "$(readlink "$R/proc/$pid/exe")" = "$ES_PATCHED/bin/emulationstation" ]; then
        ready=1
      fi
    done
    [ -n "$ready" ] && [ "$(api_code)" = 201 ] && return 0
    i=$((i + 1))
    sleep 2
  done
  return 1
}

# /runningGame says 200 once the game runs; 30 s at most
wait_game_running() {
  local i=0
  while [ "$i" -lt 15 ]; do
    [ "$(api_code)" = 200 ] && return 0
    i=$((i + 1))
    sleep 2
  done
  return 1
}

recovery_allowed() {  # <emulator> <check output>
  [ "$1" = advanced_drastic ] || return 1
  [ "$(knulli-settings-get system.dsguard.recovery 2>/dev/null)" != 0 ] || return 1
  [ "$(cat "$R/usr/share/knulli/knulli.version" 2>/dev/null)" = "$FIRMWARE" ] || return 1
  case "$2" in *'"errno": "EPERM"'*) ;; *) return 1 ;; esac
  last=$(cat "$LAST" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $(( $(date +%s) - last )) -ge "$LOOP_SECS" ]
}

case "$1" in
  gameStart)
    [ "$2" = nds ] || exit 0
    rm -f "$PENDING"
    result=$(check)
    status=$?
    log "status=$status emulator=$3 $result"
    [ "$status" = 0 ] && exit 0
    if recovery_allowed "$3" "$result"; then
      now=$(date +%s)
      printf '%s\n%s\n' "$5" "$now" > "$RELAUNCH.tmp" && mv -f "$RELAUNCH.tmp" "$RELAUNCH"
      echo "$now" > "$LAST"
      sync
      : > "$PENDING"
      log "recovery: reboot once this launch ends, then start $5"
      notify "DS: falta memoria de video. La consola se reiniciará y abrirá el juego sola."
    else
      notify "DS: falta memoria de video tras una suspensión larga. Reinicia la consola para jugar DS."
    fi
    ;;

  gameStop)
    [ "$2" = nds ] && [ -f "$PENDING" ] || exit 0
    rm -f "$PENDING"
    log "recovery: rebooting"
    notify "DS: reiniciando para recuperar la memoria de video..."
    setsid "$0" rebootWhenIdle </dev/null >/dev/null 2>&1 &
    ;;

  rebootWhenIdle)
    # Let emulatorlauncher and the other gameStop hooks finish (60 s at most)
    sleep 3
    i=0
    while [ "$i" -lt 60 ] && pgrep -f '[e]mulatorlauncher|[r]omm_sync\.py|[p]ico8' >/dev/null 2>&1; do
      sleep 1
      i=$((i + 1))
    done
    exec knulli-shutdown -r
    ;;

  relaunch)
    exec 7>"$R/var/run/ds-guard.relaunch.lock"
    flock -n 7 || exit 0
    [ -f "$RELAUNCH" ] || exit 0
    { read -r rom; read -r stamp; } < "$RELAUNCH"
    case "$stamp" in ''|*[!0-9]*) drop_request "unreadable request"; exit 0 ;; esac
    if [ $(( $(date +%s) - stamp )) -gt "$RELAUNCH_SECS" ]; then
      drop_request "request too old"
      exit 0
    fi
    case "$rom" in "$R"/userdata/roms/nds/*) ;; *) drop_request "not a DS ROM: $rom"; exit 0 ;; esac
    [ -f "$rom" ] || { drop_request "missing $rom"; exit 0; }
    for attempt in 1 2; do
      if ! wait_es_ready; then
        log "relaunch: EmulationStation not ready (attempt $attempt), request kept"
        exit 0
      fi
      if [ "$attempt" = 1 ] && ! result=$(check); then
        drop_request "still refused after the reboot: $result"
        notify "DS: la memoria de video sigue sin estar disponible tras reiniciar."
        exit 0
      fi
      sleep 5
      printf '%s' "${rom#$R}" | curl -s -m 5 --data-binary @- "$ES/launch" >/dev/null 2>&1
      if wait_game_running; then
        drop_request "started $rom (attempt $attempt)"
        exit 0
      fi
      log "relaunch: attempt $attempt not confirmed by /runningGame"
    done
    drop_request "no game running after 2 attempts"
    notify "DS: no se pudo abrir el juego tras reiniciar. Ábrelo desde el menú."
    ;;
esac
exit 0
