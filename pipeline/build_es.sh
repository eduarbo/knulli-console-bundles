#!/bin/bash
# Build the patched EmulationStation for the H700 against a release's own libraries.
#   build_es.sh SYSROOT ES_SOURCE OUT_DIR
# Same recipe as unit 07's install/build/build-es.sh (Debian 12 headers and GCC 12, linked
# against the firmware libraries, -DH700, GLES2, pulse, TTS, -lmali), with four changes:
# the sysroot comes from extract.sh (any partition layout), the source is copied into the
# container (the checkout stays clean), SOURCE_DATE_EPOCH fixes __DATE__/__TIME__, so the
# same inputs give the same binary, and es-sdl-knulli.h declares the joystick functions of
# Knulli's SDL2 that Knulli's ES package patches call (Debian's SDL2 headers lack them; the
# binary resolves them in the firmware's libSDL2, which the chroot check below proves).
# Exit INFRA_EXIT when apt cannot fetch (infrastructure, not the unit's fault).
# Gates (exit 1): the binary must load with the firmware's loader and libraries
# (LD_BIND_NOW=1 chroot SYSROOT emulationstation --help prints "Version"), and it may only
# need libraries the firmware has.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/config.env"
SYSROOT=$(cd "$1" && pwd)
SRC=$(cd "$2" && pwd)
OUT=$(mkdir -p "$3" && cd "$3" && pwd)
: "${SOURCE_DATE_EPOCH:?set SOURCE_DATE_EPOCH (rebase.env TAG_TIME)}"
NAME=knulli-es-build-$$

# Source, build tree and sysroot copy live in RAM (tmpfs), so only the build packages use disk
docker run -d --name "$NAME" --platform linux/arm64 --tmpfs /t:rw,exec,size=1g --tmpfs /src:rw,exec,size=1g \
	--tmpfs /build:rw,exec,size=4g --tmpfs /sysroot:rw,exec,size=1g -e SOURCE_DATE_EPOCH -e ES_DATE_OVERRIDES \
	-e DEBIAN_SNAPSHOT="$DEBIAN_SNAPSHOT" -e INFRA_EXIT="$INFRA_EXIT" -v "$HERE:/tools:ro" \
	-v "$SYSROOT:/in/sysroot:ro" -v "$SRC:/in/src:ro" -v "$OUT:/out" "$DEBIAN_IMAGE" sleep infinity >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1' EXIT

docker exec "$NAME" bash -euc '
. /tools/apt.sh
apt_install build-essential cmake pkg-config gettext python3 \
	libsdl2-dev libsdl2-mixer-dev libfreeimage-dev libfreetype-dev \
	libcurl4-openssl-dev rapidjson-dev libvlc-dev libasound2-dev libgles-dev libegl-dev \
	libudev-dev libpulse-dev libespeak-dev ca-certificates
dpkg-query -W -f "\${Package} \${Version}\n" > /out/es-build-packages.txt

cp -a /in/sysroot/. /sysroot/
# /src and /build: the paths the unit 07 build used (they end up in __FILE__ strings)
cp -a /in/src/. /src/ && rm -rf /src/.git
cd /build
cmake /src -DGLES2=ON -DBATOCERA=ON -DKNULLI=ON -DDISABLE_KODI=ON -DENABLE_PULSE=ON \
	-DENABLE_TTS=ON -DCEC=OFF -DENABLE_FILEMANAGER=OFF -DCMAKE_BUILD_TYPE=Release \
	"-DCMAKE_CXX_FLAGS=-DH700 -include /tools/es-sdl-knulli.h" -DOPENGLES2_INCLUDE_DIR=/usr/include -DPYTHON3_EXECUTABLE=/bin/true \
	"-DCMAKE_LIBRARY_PATH=/sysroot/usr/lib;/sysroot/lib" \
	"-DCMAKE_EXE_LINKER_FLAGS=-L/sysroot/usr/lib -L/sysroot/lib -Wl,-rpath-link,/sysroot/usr/lib:/sysroot/lib -Wl,--allow-shlib-undefined -Wl,--no-as-needed -lmali" \
	> /out/es-cmake.log
(cd /src && python3 resources/checkWheelGunGamesResources.py)
make -j"$(nproc)" > /out/es-make.log 2>&1
# Reproduction aid (tests only): ES_DATE_OVERRIDES="<object path suffix>=<epoch> ..." rebuilds
# those objects with another SOURCE_DATE_EPOCH, as when one build crossed a second boundary
for o in ${ES_DATE_OVERRIDES:-}; do
	obj=$(find /build -path "*/${o%%=*}.o")
	[ "$(echo "$obj" | grep -c .)" = 1 ] || { echo "not exactly one object for ${o%%=*}: $obj"; exit 1; }
	rm -f "$obj"
	SOURCE_DATE_EPOCH=${o#*=} make -j"$(nproc)" >> /out/es-make.log 2>&1
done
strip -o /out/emulationstation /src/emulationstation

needed() { readelf -d "$1" | sed -n "s/.*(NEEDED).*\[\(.*\)\]/\1/p" | sort; }
{
	echo "NEEDED only in the build: $(comm -23 <(needed /out/emulationstation) <(needed /sysroot/usr/bin/emulationstation) | tr "\n" " ")"
	echo "NEEDED only in stock:     $(comm -13 <(needed /out/emulationstation) <(needed /sysroot/usr/bin/emulationstation) | tr "\n" " ")"
	for v in GLIBC GLIBCXX CXXABI; do
		echo "max $v: $(objdump -T /out/emulationstation | grep -o "${v}_[0-9.]*" | sort -u -V | tail -1)"
	done
} > /out/es-checks.txt
missing=""
for lib in $(needed /out/emulationstation); do
	[ -e "/sysroot/usr/lib/$lib" ] || [ -e "/sysroot/lib/$lib" ] || missing="$missing $lib"
done
[ -z "$missing" ] || { echo "needs libraries the firmware lacks:$missing" | tee -a /out/es-checks.txt; exit 1; }
cp /out/emulationstation /sysroot/tmp/emulationstation
LD_BIND_NOW=1 chroot /sysroot /tmp/emulationstation --help > /t/help.txt 2>&1 || {
	echo "chroot --help failed: $(head -3 /t/help.txt)" | tee -a /out/es-checks.txt; exit 1; }
grep -m1 "Version" /t/help.txt | tee -a /out/es-checks.txt
chown "$(stat -c %u:%g /out)" /out/*
'
cat "$OUT/es-checks.txt"
