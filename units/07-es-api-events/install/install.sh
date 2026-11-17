#!/bin/bash
# Install the patched EmulationStation on the console (run as root from this folder).
# Copies the build to /userdata/system/es-patched, adds the es_patched user service,
# enables it in system.services (knulli.conf backed up first) and starts it.
# The stock /usr/bin/emulationstation is never modified. Undo with rollback.sh.
# Succeeds only when the patched ES runs, its web API answers and the screen is not black;
# otherwise it rolls back to stock by itself and exits 1.
set -eu
cd "$(dirname "$0")"

ROOT=${ES_PATCHED_ROOT:-/userdata/system/es-patched}
TARGET=${ES_PATCHED_TARGET:-/usr/bin/emulationstation}
SERVICE=${ES_PATCHED_SERVICE:-/userdata/system/services/es_patched}
CONF=${ES_PATCHED_CONF:-/userdata/system/knulli.conf}
MODEL_FILE=${ES_PATCHED_MODEL_FILE:-/proc/device-tree/model}
VERSION_FILE=${ES_PATCHED_VERSION_FILE:-/usr/share/knulli/knulli.version}
ES_API=${ES_PATCHED_ES_API:-http://127.0.0.1:1234}
LOOP_FLAG=${ES_PATCHED_LOOP_FLAG:-/var/run/emulationstation-standalone}
FB=${ES_PATCHED_FB:-/dev/fb0}
READY_WAIT=${ES_PATCHED_READY_WAIT:-300}

die() { echo "install: $*" >&2; exit 1; }
manifest() { sed -n "s/^$1=//p" payload/manifest; }
sha() { sha256sum "$1" | cut -d ' ' -f 1; }

[ "$(id -u)" = 0 ] || die "run as root"
[ "$(tr -d '\000' < "$MODEL_FILE")" = "$(manifest MODEL)" ] || die "this build is for $(manifest MODEL)"
[ "$(cat "$VERSION_FILE")" = "$(manifest VERSION)" ] || die "this build is for Knulli $(manifest VERSION)"
case "$(sha "$TARGET")" in
	"$(manifest STOCK_SHA256)") ;;
	"$(manifest LAUNCHER_SHA256)") die "already active; run rollback.sh first" ;;
	*) die "$TARGET is not the expected stock binary" ;;
esac
[ "$(sha payload/emulationstation)" = "$(manifest PATCHED_SHA256)" ] || die "payload/emulationstation checksum"
[ "$(sha files/launcher.sh)" = "$(manifest LAUNCHER_SHA256)" ] || die "files/launcher.sh checksum"
[ "$(sha files/service.sh)" = "$(manifest SERVICE_SHA256)" ] || die "files/service.sh checksum"
[ "$(df -Pk "$(dirname "$ROOT")" | awk 'NR==2 {print $4}')" -gt 51200 ] || die "less than 50 MB free"
# ES must run under emulationstation-standalone, which starts it again after it quits
[ -e "$LOOP_FLAG" ] && pgrep -f emulationstation-standalone > /dev/null || die "ES is not running under emulationstation-standalone"
command -v fbgrab > /dev/null || die "fbgrab not found (needed for the screen check)"

# Files (temporary names, then rename)
mkdir -p "$ROOT/bin" "$ROOT/state" "$(dirname "$SERVICE")"
cp payload/emulationstation "$ROOT/bin/.emulationstation.new"
cp files/launcher.sh "$ROOT/.launcher.sh.new"
cp payload/manifest "$ROOT/.manifest.new"
cp files/service.sh "$SERVICE.new"
chmod 755 "$ROOT/bin/.emulationstation.new" "$ROOT/.launcher.sh.new" "$SERVICE.new"
mv -f "$ROOT/bin/.emulationstation.new" "$ROOT/bin/emulationstation"
mv -f "$ROOT/.launcher.sh.new" "$ROOT/launcher.sh"
mv -f "$ROOT/.manifest.new" "$ROOT/manifest"
mv -f "$SERVICE.new" "$SERVICE"
rm -f "$ROOT/state/use-stock" "$ROOT/state/disabled" "$ROOT/state/failures" "$ROOT/state/start-timeout" "$ROOT/state/ok-version"
sync

# Enable the service (keeps the other services)
services=$(knulli-settings-get system.services || true)
case " $services " in
	*" es_patched "*) ;;
	*)
		cp -p "$CONF" "$CONF.bak-$(date +%Y%m%d-%H%M%S)-es_patched"
		knulli-settings-set system.services "$(echo $services es_patched)"
		;;
esac
case " $(knulli-settings-get system.services) " in
	*" es_patched "*) ;;
	*) die "system.services readback does not list es_patched" ;;
esac
sync

back_to_stock() {
	echo "install: $*" >&2
	echo "install: rolling back to the stock EmulationStation" >&2
	bash ./rollback.sh >&2 || true
	exit 1
}

bash "$SERVICE" start || back_to_stock "the service did not start"
[ "$(sha "$TARGET")" = "$(manifest LAUNCHER_SHA256)" ] || back_to_stock "launcher not mounted on $TARGET"

# Readback: the patched build runs and its web API answers
running=no
for i in $(seq "$READY_WAIT"); do
	sleep 1
	curl -fs -m 2 -o /dev/null "$ES_API/caps" || continue
	for pid in $(pidof emulationstation); do
		[ "$(readlink "/proc/$pid/exe")" = "$ROOT/bin/emulationstation" ] && running=yes
	done
	[ "$running" = yes ] && break
done
[ "$running" = yes ] || back_to_stock "the patched ES is not running with its web API up after ${READY_WAIT}s (a game running at install time also ends here)"
echo "ES running: $ROOT/bin/emulationstation, web API answers after ${i}s"

# Screen check: one frame of the framebuffer must not be uniformly black
sleep 3
frame=$(mktemp /tmp/es-patched-frame.XXXXXX.png)
fbgrab -d "$FB" "$frame" > /dev/null 2>&1 || { rm -f "$frame"; back_to_stock "fbgrab of $FB failed"; }
if python3 -I files/fbcheck.py "$frame"; then shown=0; else shown=$?; fi
rm -f "$frame"
[ "$shown" = 0 ] || back_to_stock "the screen is black or unreadable (fbcheck status $shown); with the battery saver dimming or a display off, wake the console and try again"

echo "LOOK AT THE CONSOLE NOW: the EmulationStation menu must be on screen and respond to the buttons. If it does not, run rollback.sh."
