#!/bin/bash
# Extract the sysroot and the stock files the version-tied units pin from a Knulli image.
#   extract.sh IMAGE_GZ OUT_DIR
# OUT_DIR/sysroot   libraries (for linking and the chroot checks) and the stock files below
# OUT_DIR/listing.txt  unsquashfs -lls of the whole rootfs (audit, kernel modules, tools)
# OUT_DIR/stock.env    knulli.version, kernel release and sha256 of every pinned stock file
# Runs in a disposable debian:bookworm container (pinned by digest in config.env); the
# squashfs is kept in a container tmpfs, never on the host disk.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/config.env"
IMG=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
NAME=knulli-extract-$$
rm -rf "$OUT/sysroot"

docker run -d --name "$NAME" --platform linux/arm64 --tmpfs /t:size=3g \
	-v "$IMG:/in/img.gz:ro" -v "$HERE:/tools:ro" -v "$OUT:/out" "$DEBIAN_IMAGE" sleep infinity >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1' EXIT

docker exec -e STOCK_PATHS="$STOCK_PATHS" -e KERNEL_PARTITION="$KERNEL_PARTITION" -e DEBIAN_SNAPSHOT="$DEBIAN_SNAPSHOT" \
	-e INFRA_EXIT="$INFRA_EXIT" "$NAME" bash -euc '
. /tools/apt.sh
apt_install squashfs-tools python3
python3 -I /tools/image_extract.py /in/img.gz BOOT/KNULLI /t/knulli.squashfs
unsquashfs -lls -d "" /t/knulli.squashfs > /out/listing.txt
# Libraries for the builds and chroot checks, plus the stock files the units pin
unsquashfs -q -n -d /out/sysroot /t/knulli.squashfs "usr/lib/lib*.so*" "lib/*.so*" "lib/ld-linux*" \
	"usr/lib/pulseaudio/*.so*" $STOCK_PATHS > /dev/null
rm -f /t/knulli.squashfs
mkdir -p /out/sysroot/etc /out/sysroot/tmp && : > /out/sysroot/etc/ld.so.conf && ldconfig -r /out/sysroot
{
	printf "VERSION=%q\n" "$(cat /out/sysroot/usr/share/knulli/knulli.version)"
	printf "KERNEL=%s\n" "$(grep -o " /lib/modules/[^/ ]*$" /out/listing.txt | head -1 | sed "s|.*/||")"
	printf "SHA_PART_%s=%s\n" "$(echo "$KERNEL_PARTITION" | tr a-z- A-Z_)" "$(python3 -I /tools/image_extract.py /in/img.gz --partition-sha "$KERNEL_PARTITION")"
	printf "CONNMAN_VERSION=%s\n" "$(chroot /out/sysroot /usr/sbin/connmand --version 2>/dev/null || echo unknown)"
	for p in $STOCK_PATHS; do
		key=$(echo "$p" | tr "a-z/.-" "A-Z___")
		if [ -f "/out/sysroot/$p" ]; then
			printf "SHA_%s=%s\n" "$key" "$(sha256sum "/out/sysroot/$p" | cut -d " " -f 1)"
		else
			printf "SHA_%s=absent\n" "$key"
		fi
	done
} > /out/stock.env
chown -R "$(stat -c %u:%g /out)" /out
'
cat "$OUT/stock.env"
