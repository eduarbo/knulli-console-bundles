#!/bin/bash
# Off-device tests of files/knulli-aggressive-saver and the patched idle /
# active hooks, with real processes: a stand-in EmulationStation (a Python
# HTTP server) and a stand-in emulator (sleep) in its own process group.
# pidof, flock and "ps -eo pid,ni" are stubs (the emulator is reported at
# nice -4); the init script is the device's S31emulationstation.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); FILES="$HERE/../files"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $*"; }
ko() { fail=$((fail+1)); echo "FAIL $*"; }

R=$(mktemp -d "${TMPDIR:-/tmp}/saver.XXXXXX"); STUB="$R.stub"; mkdir -p "$STUB"
mkdir -p "$R/var/run" "$R/var/log" "$R/etc/init.d" "$R/userdata/system/patches/es_api_hold" "$R/sys/devices/system/cpu/cpu0/cpufreq" "$R/sys/devices/system/cpu/cpu1/cpufreq"
for c in cpu0 cpu1; do echo schedutil > "$R/sys/devices/system/cpu/$c/cpufreq/scaling_governor"; done
PORT=$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 -I -c 'import os,sys;os.setpgrp();os.execvp("bash",["bash","-c","sleep 600 & echo $! > \"$1\"/emu.pid; exec python3 -I -m http.server --bind 127.0.0.1 \"$2\" --directory \"$1\"","x",sys.argv[1],sys.argv[2]])' "$R" "$PORT" >/dev/null 2>&1 &
ES=$!; sleep 1.5; EMU=$(cat "$R/emu.pid")
printf '#!/bin/sh\n[ "$1" = emulationstation ] && kill -0 %s 2>/dev/null && echo %s && exit 0\nexit 1\n' "$ES" "$ES" > "$STUB/pidof"
printf '#!/bin/sh\nif [ "$1" = -eo ]; then printf "  PID  NI\\n%%s -4\\n%%s 0\\n" %s %s; else exec /bin/ps "$@"; fi\n' "$EMU" "$ES" > "$STUB/ps"
printf '#!/bin/sh\nexit 0\n' > "$STUB/flock"   # see test_deadlock.sh for real locking
command -v setsid >/dev/null 2>&1 || printf '#!/bin/sh\nexec python3 -I -c "import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])" "$@"\n' > "$STUB/setsid"
printf '#!/bin/sh\necho "brightness $*" >> %s/calls\n' "$R" > "$STUB/knulli-brightness"
printf '#!/bin/sh\ncase "$1" in system.batterysaver.mode) echo dim;; system.batterysaver.aggressive) echo 1;; system.batterysaver.mute) echo 0;; esac\n' > "$STUB/knulli-settings-get"
chmod +x "$STUB"/*
sed -e 's#^\. /etc/profile.d/.*##' "$HERE/fixtures/S31emulationstation.device" > "$R/etc/init.d/S31emulationstation" 2>/dev/null ||
  ko "missing S31 fixture"
chmod +x "$R/etc/init.d/S31emulationstation"
SAVER="$R/userdata/system/patches/es_api_hold/knulli-aggressive-saver"
cp "$FILES/knulli-aggressive-saver" "$SAVER"; chmod +x "$SAVER"
export UNIT_ROOT="$R" PATH="$STUB:$PATH"

st() { ps -o stat= -p "$1" 2>/dev/null | cut -c1; }
api() { curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/"; }
flag() { [ -f "$R/var/run/emulationstation.suspended" ] && echo on || echo off; }
gov() { cat "$R/sys/devices/system/cpu/cpu1/cpufreq/scaling_governor"; }
# ES is stopped by a detached worker: wait up to 3 s for it
settle() { for _ in $(seq 30); do [ "$(st "$ES")" = T ] && [ "$(flag)" = on ] && break; /bin/sleep 0.1; done; /bin/sleep 0.2; }

"$SAVER" on; settle
[ "$(st "$ES")$(st "$EMU")" = TT ] && [ "$(flag)" = on ] && [ "$(api)" = 000 ] && ok "on: ES and emulator stopped, flag set, API silent" || ko "on: es=$(st "$ES") emu=$(st "$EMU") flag=$(flag)"
[ "$(cat "$R/var/run/emulationstation.suspended")" = "$(ps -o pgid= -p "$ES" | tr -d ' ')" ] && ok "flag holds the ES process group" || ko "flag content"
[ "$(gov)" = powersave ] && [ "$(cat "$R/var/run/battery-saver/governor.saved")" = schedutil ] && ok "governor saved and set to powersave" || ko "governor"
"$SAVER" state >/dev/null; [ $? = 3 ] && ok "state: frozen (exit 3)" || ko "state while frozen"
inside=$("$SAVER" run romm-sync -- sh -c "curl -s -o /dev/null -m 3 -w '%{http_code}' http://127.0.0.1:$PORT/; ps -o stat= -p $EMU | cut -c1")
[ "$inside" = "200T" ] && ok "run: API answers during the hold, game stays paused" || ko "run inside: $inside"
settle; [ "$(st "$ES")" = T ] && [ "$(flag)" = on ] && [ ! -e "$R/var/run/battery-saver/holds/romm-sync" ] && ok "run: ES stopped again after the hold" || ko "after run: es=$(st "$ES") flag=$(flag)"
"$SAVER" run failing -- sh -c 'exit 7'; [ $? = 7 ] && ok "run: returns the command's status" || ko "run status"; settle
sleep 300 & holder=$!
"$SAVER" hold sync "$holder"; [ "$(st "$ES")" != T ] && [ "$(api)" = 200 ] && ok "hold: ES answers" || ko "hold"
kill "$holder"; wait "$holder" 2>/dev/null
"$SAVER" state >/dev/null; settle; "$SAVER" state >/dev/null; [ $? = 3 ] && [ "$(st "$ES")" = T ] && ok "stale hold dropped, ES stopped again" || ko "stale hold: es=$(st "$ES")"
"$SAVER" off
[ "$(st "$ES")" != T ] && [ "$(st "$EMU")" != T ] && [ "$(flag)" = off ] && [ "$(api)" = 200 ] && [ "$(gov)" = schedutil ] && ok "off: everything resumed, governor restored" || ko "off: es=$(st "$ES") emu=$(st "$EMU") gov=$(gov)"
"$SAVER" state >/dev/null && ok "state: running (exit 0)" || ko "state running"
sleep 300 & holder=$!
"$SAVER" hold early "$holder"; "$SAVER" on; /bin/sleep 1
[ "$(st "$ES")" != T ] && [ "$(st "$EMU")" = T ] && [ "$(flag)" = off ] && ok "on during a hold: game paused, ES kept running" || ko "on with hold: es=$(st "$ES") emu=$(st "$EMU")"
"$SAVER" release early; settle; [ "$(st "$ES")" = T ] && [ "$(flag)" = on ] && ok "release: ES stopped" || ko "release"
kill "$holder"; wait "$holder" 2>/dev/null
"$SAVER" off
touch "$R/var/run/battery-saver/scraper.pause"; "$SAVER" on
[ ! -f "$R/var/run/battery-saver/aggressive.active" ] && [ "$(st "$ES")" != T ] && ok "a pause file keeps the saver off" || ko "pause ignored"
rm -f "$R/var/run/battery-saver/scraper.pause"
"$SAVER" hold 'bad/name' 2>/dev/null; [ $? = 2 ] && ok "invalid hold names refused" || ko "hold name check"

# Patched hooks call the saver; without it they fall back to the stock inline code
for h in idle active; do sed -e "s#/usr/bin/knulli-settings-get#knulli-settings-get#g" -e "s#/userdata/#$R/userdata/#g" -e "s#/etc/init.d/#$R/etc/init.d/#g" -e "s#/var/run/#$R/var/run/#g" "$FILES/01$h-hooks" > "$R/01$h-hooks"; done
bash "$R/01idle-hooks" idle; settle
[ -f "$R/var/run/battery-saver/aggressive.active" ] && [ "$(st "$ES")" = T ] && grep -q 'brightness dim' "$R/calls" && ok "idle hook: dims and runs the saver" || ko "idle hook"
bash "$R/01active-hooks" active
[ ! -f "$R/var/run/battery-saver/aggressive.active" ] && [ "$(st "$ES")" != T ] && [ "$(st "$EMU")" != T ] && grep -q 'brightness undim' "$R/calls" && ok "active hook: undims and undoes the saver" || ko "active hook"
chmod -x "$SAVER"
bash "$R/01idle-hooks" idle
[ "$(st "$ES")$(st "$EMU")" = TT ] && [ ! -f "$R/var/run/battery-saver/aggressive.active" ] && ok "fallback: stock inline saver when the unit is absent" || ko "fallback idle: es=$(st "$ES") emu=$(st "$EMU")"
bash "$R/01active-hooks" active
[ "$(st "$ES")" != T ] && [ "$(st "$EMU")" != T ] && ok "fallback: stock inline undo" || ko "fallback active"

# Installed while the stock saver had ES stopped: the new active hook still resumes it
chmod +x "$SAVER"; kill -STOP "$EMU"; "$R/etc/init.d/S31emulationstation" suspend >/dev/null
"$SAVER" off
[ "$(st "$ES")" != T ] && [ "$(st "$EMU")" != T ] && ok "off resumes a freeze made by the stock saver" || ko "stock freeze not resumed: es=$(st "$ES") emu=$(st "$EMU")"

kill -CONT -- -"$ES" 2>/dev/null; kill -- -"$ES" 2>/dev/null; kill "$EMU" 2>/dev/null; wait 2>/dev/null
rm -rf "$R" "$STUB"
echo "passed=$pass failed=$fail"; [ "$fail" = 0 ]
