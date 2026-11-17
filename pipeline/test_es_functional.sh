#!/bin/bash
# Gate for unit 07: the rebased ES source passes unit 07's own API and UI tests headless.
#   test_es_functional.sh ES_SOURCE UNIT07_TESTS OUT_DIR      (exit 0 pass, 1 fail, INFRA_EXIT)
# As in 07's VALIDATION: a Debian-linked build of the same source (Mesa GLES2 under Xvfb; the
# firmware build links the console's libmali and cannot run here), tests/setup.sh for a fake
# /userdata, then
#   api_test.sh    POST /addgames with favorite=false, lastplayed=0 on a played favorite:
#                  the game must come back favorite=false and not played (07 fix a);
#   ui_fav_test.sh long-press X twice: game-favorite-changed must fire true then false
#                  (07 fix c, through the scripting event).
# Writes OUT_DIR/es-functional.log and es-functional.status.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/config.env"
SRC=$(cd "$1" && pwd)
TESTS=$(cd "$2" && pwd)
OUT=$(mkdir -p "$3" && cd "$3" && pwd)
NAME=knulli-es-functional-$$
docker run -d --name "$NAME" --platform linux/arm64 --tmpfs /src:rw,exec,size=1g --tmpfs /build:rw,exec,size=4g \
	-e DEBIAN_SNAPSHOT="$DEBIAN_SNAPSHOT" -e INFRA_EXIT="$INFRA_EXIT" -e SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}" \
	-v "$HERE:/tools:ro" -v "$SRC:/in/src:ro" -v "$TESTS:/tests:ro" -v "$OUT:/out" "$DEBIAN_IMAGE" sleep infinity >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1' EXIT
docker exec "$NAME" bash -uc '
. /tools/apt.sh
apt_install build-essential cmake pkg-config gettext python3 libsdl2-dev libsdl2-mixer-dev libfreeimage-dev \
	libfreetype-dev libcurl4-openssl-dev rapidjson-dev libvlc-dev libasound2-dev libgles-dev libegl-dev libudev-dev \
	libpulse-dev libespeak-dev ca-certificates xvfb xdotool curl libgl1-mesa-dri libgles2 libegl1 xauth
cp -a /in/src/. /src/ && rm -rf /src/.git
cd /build
cmake /src -DGLES2=ON -DBATOCERA=ON -DKNULLI=ON -DDISABLE_KODI=ON -DENABLE_PULSE=OFF -DENABLE_TTS=OFF -DCEC=OFF \
	-DENABLE_FILEMANAGER=OFF -DCMAKE_BUILD_TYPE=Release -DOPENGLES2_INCLUDE_DIR=/usr/include -DPYTHON3_EXECUTABLE=/bin/true \
	> /out/es-functional-cmake.log 2>&1 || { echo "cmake failed"; tail -20 /out/es-functional-cmake.log; exit 1; }
(cd /src && python3 resources/checkWheelGunGamesResources.py) > /dev/null
make -j"$(nproc)" > /out/es-functional-make.log 2>&1 || { echo "build failed"; tail -20 /out/es-functional-make.log; exit 1; }
bash /tests/setup.sh
Xvfb :99 -screen 0 640x480x24 -nolisten tcp > /tmp/xvfb.log 2>&1 &
sleep 2
export DISPLAY=:99 LIBGL_ALWAYS_SOFTWARE=1 HOME=/userdata/system
(cd /userdata/system && /src/emulationstation --windowed --resolution 640 480 > /tmp/es.out 2>&1 &)
for i in $(seq 120); do curl -fs -m 2 -o /dev/null http://127.0.0.1:1234/caps && break; sleep 1; done
curl -fs -m 2 -o /dev/null http://127.0.0.1:1234/caps || { echo "ES web API never answered"; tail -30 /tmp/es.out; tail -30 /userdata/system/logs/es_log.txt 2>/dev/null; exit 1; }
sleep 3
fail=0
echo "--- api_test.sh"; bash /tests/api_test.sh
game=$(curl -s http://127.0.0.1:1234/systems/gb/games | python3 -c "import json,sys
g=[x for x in json.load(sys.stdin) if x.get(\"name\")==\"Alpha\"][0]; print(g.get(\"favorite\"), g.get(\"lastplayed\") or \"\")")
echo "Alpha after /addgames: $game"
case "$game" in False*|false*) ;; *) echo "FAIL /addgames did not clear favorite"; fail=1 ;; esac
case "$game" in *2026*) echo "FAIL /addgames did not clear lastplayed"; fail=1 ;; esac
echo "--- ui_fav_test.sh"; bash /tests/ui_fav_test.sh
events=$(cat /tmp/fav-events.log 2>/dev/null)
echo "events: $events"
[ "$(printf "%s\n" "$events" | sed -n 1p)" = "gb|/userdata/roms/gb/Alpha.gb|true" ] || { echo "FAIL first toggle event"; fail=1; }
[ "$(printf "%s\n" "$events" | sed -n 2p)" = "gb|/userdata/roms/gb/Alpha.gb|false" ] || { echo "FAIL second toggle event"; fail=1; }
[ "$fail" = 0 ] && echo "functional tests passed"
exit $fail
' > "$OUT/es-functional.log" 2>&1
rc=$?
echo "$rc" > "$OUT/es-functional.status"
tail -12 "$OUT/es-functional.log"
exit $rc
