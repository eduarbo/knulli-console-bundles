#!/bin/bash
# Off-device tests of files/ds-ion-guard.sh: python3 (ion_check), curl (ES
# API), pgrep, setsid, timeout, knulli-shutdown and the clock are stubs.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GUARD="$HERE/../files/ds-ion-guard.sh"
SHELLS="/bin/dash /bin/bash"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $*"; }
ko() { fail=$((fail+1)); echo "FAIL $*"; }

# setup <check result: ok|EPERM|EINVAL> [now]
# ES API stub: /runningGame is 201 until /launch was posted $T/launch_ok_after
# times (default 1), then 200; "echo 0 > $T/launch_ok_after" = never
setup() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/dsg.XXXXXX")
  mkdir -p "$T/stub" "$T/userdata/system/ds-guard" "$T/userdata/system/scripts" "$T/userdata/roms/nds" "$T/var/log" "$T/var/run" "$T/usr/share/knulli"
  echo 'scarab 2026/05/11 00:09' > "$T/usr/share/knulli/knulli.version"
  : > "$T/userdata/roms/nds/Mega Man ZX.zip"
  echo "${2:-2000000000}" > "$T/clock"
  case "$1" in
    ok) printf '#!/bin/sh\necho "{\\"ok\\": true, \\"cma_free_kb\\": 49152}"\nexit 0\n' > "$T/stub/python3" ;;
    *) printf '#!/bin/sh\necho "{\\"ok\\": false, \\"errno\\": \\"%s\\", \\"cma_free_kb\\": 63000}"\nexit 1\n' "$1" > "$T/stub/python3" ;;
  esac
  cat > "$T/stub/date" <<S
#!/bin/sh
if [ "\$1" = "+%s" ]; then cat "$T/clock"; else /bin/date "\$@"; fi
S
  cat > "$T/stub/curl" <<S
#!/bin/sh
for a in "\$@"; do case "\$a" in http://*) url=\$a ;; esac; done
case "\$url" in
  */runningGame) if [ -f "$T/game_running" ]; then printf 200; else printf 201; fi ;;
  */launch) printf 'launch:%s\n' "\$(cat)" >> "$T/calls"
    n=\$(( \$(cat "$T/launches" 2>/dev/null || echo 0) + 1 )); echo \$n > "$T/launches"
    ok=\$(cat "$T/launch_ok_after" 2>/dev/null || echo 1)
    [ "\$ok" != 0 ] && [ "\$n" -ge "\$ok" ] && : > "$T/game_running" ;;
  */notify) printf 'notify:%s\n' "\$*" >> "$T/calls" ;;
esac
S
  printf '#!/bin/sh\nshift; exec "$@"\n' > "$T/stub/timeout"
  printf '#!/bin/sh\necho "setsid $*" >> %s/calls\n' "$T" > "$T/stub/setsid"
  printf '#!/bin/sh\nexit 1\n' > "$T/stub/pgrep"
  printf '#!/bin/sh\necho 4242\n' > "$T/stub/pidof"
  command -v flock >/dev/null 2>&1 || printf '#!/bin/sh\nexit 0\n' > "$T/stub/flock"
  printf '#!/bin/sh\nexit 0\n' > "$T/stub/sleep"
  printf '#!/bin/sh\nexit 0\n' > "$T/stub/sync"
  printf '#!/bin/sh\necho "knulli-shutdown $*" >> %s/calls\n' "$T" > "$T/stub/knulli-shutdown"
  printf '#!/bin/sh\n[ -f %s/recovery ] && cat %s/recovery\nexit 0\n' "$T" "$T" > "$T/stub/knulli-settings-get"
  chmod +x "$T"/stub/*
  cp "$GUARD" "$T/userdata/system/scripts/ds-ion-guard.sh"; chmod +x "$T/userdata/system/scripts/ds-ion-guard.sh"
  ROM="$T/userdata/roms/nds/Mega Man ZX.zip"
}
g() { UNIT_ROOT="$T" PATH="$T/stub:$PATH" "$sh" "$T/userdata/system/scripts/ds-ion-guard.sh" "$@"; }
calls() { cat "$T/calls" 2>/dev/null; }

for sh in $SHELLS; do
  s=$(basename "$sh")
  setup EPERM; g gameStart snes retroarch snes9x "$ROM"
  [ -z "$(calls)" ] && [ ! -e "$T/var/log/ds-ion-guard.log" ] && ok "$s other systems ignored" || ko "$s other system: $(calls)"; rm -rf "$T"

  setup ok; g gameStart nds advanced_drastic advanced_drastic "$ROM"
  [ -z "$(calls)" ] && grep -q 'status=0' "$T/var/log/ds-ion-guard.log" && ok "$s check ok: no notice" || ko "$s ok path: $(calls)"; rm -rf "$T"

  setup EPERM; g gameStart nds advanced_drastic advanced_drastic "$ROM"
  [ -f "$T/var/run/ds-guard.reboot" ] && [ "$(head -1 "$T/userdata/system/ds-guard/relaunch")" = "$ROM" ] && grep -q 'reiniciará' "$T/calls" && ok "$s EPERM: recovery planned, ROM recorded" || ko "$s EPERM plan: $(calls)"
  g gameStop nds advanced_drastic advanced_drastic "$ROM"
  for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q setsid "$T/calls" && break; /bin/sleep 0.2; done
  [ ! -f "$T/var/run/ds-guard.reboot" ] && grep -q 'setsid .*ds-ion-guard.sh rebootWhenIdle' "$T/calls" && ok "$s gameStop: detached reboot started" || ko "$s gameStop: $(calls)"
  g rebootWhenIdle
  grep -q 'knulli-shutdown -r' "$T/calls" && ok "$s reboot goes through knulli-shutdown -r" || ko "$s reboot path: $(calls)"
  echo 2000000300 > "$T/clock"; : > "$T/calls"
  printf '#!/bin/sh\necho "{\\"ok\\": true}"\nexit 0\n' > "$T/stub/python3"   # fresh boot: allocation works
  g relaunch
  [ "$(grep -c "launch:/userdata/roms/nds/Mega Man ZX.zip" "$T/calls")" = 1 ] && [ ! -e "$T/userdata/system/ds-guard/relaunch" ] && grep -q 'started .*(attempt 1)' "$T/var/log/ds-ion-guard.log" && ok "$s after boot: same game launched once, confirmed" || ko "$s relaunch: $(calls)"
  : > "$T/calls"; g relaunch; [ -z "$(calls)" ] && ok "$s relaunch is one-shot" || ko "$s relaunch repeated"
  printf '#!/bin/sh\necho "{\\"ok\\": false, \\"errno\\": \\"EPERM\\"}"\nexit 1\n' > "$T/stub/python3"
  echo 2000000600 > "$T/clock"; : > "$T/calls"; g gameStart nds advanced_drastic advanced_drastic "$ROM"
  [ ! -f "$T/var/run/ds-guard.reboot" ] && grep -q 'Reinicia la consola' "$T/calls" && ok "$s second failure within 30 min: notice only" || ko "$s loop guard: $(calls)"
  rm -rf "$T"

  setup EINVAL; g gameStart nds advanced_drastic advanced_drastic "$ROM"
  [ ! -f "$T/var/run/ds-guard.reboot" ] && grep -q 'Reinicia la consola' "$T/calls" && ok "$s other errno: notice only" || ko "$s EINVAL: $(calls)"; rm -rf "$T"

  setup EPERM; g gameStart nds libretro melonds "$ROM"
  [ ! -f "$T/var/run/ds-guard.reboot" ] && ok "$s other emulator: no reboot" || ko "$s other emulator"; rm -rf "$T"

  setup EPERM; echo 0 > "$T/recovery"; g gameStart nds advanced_drastic advanced_drastic "$ROM"
  [ ! -f "$T/var/run/ds-guard.reboot" ] && ok "$s system.dsguard.recovery=0: no reboot" || ko "$s recovery off"; rm -rf "$T"

  setup EPERM; echo 'scarab 2026/09/01 00:00' > "$T/usr/share/knulli/knulli.version"; g gameStart nds advanced_drastic advanced_drastic "$ROM"
  [ ! -f "$T/var/run/ds-guard.reboot" ] && ok "$s other firmware: no reboot" || ko "$s other firmware"; rm -rf "$T"

  setup ok; g gameStop nds advanced_drastic advanced_drastic "$ROM"
  [ -z "$(calls)" ] && ok "$s gameStop without a pending recovery does nothing" || ko "$s gameStop idle"; rm -rf "$T"

  setup ok; printf '%s\n%s\n' "$ROM" 1999999000 > "$T/userdata/system/ds-guard/relaunch"; g relaunch
  [ -z "$(calls)" ] && [ ! -e "$T/userdata/system/ds-guard/relaunch" ] && ok "$s stale relaunch dropped" || ko "$s stale relaunch: $(calls)"; rm -rf "$T"

  setup EPERM; printf '%s\n%s\n' "$ROM" 2000000000 > "$T/userdata/system/ds-guard/relaunch"; g relaunch
  ! grep -q launch: "$T/calls" && grep -q 'sigue sin' "$T/calls" && ok "$s still refused after boot: notice, no launch" || ko "$s refused relaunch: $(calls)"; rm -rf "$T"

  setup ok; printf '%s\n%s\n' "$T/userdata/system/knulli.conf" 2000000000 > "$T/userdata/system/ds-guard/relaunch"; g relaunch
  ! grep -q launch: "$T/calls" 2>/dev/null && ok "$s relaunch outside roms/nds refused" || ko "$s path check"; rm -rf "$T"
  setup ok; : > "$T/var/run/ds-guard.simulate-eperm"; g gameStart nds advanced_drastic advanced_drastic "$ROM"
  [ -f "$T/var/run/ds-guard.reboot" ] && grep -q '"simulated": true' "$T/var/log/ds-ion-guard.log" && ok "$s simulate file forces the recovery path" || ko "$s simulate"; rm -rf "$T"
  # Unit 07 present: wait for its patched ES, never launch on the first (stock) one
  setup ok; mkdir -p "$T/userdata/system/es-patched/bin" "$T/proc/4242"; ln -s /usr/bin/emulationstation "$T/proc/4242/exe"
  printf '%s\n%s\n' "$ROM" 2000000000 > "$T/userdata/system/ds-guard/relaunch"; g relaunch
  ! grep -q launch: "$T/calls" 2>/dev/null && [ -f "$T/userdata/system/ds-guard/relaunch" ] && grep -q 'not ready (attempt 1), request kept' "$T/var/log/ds-ion-guard.log" && ok "$s stock ES under unit 07: no launch, request kept" || ko "$s es-patched stock: $(calls)"
  ln -sfn "$T/userdata/system/es-patched/bin/emulationstation" "$T/proc/4242/exe"; g relaunch
  grep -q "launch:/userdata/roms/nds/Mega Man ZX.zip" "$T/calls" && [ ! -e "$T/userdata/system/ds-guard/relaunch" ] && ok "$s patched ES running: launched" || ko "$s es-patched: $(calls)"; rm -rf "$T"

  setup ok; echo 2 > "$T/launch_ok_after"; printf '%s\n%s\n' "$ROM" 2000000000 > "$T/userdata/system/ds-guard/relaunch"; g relaunch
  [ "$(grep -c launch: "$T/calls")" = 2 ] && grep -q '(attempt 2)' "$T/var/log/ds-ion-guard.log" && [ ! -e "$T/userdata/system/ds-guard/relaunch" ] && ok "$s first launch lost: retried once, confirmed" || ko "$s retry: $(calls)"; rm -rf "$T"

  setup ok; echo 0 > "$T/launch_ok_after"; printf '%s\n%s\n' "$ROM" 2000000000 > "$T/userdata/system/ds-guard/relaunch"; g relaunch
  [ "$(grep -c launch: "$T/calls")" = 2 ] && grep -q 'no game running after 2 attempts' "$T/var/log/ds-ion-guard.log" && grep -q 'no se pudo abrir' "$T/calls" && [ ! -e "$T/userdata/system/ds-guard/relaunch" ] && ok "$s never confirmed: 2 attempts, notice, request dropped" || ko "$s never confirmed: $(calls)"; rm -rf "$T"
done
echo "passed=$pass failed=$fail"; [ "$fail" = 0 ]
