#!/bin/bash
# es_patched user service (/userdata/system/services/es_patched, listed in system.services).
# start: bind-mounts the launcher over /usr/bin/emulationstation, after keeping the stock
# binary reachable at /var/run/es-patched/emulationstation.stock. Nothing on the rootfs
# changes and the mounts are gone after a reboot without this service. Fails closed
# (nothing mounted, ES told) on another model, another firmware or any unexpected file.

ROOT=${ES_PATCHED_ROOT:-/userdata/system/es-patched}
TARGET=${ES_PATCHED_TARGET:-/usr/bin/emulationstation}
RUN=${ES_PATCHED_RUN:-/var/run/es-patched}
MODEL_FILE=${ES_PATCHED_MODEL_FILE:-/proc/device-tree/model}
VERSION_FILE=${ES_PATCHED_VERSION_FILE:-/usr/share/knulli/knulli.version}
LOG=${ES_PATCHED_LOG:-/userdata/system/logs/es-patched.log}
ES_API=${ES_PATCHED_ES_API:-http://127.0.0.1:1234}
API_WAIT=${ES_PATCHED_API_WAIT:-300}
MOUNTS=${ES_PATCHED_MOUNTS:-/proc/mounts}
LOOP_FLAG=${ES_PATCHED_LOOP_FLAG:-/var/run/emulationstation-standalone}
KILL=${ES_PATCHED_KILL:-kill}
STOCK=$RUN/emulationstation.stock
STATE=$ROOT/state

log() { printf '%s service: %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; echo "$*"; }
manifest() { sed -n "s/^$1=//p" "$ROOT/manifest" 2>/dev/null; }
sha() { sha256sum "$1" 2>/dev/null | cut -d ' ' -f 1; }
mounted() { grep -q " $1 " "$MOUNTS" 2>/dev/null; }
api_up() { curl -fs -m 2 -o /dev/null "$ES_API/caps"; }

# Tell the owner in ES (once its web API answers) that the fixes are off
notify() {
	local i
	for i in $(seq "$API_WAIT"); do
		api_up && break
		sleep 1
	done
	curl -fs -m 5 -o /dev/null -H 'Content-Type: text/plain' --data-binary "$1" "$ES_API/notify"
}

fail() {
	log "not started: $*"
	notify "Patched EmulationStation not started ($*): running stock, fixes 07/14/15 are off."
	exit 1
}

# emulationstation-standalone starts ES again when it exits; without it ES would stay down
under_standalone() { [ -e "$LOOP_FLAG" ] && pgrep -f emulationstation-standalone > /dev/null; }

# ES started before the mount runs the stock binary: get it restarted through the launcher.
# Still loading (no web API yet): stop it now, it has written nothing yet, so the loop starts
# the launcher without a full stock load. Loaded: ask it to quit, unless a game is running
# (then the launcher takes over at the next ES start).
restart_stock_es() {
	local pid
	for pid in $(pidof emulationstation); do
		[ "$(readlink "/proc/$pid/exe")" = "$TARGET" ] || continue
		if ! under_standalone; then
			log "ES not under emulationstation-standalone; the patched build starts with the next ES start"
			return 0
		fi
		if ! api_up; then
			"$KILL" -KILL "$pid" && log "stopped the stock ES while it was loading; the loop starts the launcher"
			return 0
		fi
		if [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$ES_API/runningGame")" != 201 ]; then
			log "ES busy; the patched build starts with the next ES start"
			return 0
		fi
		curl -fs -m 5 -o /dev/null "$ES_API/quit" && log "restarting ES through the launcher"
		return 0
	done
}

start() {
	[ "$(tr -d '\000' < "$MODEL_FILE" 2>/dev/null)" = "$(manifest MODEL)" ] || fail "other model"
	[ "$(cat "$VERSION_FILE" 2>/dev/null)" = "$(manifest VERSION)" ] || fail "other firmware"
	if [ -e "$STATE/use-stock" ]; then
		log "use-stock set by the owner; staying on stock"
		exit 0
	fi
	if [ -e "$STATE/disabled" ]; then
		# Automatic disable lasts one boot if this build has started fine on this firmware
		if [ "$(cat "$STATE/ok-version" 2>/dev/null)" = "$(manifest VERSION)" ]; then
			rm -f "$STATE/disabled" "$STATE/failures"
			log "automatic disable expired (it started fine here before); trying the patched build again"
		else
			log "disabled after failures in a row and never started fine here; staying on stock (run install.sh to try again)"
			notify "Patched EmulationStation stays disabled after repeated failures: running stock, fixes 07/14/15 are off."
			exit 0
		fi
	fi
	[ "$(sha "$ROOT/launcher.sh")" = "$(manifest LAUNCHER_SHA256)" ] || fail "launcher checksum"
	[ "$(sha "$ROOT/bin/emulationstation")" = "$(manifest PATCHED_SHA256)" ] || fail "patched binary checksum"

	local current
	current=$(sha "$TARGET")
	if [ "$current" = "$(manifest LAUNCHER_SHA256)" ]; then
		echo "already active"
		exit 0
	fi
	[ "$current" = "$(manifest STOCK_SHA256)" ] || fail "unexpected $TARGET"

	mkdir -p "$RUN" || fail "cannot create $RUN"
	if ! mounted "$STOCK"; then
		: > "$STOCK" && mount --bind "$TARGET" "$STOCK" || fail "cannot keep the stock binary"
	fi
	if [ "$(sha "$STOCK")" != "$(manifest STOCK_SHA256)" ]; then
		umount "$STOCK"
		fail "stock copy checksum"
	fi
	mount --bind "$ROOT/launcher.sh" "$TARGET" || { umount "$STOCK"; fail "cannot mount the launcher"; }
	log "launcher active"
	restart_stock_es
}

status() {
	echo "target:   $(sha "$TARGET") $TARGET"
	echo "launcher: $(manifest LAUNCHER_SHA256)"
	echo "stock:    $(manifest STOCK_SHA256)"
	echo "use-stock: $([ -e "$STATE/use-stock" ] && echo yes || echo no), disabled: $([ -e "$STATE/disabled" ] && echo yes || echo no), failures: $(cat "$STATE/failures" 2>/dev/null || echo 0), started fine on: $(cat "$STATE/ok-version" 2>/dev/null || echo never)"
	local pid
	for pid in $(pidof emulationstation); do echo "running:  $pid $(readlink "/proc/$pid/exe")"; done
}

case "$1" in
	start) start ;;
	stop) exit 0 ;;
	status) status ;;
	*) echo "usage: $0 start|stop|status"; exit 1 ;;
esac
