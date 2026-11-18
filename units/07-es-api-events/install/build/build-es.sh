#!/bin/bash
# Build the patched EmulationStation for Knulli scarab 20260511 on an RG35XX-H (H700),
# off-device, in an arm64 Debian 12 container, linking against the console's own libraries.
#
#   build-es.sh IMAGE_GZ ES_SOURCE OUT_DIR
#     IMAGE_GZ   knulli-h700-rg35xx-h-scarab-20260511.img.gz
#                (sha256 c28a96f88b07e3adb4ea76b9874cd18ae177ec216bec2dac87c68795fb81291c)
#     ES_SOURCE  checkout with submodules of the ES Scarab ships plus the fixes: 4041b56, then
#                Knulli 20260511's package patches (knulli-linux
#                package/emulationstation/knulli-emulationstation/*.patch, in name order, as
#                Buildroot applies them), then the fork series. The pipeline's rebase.py leaves
#                exactly that in WORK/es. A source without those patches is refused: ES would
#                not pass -pNdevicepath and configgen's evmapy fails (PICO-8, MAME, GZDoom).
#     OUT_DIR    receives emulationstation (stripped) and build logs
#
# Why this works: the binary is compiled with Debian 12 headers (GCC 12, glibc 2.36) and
# linked against the Scarab libraries taken from the image, so it needs at most
# GLIBC_2.34 / GLIBCXX_3.4.30 (Scarab ships glibc 2.40, libstdc++ 6.0.32) and the same
# sonames as the stock /usr/bin/emulationstation. ScreenScraper/HfsDB developer keys are
# not public, so those scrapers are missing from this build (TheGamesDB and ArcadeDB stay).
# es-sdl-knulli.h declares the joystick functions of Knulli's SDL2 that the package patches
# call (Debian's SDL2 headers lack them; the firmware's libSDL2 exports them).
set -eu
IMG=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
SRC=$(cd "$2" && pwd)
OUT=$(mkdir -p "$3" && cd "$3" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
NAME=knulli-es-build-$$
grep -q '"devicepath "' "$SRC/es-core/src/InputManager.cpp" ||
	{ echo "refused: $SRC lacks Knulli's ES package patches (no -pNdevicepath)"; exit 1; }

docker run -d --name "$NAME" --tmpfs /t:size=3g -v "$IMG:/in/img.gz:ro" -v "$SRC:/src" \
	-v "$HERE:/tools:ro" -v "$OUT:/out" debian:bookworm-slim sleep infinity
trap 'docker rm -f "$NAME" >/dev/null' EXIT

docker exec "$NAME" bash -euc '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends build-essential cmake pkg-config gettext python3 \
	squashfs-tools libsdl2-dev libsdl2-mixer-dev libfreeimage-dev libfreetype-dev \
	libcurl4-openssl-dev rapidjson-dev libvlc-dev libasound2-dev libgles-dev libegl-dev \
	libudev-dev libpulse-dev libespeak-dev ca-certificates > /dev/null

# Sysroot: the /boot/knulli squashfs from the FAT partition (sector 147456), libraries only
python3 -I /tools/fat_extract.py /in/img.gz 147456 BOOT/KNULLI /t/knulli.squashfs
unsquashfs -q -n -d /sysroot /t/knulli.squashfs "usr/lib/lib*.so*" "lib/*.so*" "lib/ld-linux*" \
	"usr/lib/pulseaudio/*.so*" usr/bin/emulationstation usr/share/knulli/knulli.version
rm -f /t/knulli.squashfs
mkdir -p /sysroot/etc /sysroot/tmp && : > /sysroot/etc/ld.so.conf && ldconfig -r /sysroot

mkdir -p /build && cd /build
cmake /src -DGLES2=ON -DBATOCERA=ON -DKNULLI=ON -DDISABLE_KODI=ON -DENABLE_PULSE=ON \
	-DENABLE_TTS=ON -DCEC=OFF -DENABLE_FILEMANAGER=OFF -DCMAKE_BUILD_TYPE=Release \
	"-DCMAKE_CXX_FLAGS=-DH700 -include /tools/es-sdl-knulli.h" -DOPENGLES2_INCLUDE_DIR=/usr/include -DPYTHON3_EXECUTABLE=/bin/true \
	"-DCMAKE_LIBRARY_PATH=/sysroot/usr/lib;/sysroot/lib" \
	"-DCMAKE_EXE_LINKER_FLAGS=-L/sysroot/usr/lib -L/sysroot/lib -Wl,-rpath-link,/sysroot/usr/lib:/sysroot/lib -Wl,--allow-shlib-undefined -Wl,--no-as-needed -lmali" \
	> /out/cmake.log
(cd /src && python3 resources/checkWheelGunGamesResources.py)
make -j"$(nproc)" > /out/make.log 2>&1
strip -o /out/emulationstation /src/emulationstation
rm -f /src/emulationstation

# Checks: sonames against the stock binary, symbol versions, and a full load with the
# console loader and libraries (LD_BIND_NOW resolves every symbol before main)
diff <(readelf -d /out/emulationstation | grep NEEDED | sed "s/.*\[//;s/\]//" | sort) \
	<(readelf -d /sysroot/usr/bin/emulationstation | grep NEEDED | sed "s/.*\[//;s/\]//" | sort) || true
for v in GLIBC GLIBCXX CXXABI; do objdump -T /out/emulationstation | grep -o "${v}_[0-9.]*" | sort -u -V | tail -1; done
cp /out/emulationstation /sysroot/tmp/emulationstation
LD_BIND_NOW=1 chroot /sysroot /tmp/emulationstation --help | head -3
'
(cd "$SRC" && git checkout -q -- locale) # the build refreshes the .po files
echo "built $OUT/emulationstation"
