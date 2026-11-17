#!/bin/sh
# Reproducible build of files/connmand: ConnMan 1.42 + files/connman-1.42-generic-pmf.patch for
# Knulli 20260511 (aarch64). Same recipe as the v2 candidate except the generic patch and no
# Bluetooth plugin (stock Knulli has none either). Run in the pinned disposable container:
#   mkdir in out && cp connman-1.42.tar.xz files/connman-1.42-generic-pmf.patch <stock connmand> in/
#   (stock connmand renamed in/stock-connmand; tarball from kernel.org/pub/linux/network/connman)
#   docker run --rm --platform linux/arm64 -v "$PWD/in:/in:ro" -v "$PWD/out:/out" -v "$PWD:/tools:ro" \
#     debian@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc /tools/build.sh
# Expected: out/connmand sha256 a43f5ff1e9140fde0eab2db47ea3bea8d8d0962209256a19ea026e921d0f9928
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends build-essential pkg-config libglib2.0-dev libdbus-1-dev \
  libxtables-dev ca-certificates xz-utils patch binutils > /out/packages.log
echo "a3e6bae46fc081ef2e9dae3caa4f7649de892c3de622c20283ac0ca81423c2aa  /in/connman-1.42.tar.xz" | sha256sum -c -
echo "fab1de51700e11a7b0ccd96cbbf14c27adbd7ee2c036d6540fb643cde188d751  /in/connman-1.42-generic-pmf.patch" | sha256sum -c -
mkdir -p /build && tar -xJf /in/connman-1.42.tar.xz -C /build
cd /build/connman-1.42
# buildroot support/scripts/apply-patches.sh flags
patch -g0 -p1 -E --no-backup-if-mismatch -t -N < /in/connman-1.42-generic-pmf.patch
./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
  --with-dbusconfdir=/etc --with-firewall=iptables \
  --enable-wifi --enable-ethernet --disable-bluetooth --enable-loopback \
  --disable-client --disable-tools --disable-test --disable-debug \
  --disable-ofono --disable-neard --disable-polkit --disable-wispr \
  --disable-pptp --disable-openvpn --disable-vpnc --disable-l2tp \
  --disable-openconnect --disable-wireguard --disable-iwd \
  > /out/configure.log 2>&1
make -j"$(nproc)" > /out/build.log 2>&1
echo "warnings in supplicant.c: $(grep -c 'supplicant.c:.*warning' /out/build.log || true)"
strip src/connmand
cp src/connmand /out/connmand
/out/connmand --version
sha256sum /out/connmand
echo "NEEDED candidate:"; readelf -d /out/connmand | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' '; echo
echo "NEEDED stock:"; readelf -d /in/stock-connmand | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' '; echo
echo "plugins candidate: $(strings -n 6 /out/connmand | grep -E ' plugin$' | sort -u | tr '\n' ';')"
echo "plugins stock:     $(strings -n 6 /in/stock-connmand | grep -E ' plugin$' | sort -u | tr '\n' ';')"
echo "glibc symbol versions needed (max): $(readelf -V /out/connmand | grep -o 'GLIBC_[0-9.]*' | sort -V -u | tail -1)"
grep -n '"Pmf"' gsupplicant/supplicant.c
awk '/^static void add_network_security\(/,/^}/' gsupplicant/supplicant.c | grep -n -E 'key_mgmt =|ieee80211w' 
