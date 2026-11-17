#!/bin/bash
# Build unit 10's ConnMan candidate for a release.
#   build_connman.sh SYSROOT KNULLI_REPO REF BUILDROOT_COMMIT OUT_DIR
# The ConnMan version is the firmware's own (connmand --version in the sysroot); it must be
# the one Buildroot (the submodule commit the tag pins) packages, whose connman.hash gives
# the tarball sha256. The patch is the series' CONNMAN_PATCH at REF (the rebased branch).
# Recipe: unit 10's install/build.sh, parametrised by version, in the same pinned container.
# Exit INFRA_EXIT = download or apt failure (infrastructure); exit 3 = unit not needed any more (patch gone from the series, or the stock binary already
# sets the global Pmf property); exit 1 = build or gate failure.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/config.env"
SYSROOT=$(cd "$1" && pwd)
REPO=$(cd "$2" && pwd)
REF=$3
BR=$4
OUT=$(mkdir -p "$5" && cd "$5" && pwd)
IN=$OUT/in
mkdir -p "$IN"
sum() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | cut -d ' ' -f 1; }

STOCK=$SYSROOT/usr/sbin/connmand
if strings -n 3 "$STOCK" | grep -qx Pmf; then
	echo "stock connmand already sets the global Pmf property: fix upstream" | tee "$OUT/connman-checks.txt"
	exit 3
fi
if ! git -C "$REPO" cat-file -e "$REF:$CONNMAN_PATCH" 2>/dev/null; then
	echo "the series no longer carries $CONNMAN_PATCH (dropped as upstream)" | tee "$OUT/connman-checks.txt"
	exit 3
fi
git -C "$REPO" show "$REF:$CONNMAN_PATCH" > "$IN/connman-pmf.patch"
cp "$STOCK" "$IN/stock-connmand"

BR_RAW=https://raw.githubusercontent.com/knulli-cfw/buildroot/$BR/package/connman
fetch() { curl -fsSL --retry 3 "$@" || { echo "download failed (infrastructure): $*"; exit "$INFRA_EXIT"; }; }
fetch "$BR_RAW/connman.mk" -o "$OUT/connman.mk"
fetch "$BR_RAW/connman.hash" -o "$OUT/connman.hash"
VERSION=$(sed -n 's/^CONNMAN_VERSION *= *//p' "$OUT/connman.mk")
TARBALL=connman-$VERSION.tar.xz
TAR_SHA=$(awk -v f="$TARBALL" '$1 == "sha256" && $3 == f {print $2}' "$OUT/connman.hash")
[[ $TAR_SHA =~ ^[0-9a-f]{64}$ ]] || { echo "no sha256 for $TARBALL in Buildroot $BR"; exit 1; }
CACHE=${CONNMAN_CACHE:-$OUT}
if [ ! -f "$CACHE/$TARBALL" ] || [ "$(sum "$CACHE/$TARBALL")" != "$TAR_SHA" ]; then
	fetch -o "$CACHE/$TARBALL.part" "https://www.kernel.org/pub/linux/network/connman/$TARBALL"
	mv -f "$CACHE/$TARBALL.part" "$CACHE/$TARBALL"
fi
[ "$(sum "$CACHE/$TARBALL")" = "$TAR_SHA" ] || { echo "$TARBALL sha256 mismatch"; exit 1; }
cp "$CACHE/$TARBALL" "$IN/$TARBALL"

docker run --rm --platform linux/arm64 --tmpfs /build:rw,exec,size=1g --tmpfs /t:rw,exec,size=1g \
	-e DEBIAN_SNAPSHOT="$DEBIAN_SNAPSHOT" -e INFRA_EXIT="$INFRA_EXIT" -v "$HERE:/tools:ro" -e VERSION="$VERSION" -e TAR_SHA="$TAR_SHA" \
	-e PATCH_SHA="$(sum "$IN/connman-pmf.patch")" -v "$IN:/in:ro" -v "$OUT:/out" \
	-v "$SYSROOT:/sysroot:ro" "$DEBIAN_IMAGE" bash -euc '
. /tools/apt.sh
apt_install build-essential pkg-config libglib2.0-dev libdbus-1-dev libxtables-dev ca-certificates xz-utils patch binutils
dpkg-query -W -f "\${Package} \${Version}\n" > /out/connman-packages.log
echo "$TAR_SHA  /in/connman-$VERSION.tar.xz" | sha256sum -c -
echo "$PATCH_SHA  /in/connman-pmf.patch" | sha256sum -c -
tar -xJf /in/connman-$VERSION.tar.xz -C /build
cd /build/connman-$VERSION
patch -g0 -p1 -E --no-backup-if-mismatch -t -N < /in/connman-pmf.patch > /out/connman-patch.log
./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
  --with-dbusconfdir=/etc --with-firewall=iptables \
  --enable-wifi --enable-ethernet --disable-bluetooth --enable-loopback \
  --disable-client --disable-tools --disable-test --disable-debug \
  --disable-ofono --disable-neard --disable-polkit --disable-wispr \
  --disable-pptp --disable-openvpn --disable-vpnc --disable-l2tp \
  --disable-openconnect --disable-wireguard --disable-iwd \
  > /out/connman-configure.log 2>&1
make -j"$(nproc)" > /out/connman-build.log 2>&1
strip src/connmand
cp src/connmand /out/connmand
needed() { readelf -d "$1" | sed -n "s/.*(NEEDED).*\[\(.*\)\]/\1/p" | sort; }
plugins() { strings -n 6 "$1" | grep -E " plugin$" | sort -u | tr "\n" ";"; }
{
	echo "version: $(/out/connmand --version)"
	echo "sha256: $(sha256sum /out/connmand | cut -d " " -f 1)"
	echo "NEEDED only in the build: $(comm -23 <(needed /out/connmand) <(needed /in/stock-connmand) | tr "\n" " ")"
	echo "plugins build: $(plugins /out/connmand)"
	echo "plugins stock: $(plugins /in/stock-connmand)"
	echo "max GLIBC: $(readelf -V /out/connmand | grep -o "GLIBC_[0-9.]*" | sort -V -u | tail -1)"
	echo "warnings in supplicant.c: $(grep -c "supplicant.c:.*warning" /out/connman-build.log || true)"
	echo "Pmf property: $(grep -c "\"Pmf\"" gsupplicant/supplicant.c)"
} > /out/connman-checks.txt
[ "$(/out/connmand --version)" = "$VERSION" ]
[ -z "$(comm -23 <(needed /out/connmand) <(needed /in/stock-connmand))" ] || { echo "needs libraries stock does not"; exit 1; }
[ "$(plugins /out/connmand)" = "$(plugins /in/stock-connmand)" ] || { echo "plugin set differs from stock"; exit 1; }
# Loads with the firmware loader and libraries, not only with Debian ones
cp -a /sysroot /t/root && cp /out/connmand /t/root/tmp/connmand
[ "$(chroot /t/root /usr/sbin/connmand --version)" = "$VERSION" ] || { echo "stock ConnMan is not Buildroot $VERSION"; exit 1; }
[ "$(LD_BIND_NOW=1 chroot /t/root /tmp/connmand --version)" = "$VERSION" ] || { echo "does not load in the firmware"; exit 1; }
echo "firmware chroot --version: ok" >> /out/connman-checks.txt
chown "$(stat -c %u:%g /out)" /out/*
'
cat "$OUT/connman-checks.txt"
