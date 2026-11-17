#!/bin/bash
# Linux only, real flock / setsid / ps / pidof (run through tests/run_linux.sh).
# The reviewer's deadlock: a tool in EmulationStation's process group (a game
# hook's sync) holds the saver; the screen dims; the hold ends. The previous
# saver stopped ES's group from inside that tool while holding the lock, so
# "off" could not get the lock and ES and the game stayed stopped.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); FILES="$HERE/../files"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $*"; }
ko() { fail=$((fail+1)); echo "FAIL $*"; }
st() { ps -o stat= -p "$1" 2>/dev/null | cut -c1; }
wait_for() {  # wait_for <seconds> <command...>
  local n=$(( $1 * 10 )); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
  return 1
}

# setup <saver file>: fake root, ES stand-in named emulationstation, a nice -4
# game, and a holder in ES's group that holds the saver for 3 s
setup() {
  R=$(mktemp -d); W="$R/w"
  mkdir -p "$W" "$R/var/run" "$R/var/log" "$R/etc/init.d" "$R/userdata/system/patches/es_api_hold"
  cp "$(command -v sleep)" "$W/emulationstation"
  sed -e 's#^\. /etc/profile.d/.*##' "$HERE/fixtures/S31emulationstation.device" > "$R/etc/init.d/S31emulationstation"
  chmod +x "$R/etc/init.d/S31emulationstation"
  SAVER="$R/userdata/system/patches/es_api_hold/knulli-aggressive-saver"
  cp "$1" "$SAVER"; chmod +x "$SAVER"
  export UNIT_ROOT="$R"
  setsid bash -c '
    "$1/emulationstation" 600 & echo $! > "$1/es.pid"
    nice -n -4 sleep 600 & echo $! > "$1/game.pid"
    sleep 1
    "$2" run quick-inside -- sh -c "sleep 3; touch $1/cmd.done" & echo $! > "$1/holder.pid"
    wait
  ' _ "$W" "$SAVER" &
  disown $!
  wait_for 3 test -s "$W/holder.pid"
  ES=$(cat "$W/es.pid"); GAME=$(cat "$W/game.pid"); HOLDER=$(cat "$W/holder.pid")
  GROUP=$(ps -o pgid= -p "$ES" | tr -d ' ')
}
teardown() {
  kill -CONT -- -"$GROUP" 2>/dev/null; kill -- -"$GROUP" 2>/dev/null
  pkill -CONT -f "$R/" 2>/dev/null; pkill -f "$R/" 2>/dev/null
  sleep 0.3; rm -rf "$R"; unset UNIT_ROOT
}
lock_free() { flock -n "$R/var/run/battery-saver/aggressive.lock" true; }

[ "$(id -u)" = 0 ] && command -v flock >/dev/null && command -v setsid >/dev/null || { echo "needs Linux, root (nice -4), flock, setsid"; exit 2; }

# 1. Previous saver: the deadlock is reproduced
setup "$HERE/fixtures/knulli-aggressive-saver.v1"
[ "$(ps -o pgid= -p "$HOLDER" | tr -d ' ')" = "$GROUP" ] && ok "v1: the holder runs in ES's process group" || ko "v1: holder group"
"$SAVER" on
wait_for 6 test -e "$W/cmd.done"; sleep 1
if ! lock_free && [ "$(st "$HOLDER")" = T ]; then ok "v1: holder stopped while holding the lock (reproduced)"; else ko "v1: no deadlock: holder=$(st "$HOLDER")"; fi
"$SAVER" off; rc=$?
[ "$(st "$ES")" = T ] && ok "v1: after off (rc=$rc) ES is still stopped (reproduced)" || ko "v1: ES resumed"
teardown

# 2. New saver, same sequence
setup "$FILES/knulli-aggressive-saver"
sleep 1.5   # the hold is taken
"$SAVER" on
sleep 0.5
[ "$(st "$ES")" != T ] && [ "$(st "$GAME")" = T ] && ok "on during the hold: game paused, ES running" || ko "on during hold: es=$(st "$ES") game=$(st "$GAME")"
wait_for 6 test -e "$W/cmd.done" || ko "the held command did not finish"
wait_for 3 sh -c "[ \"\$(ps -o stat= -p $ES | cut -c1)\" = T ]" && ok "after the hold ES is stopped by the detached worker" || ko "ES not stopped after the hold"
wait_for 3 lock_free && ok "the lock is free" || ko "lock still held"
wait_for 3 sh -c "! kill -0 $HOLDER 2>/dev/null || [ \"\$(ps -o stat= -p $HOLDER | cut -c1)\" != T ] || flock -n $R/var/run/battery-saver/aggressive.lock true" && ok "the holder is not stuck holding the lock" || ko "holder stuck"
t0=$(date +%s%N); "$SAVER" off; rc=$?; ms=$(( ($(date +%s%N) - t0) / 1000000 ))
[ "$rc" = 0 ] && [ "$ms" -lt 3000 ] && ok "off returns 0 at once (${ms} ms)" || ko "off rc=$rc after ${ms} ms"
[ "$(st "$ES")" != T ] && [ "$(st "$GAME")" != T ] && ok "off: ES and game running" || ko "off: es=$(st "$ES") game=$(st "$GAME")"
teardown

# 3. New saver with a stuck lock holder: off resumes anyway and says it failed
setup "$FILES/knulli-aggressive-saver"
wait_for 6 test -e "$W/cmd.done"; sleep 0.5
( flock 200; kill -STOP "$BASHPID" ) 200>"$R/var/run/battery-saver/aggressive.lock" & STUCK=$!
wait_for 3 sh -c "[ \"\$(ps -o stat= -p $STUCK | cut -c1)\" = T ]"
touch "$R/var/run/battery-saver/aggressive.active"; kill -STOP "$GAME"; "$R/etc/init.d/S31emulationstation" suspend >/dev/null
SAVER_LOCK_WAIT=2 "$SAVER" off; rc=$?
[ "$rc" = 1 ] && ok "off without the lock exits 1" || ko "off rc=$rc"
[ "$(st "$ES")" != T ] && [ "$(st "$GAME")" != T ] && [ ! -e "$R/var/run/battery-saver/aggressive.active" ] && ok "off without the lock still resumes ES and the game" || ko "not resumed: es=$(st "$ES") game=$(st "$GAME")"
# The patched active hook falls back to the stock undo when off fails
touch "$R/var/run/battery-saver/aggressive.active"; kill -STOP "$GAME"; "$R/etc/init.d/S31emulationstation" suspend >/dev/null
mkdir -p "$R/stub"; printf '#!/bin/sh\ncase "$1" in system.batterysaver.mode) echo dim;; system.batterysaver.aggressive) echo 1;; esac\n' > "$R/stub/knulli-settings-get"
printf '#!/bin/sh\nexit 0\n' > "$R/stub/knulli-brightness"; chmod +x "$R"/stub/*
sed -e "s#/usr/bin/knulli-settings-get#knulli-settings-get#g" -e "s#/userdata/#$R/userdata/#g" -e "s#/etc/init.d/#$R/etc/init.d/#g" -e "s#/var/run/#$R/var/run/#g" "$FILES/01active-hooks" > "$R/01active-hooks"
mv "$SAVER" "$SAVER.real"; printf '#!/bin/sh\nexit 1\n' > "$SAVER"; chmod +x "$SAVER"
PATH="$R/stub:$PATH" bash "$R/01active-hooks" active
[ "$(st "$ES")" != T ] && [ "$(st "$GAME")" != T ] && ok "active hook: failed off falls back to the stock undo" || ko "hook fallback: es=$(st "$ES") game=$(st "$GAME")"
kill -CONT "$STUCK"; wait "$STUCK" 2>/dev/null
teardown

echo "passed=$pass failed=$fail"; [ "$fail" = 0 ]
