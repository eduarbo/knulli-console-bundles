#!/bin/sh
# Off-device test of files/game-performance.sh against a fake sysfs root.
# Usage: sh tests/test_hook.sh   (SH=/bin/dash or /bin/bash picks the shell)
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SH=${SH:-sh}
HOOK="$HERE/files/game-performance.sh"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $*"; }
ko() { fail=$((fail+1)); echo "FAIL $*"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else ko "$1: got '$2' want '$3'"; fi; }

new_root() {
  ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gperf.XXXXXX")
  STUB="$ROOT.stub"; mkdir -p "$STUB"
  for n in 0 1 2 3; do :; done
  mkdir -p "$ROOT/sys/devices/system/cpu/cpufreq/policy0" "$ROOT/sys/class/devfreq/gpu" \
    "$ROOT/sys/class/thermal/thermal_zone0" "$ROOT/sys/class/thermal/thermal_zone1" \
    "$ROOT/var/run" "$ROOT/var/log" "$ROOT/userdata/system/game-performance"
  P="$ROOT/sys/devices/system/cpu/cpufreq/policy0"
  echo "480000 792000 1008000 1200000 1320000 1416000 1512000 1600000 1704000" > "$P/scaling_available_frequencies"
  echo 1512000 > "$P/scaling_max_freq"
  echo "interactive conservative ondemand userspace powersave performance schedutil" > "$P/scaling_available_governors"
  echo schedutil > "$P/scaling_governor"
  G="$ROOT/sys/class/devfreq/gpu"
  echo "240000000 336000000 420000000 504000000 600000000 696000000" > "$G/available_frequencies"
  echo 0 > "$G/min_freq"
  echo 40000 > "$ROOT/sys/class/thermal/thermal_zone0/temp"
  echo 41000 > "$ROOT/sys/class/thermal/thermal_zone1/temp"
  printf 'arcade\tmk.zip\tmaxfreq=1704000 governor=performance\n' > "$ROOT/userdata/system/game-performance/profiles.tsv"
  printf 'arcade\tpbobble2.zip\tmaxfreq=1704000 gpu_min=max\n' >> "$ROOT/userdata/system/game-performance/profiles.tsv"
  printf 'n64\tbad.zip\tmaxfreq=2000000 gpu_min=123\n' >> "$ROOT/userdata/system/game-performance/profiles.tsv"
  SETTING=""
  printf '#!/bin/sh\n[ -n "%s" ] && echo "%s"\n' "${1:-}" "${1:-}" > "$STUB/knulli-settings-get"
  chmod +x "$STUB/knulli-settings-get"
  export UNIT_ROOT="$ROOT" PATH="$STUB:$PATH"
}
drop_root() { rm -rf "$ROOT" "$ROOT.stub"; unset UNIT_ROOT; }
maxf() { cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq"; }
gmin() { cat "$ROOT/sys/class/devfreq/gpu/min_freq"; }
gov() { cat "$ROOT/sys/devices/system/cpu/cpufreq/policy0/scaling_governor"; }
wait_gone() { i=0; while [ -f "$ROOT/var/run/game-performance.saved" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; }

# 1 listed game: raised on start, back on stop
new_root
$SH "$HOOK" gameStart arcade libretro fbneo /userdata/roms/arcade/mk.zip
check "listed game raises the ceiling" "$(maxf)" 1704000
check "GPU untouched without gpu_min" "$(gmin)" 0
check "governor set" "$(gov)" performance
$SH "$HOOK" gameStop arcade libretro fbneo /userdata/roms/arcade/mk.zip
check "stop restores the ceiling" "$(maxf)" 1512000
check "stop restores the governor" "$(gov)" schedutil
check "nothing saved after stop" "$([ -f "$ROOT/var/run/game-performance.saved" ] && echo yes || echo no)" no
drop_root

# 2 GPU floor max and restore
new_root
$SH "$HOOK" gameStart arcade libretro fbneo /userdata/roms/arcade/pbobble2.zip
check "gpu_min=max uses the top frequency" "$(gmin)" 696000000
$SH "$HOOK" gameStop arcade libretro fbneo /userdata/roms/arcade/pbobble2.zip
check "GPU floor restored" "$(gmin)" 0
drop_root

# 3 unlisted game and other system: nothing changes
new_root
$SH "$HOOK" gameStart arcade libretro fbneo /userdata/roms/arcade/sf2.zip
check "unlisted game keeps the ceiling" "$(maxf)" 1512000
$SH "$HOOK" gameStart snes libretro snes9x /userdata/roms/snes/mk.zip
check "same file name in another system ignored" "$(maxf)" 1512000
$SH "$HOOK" gameStart vertical libretro fbneo /userdata/roms/arcade/mk.zip
check "ROM folder matches when ES names the system otherwise" "$(maxf)" 1704000
$SH "$HOOK" gameStop vertical libretro fbneo /userdata/roms/arcade/mk.zip
drop_root

# 4 values the driver does not list are refused
new_root
$SH "$HOOK" gameStart n64 libretro m64 /userdata/roms/n64/bad.zip
check "unlisted frequency refused" "$(maxf)" 1512000
check "unlisted GPU frequency refused" "$(gmin)" 0
$SH "$HOOK" gameStop n64 libretro m64 /userdata/roms/n64/bad.zip
drop_root

# 5 off switch
new_root off
printf '#!/bin/sh\necho 0\n' > "$STUB/knulli-settings-get"
$SH "$HOOK" gameStart arcade libretro fbneo /userdata/roms/arcade/mk.zip
check "system.gameperformance=0 disables" "$(maxf)" 1512000
drop_root

# 6 emulatorlauncher dies without gameStop: the watcher restores
new_root
sleep 300 &
LAUNCHER=$!
( exec $SH "$HOOK" gameStart arcade libretro fbneo /userdata/roms/arcade/mk.zip ) &
wait $!
# the hook's $PPID is this test shell; run the watcher on the fake launcher instead
kill "$(cat "$ROOT/var/run/game-performance.watch" 2>/dev/null)" 2>/dev/null
setsid $SH "$HOOK" watch "$LAUNCHER" </dev/null >/dev/null 2>&1 &
sleep 0.5
check "raised while the launcher runs" "$(maxf)" 1704000
kill "$LAUNCHER"; wait "$LAUNCHER" 2>/dev/null
i=0; while [ "$(maxf)" != 1512000 ] && [ $i -lt 80 ]; do sleep 0.25; i=$((i+1)); done
check "watcher restores after the launcher is gone" "$(maxf)" 1512000
check "watcher restores the governor" "$(gov)" schedutil
drop_root

# 7 a leftover from a crash is restored at the next start
new_root
$SH "$HOOK" gameStart arcade libretro fbneo /userdata/roms/arcade/mk.zip
kill "$(cat "$ROOT/var/run/game-performance.watch" 2>/dev/null)" 2>/dev/null
$SH "$HOOK" gameStart arcade libretro fbneo /userdata/roms/arcade/sf2.zip
check "leftover restored by the next gameStart" "$(maxf)" 1512000
drop_root

echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
