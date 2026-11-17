#!/bin/bash
# Off-device tests for files/knulli-suspend (and the stock Scarab script for
# comparison). The script runs with its absolute paths redirected into a
# sandbox; pm-suspend, rtcwake, knulli-shutdown and the clock are stubs, and
# two real "sleep" processes stand in for paused emulators.
# Usage: tests/test_knulli_suspend.sh [stock knulli-suspend, default fixtures/]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
NEW="$HERE/../files/knulli-suspend"
STOCK=${1:-$HERE/fixtures/knulli-suspend.stock}
SHELLS="/bin/dash /bin/bash"
pass=0; fail=0

# run <script> <shell> <wake> [key=value ...] -> sets OUT (log) and WAKE_LEFT
# wake: alarm | button:<secs> ; extra pseudo-keys: battery=<status>:<capacity>,
# rtcfail=1, stopped=1 (two paused nice -4 "retroarch" processes exist),
# game=<comm> (a nice -4 process), running=<name> (pidof finds it),
# launcher=1 (an emulatorlauncher process exists)
run() {
  local script=$1 sh=$2 wake=$3; shift 3
  T=$(mktemp -d "${TMPDIR:-/tmp}/ksus.XXXXXX")
  mkdir -p "$T/stub" "$T/run" "$T/log" "$T/conf" "$T/initd" "$T/ps/axp2202-battery" "$T/ps/axp2202-usb"
  for r in rtc0 rtc1; do mkdir -p "$T/rtc/$r/device/power"; : > "$T/rtc/$r/wakealarm"; : > "$T/rtc/$r/device/power/wakeup"; done
  echo 1000000 > "$T/clock"
  echo Battery > "$T/ps/axp2202-battery/type"; echo USB > "$T/ps/axp2202-usb/type"
  echo Discharging > "$T/ps/axp2202-battery/status"; echo 80 > "$T/ps/axp2202-battery/capacity"
  local rtcfail=0 stopped=0 kv
  for kv in "$@"; do
    case "$kv" in
      battery=*) v=${kv#battery=}; echo "${v%%:*}" > "$T/ps/axp2202-battery/status"; echo "${v#*:}" > "$T/ps/axp2202-battery/capacity" ;;
      rtcfail=1) rtcfail=1 ;;
      stopped=1) stopped=1 ;;
      game=*) printf -- '-4 %s\n' "${kv#game=}" >> "$T/ps.comm" ;;
      running=*) echo "${kv#running=}" >> "$T/running" ;;
      launcher=1) : > "$T/launcher" ;;
      *) printf '%s\n' "${kv#*=}" > "$T/conf/${kv%%=*}" ;;
    esac
  done
  : > "$T/ps.list"; touch "$T/ps.comm" "$T/running"
  if [ "$stopped" = 1 ]; then
    sleep 300 & P1=$!; sleep 300 & P2=$!
    kill -STOP "$P1" "$P2"
    printf '%s -4\n%s -4\n%s 0\n' "$P1" "$P2" "$$" > "$T/ps.list"
    printf -- '-4 retroarch\n-4 retroarch\n' >> "$T/ps.comm"
  fi
  cat > "$T/stub/knulli-settings-get" <<S
#!/bin/sh
[ -f "$T/conf/\$1" ] && cat "$T/conf/\$1"
exit 0
S
  cat > "$T/stub/date" <<S
#!/bin/sh
if [ "\$1" = "+%s" ]; then cat "$T/clock"; else /bin/date "\$@"; fi
S
  cat > "$T/stub/rtcwake" <<S
#!/bin/sh
[ $rtcfail = 1 ] && exit 1
echo "rtcwake \$*" >> "$T/calls"; echo "\$6" > "$T/armed"
S
  cat > "$T/stub/pm-suspend" <<S
#!/bin/sh
echo pm-suspend >> "$T/calls"; now=\$(cat "$T/clock")
case "$wake" in
  alarm) secs=\$(cat "$T/armed" 2>/dev/null || echo 3600); echo \$(( now + secs + 3 )) > "$T/clock" ;;
  button:*) echo \$(( now + ${wake#button:} )) > "$T/clock" ;;
esac
S
  printf '#!/bin/sh\nexit 0\n' > "$T/stub/pm-is-supported"
  printf '#!/bin/sh\nexit 0\n' > "$T/stub/flock"
  printf '#!/bin/sh\nexit 0\n' > "$T/stub/sleep"
  printf '#!/bin/sh\necho "knulli-shutdown $*" >> %s/calls\n' "$T" > "$T/stub/knulli-shutdown"
  cat > "$T/stub/ps" <<S
#!/bin/sh
case "\$*" in
  "-eo pid,ni") cat "$T/ps.list" ;;
  "-eo ni=,comm=") printf '  0 init\n'; cat "$T/ps.comm" ;;
  *) exec /bin/ps "\$@" ;;
esac
S
  printf '#!/bin/sh\ngrep -qx "$1" %s/running\n' "$T" > "$T/stub/pidof"
  printf '#!/bin/sh\n[ -f %s/launcher ]\n' "$T" > "$T/stub/pgrep"
  printf '#!/bin/sh\necho "S31 $*" >> %s/calls\n' "$T" > "$T/initd/S31emulationstation"
  chmod +x "$T"/stub/* "$T/initd/S31emulationstation"
  sed -e "s#/usr/bin/knulli-settings-get#$T/stub/knulli-settings-get#g" \
      -e "s#/var/run/#$T/run/#g" -e "s#/var/log/#$T/log/#g" \
      -e "s#/etc/init.d/#$T/initd/#g" -e "s#/sys/class/rtc/#$T/rtc/#g" \
      -e "s#/sys/class/power_supply/#$T/ps/#g" "$script" > "$T/knulli-suspend"
  PATH="$T/stub:$PATH" "$sh" "$T/knulli-suspend" 2>"$T/stderr"
  OUT="$(tr '\n' ';' 2>/dev/null < "$T/calls") | $(tr '\n' ';' 2>/dev/null < "$T/log/knulli-suspend.log" | sed -E 's/[0-9T:-]+Z //g') | stderr=$(tr '\n' ';' < "$T/stderr")"
  WAKE_LEFT=$(cat "$T/run/rtc-wake.epoch" 2>/dev/null || echo none)
  RESUMED=""
  if [ "$stopped" = 1 ]; then
    RESUMED="$(ps -o stat= -p "$P1" | cut -c1)$(ps -o stat= -p "$P2" | cut -c1)"
    kill -CONT "$P1" "$P2" 2>/dev/null; kill "$P1" "$P2" 2>/dev/null; wait "$P1" "$P2" 2>/dev/null
  fi
  rm -rf "$T"
}

check() {  # <name> <substring expected in OUT, or !substring for absent>...
  local name=$1; shift
  local ok=1 e
  for e in "$@"; do
    case "$e" in
      !*) case "$OUT" in *"${e#!}"*) ok=0 ;; esac ;;
      *) case "$OUT" in *"$e"*) ;; *) ok=0 ;; esac ;;
    esac
  done
  case "$OUT" in *stderr=?*) ok=0 ;; esac
  if [ "$ok" = 1 ]; then pass=$((pass+1)); echo "PASS $name"; else fail=$((fail+1)); echo "FAIL $name :: $OUT"; fi
}

DEFAULTS="system.batterysaver.mode=dim system.batterysaver.extendedmode=suspend system.idlewatcher.timer=300 system.idlewatcher.extendedtimer=900"
for sh in $SHELLS; do
  s=$(basename "$sh")
  run "$NEW" "$sh" alarm $DEFAULTS
  check "$s default 3h timer, no game, alarm -> graceful shutdown" "rtcwake -d rtc1 -m no -s 10800" "shutdown alarm in 10800s (suspend timer, game: none)" "S31 resume" "knulli-shutdown -s" "woken by the shutdown alarm (suspend timer, game: none)"
  run "$NEW" "$sh" button:3600 $DEFAULTS
  check "$s default timer, user wakes after 1h -> no shutdown" "-s 10800" "!knulli-shutdown" "!woken by"
  [ "$WAKE_LEFT" = none ] && check "$s wake epoch cleared after a manual wake" || { fail=$((fail+1)); echo "FAIL $s wake epoch left: $WAKE_LEFT"; }
  run "$NEW" "$sh" alarm $DEFAULTS system.suspend.shutdowntimer=7200
  check "$s timer 2h from knulli.conf" "-s 7200" "(suspend timer, game: none)" "knulli-shutdown -s"
  run "$NEW" "$sh" button:60 $DEFAULTS system.suspend.shutdowntimer=0 system.suspend.shutdownbattery=0
  check "$s both off -> no alarm, like stock" "pm-suspend" "!rtcwake" "!knulli-shutdown"
  run "$NEW" "$sh" alarm $DEFAULTS battery=Discharging:20
  check "$s 20% battery -> battery floor sooner" "-s 9000" "(battery floor, 20% now)" "knulli-shutdown -s"
  run "$NEW" "$sh" alarm $DEFAULTS battery=Discharging:4
  check "$s 4% battery -> minimum 300s" "-s 300" "(battery floor, 4% now)"
  run "$NEW" "$sh" alarm $DEFAULTS battery=Charging:20
  check "$s charging -> no timer, no floor" "pm-suspend" "!rtcwake" "!knulli-shutdown" "no suspend timer or battery floor (battery: Charging)"
  run "$NEW" "$sh" alarm $DEFAULTS battery=Full:100
  check "$s full on charger -> no alarm" "!rtcwake" "(battery: Full)"
  run "$NEW" "$sh" alarm system.batterysaver.mode=dim system.batterysaver.extendedmode=shutdown system.idlewatcher.timer=300 system.idlewatcher.extendedtimer=900 battery=Charging:50
  check "$s charging keeps the stock battery-saver shutdown" "-s 1200" "(battery saver)"
  run "$NEW" "$sh" alarm $DEFAULTS game=retroarch
  check "$s RetroArch open -> timer applies" "-s 10800" "(suspend timer, game: retroarch)" "knulli-shutdown -s"
  run "$NEW" "$sh" alarm $DEFAULTS game=drastic
  check "$s DraStic open -> no timer, floor only" "-s 45000" "(battery floor, 80% now)" "the open game may not save"
  run "$NEW" "$sh" alarm $DEFAULTS game=retroarch game=drastic
  check "$s RetroArch plus another emulator -> no timer" "-s 45000" "the open game may not save"
  run "$NEW" "$sh" alarm $DEFAULTS running=pico8_64
  check "$s PICO-8 open -> no timer" "-s 45000" "the open game may not save"
  run "$NEW" "$sh" alarm $DEFAULTS launcher=1
  check "$s unknown emulator under emulatorlauncher -> no timer" "-s 45000" "the open game may not save"
  run "$NEW" "$sh" alarm $DEFAULTS game=drastic battery=Discharging:20
  check "$s DraStic open at 20% -> floor still applies" "-s 9000" "(battery floor, 20% now)" "knulli-shutdown -s"
  run "$NEW" "$sh" alarm $DEFAULTS game=drastic system.suspend.shutdownbattery=0
  check "$s DraStic open, floor off -> no alarm" "!rtcwake" "!knulli-shutdown"
  run "$NEW" "$sh" alarm $DEFAULTS battery=Discharging:20 system.suspend.shutdownbattery=0
  check "$s battery floor off" "-s 10800"
  run "$NEW" "$sh" alarm system.batterysaver.mode=dim system.batterysaver.extendedmode=shutdown system.idlewatcher.timer=300 system.idlewatcher.extendedtimer=900
  check "$s battery saver shutdown sooner wins" "-s 1200" "(battery saver)" "knulli-shutdown -s"
  run "$NEW" "$sh" alarm $DEFAULTS system.suspend.shutdowntimer=abc
  check "$s invalid timer -> default" "-s 10800"
  run "$NEW" "$sh" alarm $DEFAULTS rtcfail=1
  check "$s no RTC -> no alarm, no shutdown" "could not arm" "!knulli-shutdown"
  run "$NEW" "$sh" alarm $DEFAULTS stopped=1
  check "$s paused RetroArch resumed before shutdown" "(suspend timer, game: retroarch)" "knulli-shutdown -s"
  case "$RESUMED" in [SR][SR]) pass=$((pass+1)); echo "PASS $s paused processes running again ($RESUMED)" ;; *) fail=$((fail+1)); echo "FAIL $s paused processes state: $RESUMED" ;; esac
  if [ -n "$STOCK" ]; then
    run "$STOCK" "$sh" button:60 $DEFAULTS
    check "$s stock: no alarm with these settings" "!rtcwake" "!knulli-shutdown"
    run "$STOCK" "$sh" alarm system.batterysaver.mode=dim system.batterysaver.extendedmode=shutdown system.idlewatcher.timer=300 system.idlewatcher.extendedtimer=900
    check "$s stock: battery saver shutdown 1200s" "-s 1200" "knulli-shutdown -s"
  fi
done
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
