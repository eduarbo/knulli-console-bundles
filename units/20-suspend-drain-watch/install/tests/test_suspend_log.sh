#!/bin/bash
# Off-device tests of files/suspend-log.sh (Linux: setsid, flock, timeout).
# ip, curl, pidof, pgrep, knulli-settings-get, knulli-shutdown and S08connman are
# stubs over files in $T; the battery is a fake sysfs folder.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../files/suspend-log.sh"
SH=${SH:-sh}
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $*"; }
ko() { fail=$((fail+1)); echo "FAIL $*"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else ko "$1: got '$2' want '$3'"; fi; }

# setup <route back after: self|reload1|reload2|never>
setup() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/sl.XXXXXX")
  mkdir -p "$T/stub" "$T/userdata/system/suspend-log" "$T/userdata/system/logs" "$T/var/run" "$T/var/log" \
    "$T/etc/init.d" "$T/sys/class/power_supply/axp2202-battery"
  B="$T/sys/class/power_supply/axp2202-battery"
  echo 87 > "$B/capacity"; echo 3987000 > "$B/voltage_now"; echo Discharging > "$B/status"; echo 300 > "$B/temp"; echo 50000 > "$B/time_to_empty_now"
  cp "$SRC" "$T/userdata/system/suspend-log/suspend-log.sh"
  echo yes > "$T/route"; echo "$1" > "$T/back"; echo 0 > "$T/reloads"
  cat > "$T/stub/ip" <<S
#!/bin/sh
[ "\$(cat $T/route)" = yes ] && echo 'default via 192.0.2.1 dev wlan0'
exit 0
S
  cat > "$T/etc/init.d/S08connman" <<S
#!/bin/sh
echo "S08connman \$*" >> "$T/calls"
n=\$(( \$(cat $T/reloads) + 1 )); echo \$n > $T/reloads
case "\$(cat $T/back)" in reload1) echo yes > $T/route ;; reload2) [ \$n -ge 2 ] && echo yes > $T/route ;; esac
exit 0
S
  printf '#!/bin/sh\n[ "$(cat %s/route)" = yes ]\n' "$T" > "$T/stub/ping"
  mkdir -p "$T/userdata/system/romm-sync"; printf '#!/bin/sh\necho "autosync $*" >> %s/calls\n' "$T" > "$T/userdata/system/romm-sync/autosync.sh"
  printf '#!/bin/sh\necho S\n' > "$T/stub/ps"
  printf '#!/bin/sh\necho "curl $*" >> %s/calls\nexit 0\n' "$T" > "$T/stub/curl"
  printf '#!/bin/sh\necho "knulli-shutdown $*" >> %s/calls\nexit 0\n' "$T" > "$T/stub/knulli-shutdown"
  printf '#!/bin/sh\ncase "$*" in *emulationstation*) echo 77; exit 0 ;; esac\n[ -f %s/game ] && echo 123 && exit 0\nexit 1\n' "$T" > "$T/stub/pidof"
  printf '#!/bin/sh\nexit 1\n' > "$T/stub/pgrep"
  printf '#!/bin/sh\ngrep "^$1=" %s/conf 2>/dev/null | cut -d= -f2\n' "$T" > "$T/stub/knulli-settings-get"
  echo 'wifi.enabled=1' > "$T/conf"
  chmod +x "$T/stub/"* "$T/etc/init.d/S08connman"
  export UNIT_ROOT="$T" PATH="$T/stub:$PATH" SUSPEND_LOG_FIRST_WAIT=2 SUSPEND_LOG_STEP_WAIT=1
}
run() { $SH "$T/userdata/system/suspend-log/suspend-log.sh" "$@"; }
settle() { i=0; while pgrep_real && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; sleep 0.3; }
pgrep_real() { /usr/bin/pgrep -f "$T/userdata/system/suspend-log/suspend-log.sh watch" >/dev/null 2>&1; }
cleanup() { /usr/bin/pkill -f "$T/userdata" 2>/dev/null; rm -rf "$T"; }
drain() { cat "$T/userdata/system/logs/suspend-drain.jsonl"; }

# 1 normal: lines logged, Wi-Fi back by itself, no ConnMan restart
setup self
run suspend; echo no > "$T/route"; run resume; ( sleep 1; echo yes > "$T/route" ) & settle
[ "$(grep -c '"ev": "suspend".*"cap": 87.*"uv": 3987000.*"tte": 50000.*"route": true' "$T/userdata/system/logs/suspend-drain.jsonl")" = 1 ] && ok "suspend line" || ko "drain: $(drain)"
[ "$(grep -c '"ev": "resume".*"route": false' "$T/userdata/system/logs/suspend-drain.jsonl")" = 1 ] && ok "resume line" || ko "drain: $(drain)"
grep -q 'watch: link back' "$T/var/log/suspend-log.log" && ok "route back logged" || ko "log: $(cat "$T/var/log/suspend-log.log" 2>/dev/null)"
check "no ConnMan restart when Wi-Fi comes back" "$(cat "$T/reloads")" 0
cleanup

# 2 Wi-Fi does not come back: first ConnMan restart fixes it
setup reload1
run suspend; echo no > "$T/route"; run resume; settle
grep -q 'link back after ConnMan restart 1' "$T/var/log/suspend-log.log" && ok "restart 1 recovers" || ko "log: $(cat "$T/var/log/suspend-log.log")"
grep -q 'S08connman reload' "$T/calls" && ok "restart is S08connman reload (ES switch path)" || ko "calls"
cleanup

# 3 second restart needed
setup reload2
run suspend; echo no > "$T/route"; run resume; settle
check "two restarts" "$(cat "$T/reloads")" 2
grep -q 'link back after ConnMan restart 2' "$T/var/log/suspend-log.log" && ok "restart 2 recovers" || ko "log: $(cat "$T/var/log/suspend-log.log")"
cleanup

# 4 simulate file: route present, first wait still fails once, restart, route
setup reload1
: > "$T/var/run/suspend-log.simulate-no-route"
run suspend; run resume; settle
grep -q 'simulated missing route' "$T/var/log/suspend-log.log" && grep -q 'link back after ConnMan restart 1' "$T/var/log/suspend-log.log" && ok "simulated fault exercises restart 1" || ko "log: $(cat "$T/var/log/suspend-log.log")"
[ ! -e "$T/var/run/suspend-log.simulate-no-route" ] && ok "simulate file consumed" || ko "simulate file left"
cleanup

# 5 nothing helps, no game: reboot once, stamp written
setup never
run suspend; echo no > "$T/route"; run resume; settle; sleep 5.5; settle
grep -q 'knulli-shutdown -r' "$T/calls" && ok "reboot as last step" || ko "calls: $(tr '\n' ';' < "$T/calls")"
[ -s "$T/userdata/system/suspend-log/last-watchdog-reboot" ] && ok "reboot stamp" || ko "no stamp"
cleanup

# 6 nothing helps, a game is open: no reboot, notice
setup never
: > "$T/game"
run suspend; echo no > "$T/route"; run resume; settle
! grep -q 'knulli-shutdown' "$T/calls" && grep -q 'curl .*notify' "$T/calls" && ok "game open: notice, no reboot" || ko "calls: $(tr '\n' ';' < "$T/calls")"
cleanup

# 7 nothing helps, watchdog rebooted 1 h ago: no second reboot
setup never
echo $(( $(date +%s) - 3600 )) > "$T/userdata/system/suspend-log/last-watchdog-reboot"
run suspend; echo no > "$T/route"; run resume; settle
! grep -q 'knulli-shutdown' "$T/calls" && ok "no reboot loop" || ko "rebooted again"
cleanup

# 8 no watcher when switched off, Wi-Fi disabled, or no route before suspend
for case_ in 'system.suspend.wifiwatch=0' 'wifi.enabled=0' 'noroute'; do
  setup never
  case "$case_" in noroute) echo no > "$T/route" ;; *) echo "$case_" > "$T/conf" ;; esac
  run suspend; echo no > "$T/route"; run resume; settle
  check "no watchdog when $case_" "$(cat "$T/reloads")" 0
  cleanup
done

# 9 always exit 0
setup self
rm -f "$T/stub/ip"; printf '#!/bin/sh\nexit 7\n' > "$T/stub/ip"; chmod +x "$T/stub/ip"
run suspend; check "suspend exits 0" "$?" 0
run resume; check "resume exits 0" "$?" 0
cleanup
# 10 after a suspend of 2 min or more the RomM quick sync starts once the link is back
setup self
run suspend; echo $(( $(date +%s) - 300 )) > "$T/var/run/suspend-log/suspend-at"; run resume; settle; sleep 0.5
grep -q 'autosync quick' "$T/calls" && grep -q 'RomM quick sync started' "$T/var/log/suspend-log.log" && ok "quick sync after a long suspend" || ko "calls: $(tr '\n' ';' < "$T/calls" 2>/dev/null)"
cleanup
setup self
run suspend; run resume; settle; sleep 0.5
! grep -q 'autosync' "$T/calls" 2>/dev/null && ok "no quick sync after a short suspend" || ko "quick after short suspend"
cleanup
setup self
: > "$T/game"
run suspend; echo $(( $(date +%s) - 300 )) > "$T/var/run/suspend-log/suspend-at"; run resume; settle; sleep 0.5
! grep -q 'autosync quick' "$T/calls" 2>/dev/null && grep -q 'left to the autosync daemon' "$T/var/log/suspend-log.log" && ok "no quick sync while a game is open" || ko "quick during game"
cleanup
echo "passed=$pass failed=$fail"; [ "$fail" = 0 ]
