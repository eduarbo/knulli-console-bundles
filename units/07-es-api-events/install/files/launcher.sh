#!/bin/bash
# EmulationStation launcher, bind-mounted over /usr/bin/emulationstation by the
# es_patched user service. emulationstation-standalone runs it on every ES start.
#
# Runs the patched build from /userdata, and the untouched stock binary instead when:
# - state/use-stock exists (set by the owner, never expires);
# - state/disabled exists: the patched build failed twice in a row (crash, failed start, or
#   no web API answer within START_TIMEOUT seconds). The service clears it at the next boot
#   on the same firmware if the patched build has started fine there before (state/ok-version);
# - the patched binary is missing or was built for another firmware.
# Executables in $ROOT/pre-start.d run first (at most HOOK_TIMEOUT seconds each), whichever
# binary starts: fixes that must be in place before ES reads its files (e.g. a theme fix).

ROOT=${ES_PATCHED_ROOT:-/userdata/system/es-patched}
STOCK=${ES_PATCHED_STOCK:-/var/run/es-patched/emulationstation.stock}
VERSION_FILE=${ES_PATCHED_VERSION_FILE:-/usr/share/knulli/knulli.version}
LOG=${ES_PATCHED_LOG:-/userdata/system/logs/es-patched.log}
API=${ES_PATCHED_API:-http://127.0.0.1:1234/caps}
NOTIFY=${ES_PATCHED_NOTIFY:-http://127.0.0.1:1234/notify}
START_TIMEOUT=${ES_PATCHED_START_TIMEOUT:-300}
HOOK_TIMEOUT=${ES_PATCHED_HOOK_TIMEOUT:-10}
CRASH_LIMIT=2

PATCHED=$ROOT/bin/emulationstation
STATE=$ROOT/state

# pidof/killall emulationstation (S31emulationstation, battery saver) must find ES only
printf 'es-launcher' > /proc/$$/comm 2>/dev/null

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; }

# Show a message in ES once its web API answers (in the background, survives exec)
notify_when_up() {
	(
		for i in $(seq "$START_TIMEOUT"); do
			curl -fs -m 2 -o /dev/null "$API" && break
			sleep 1
		done
		curl -fs -m 5 -o /dev/null -H 'Content-Type: text/plain' --data-binary "$1" "$NOTIFY"
	) > /dev/null 2>&1 &
}

run_stock() {
	[ -x "$STOCK" ] && exec "$STOCK" "$@"
	log "stock binary missing at $STOCK"
	exit 127
}

for hook in "$ROOT"/pre-start.d/*; do
	[ -f "$hook" ] && [ -x "$hook" ] || continue
	timeout -k 2 "$HOOK_TIMEOUT" "$hook" >> "$LOG" 2>&1 || log "pre-start hook $hook failed ($?)"
done

[ -e "$STATE/use-stock" ] && run_stock "$@"
[ -e "$STATE/disabled" ] && run_stock "$@"

version=$(cat "$VERSION_FILE" 2>/dev/null)
expected=$(sed -n 's/^VERSION=//p' "$ROOT/manifest" 2>/dev/null)
if [ ! -x "$PATCHED" ] || [ -z "$expected" ] || [ "$version" != "$expected" ]; then
	log "patched build missing or made for other firmware; running stock"
	run_stock "$@"
fi

mkdir -p "$STATE"
rm -f "$STATE/start-timeout"
started=$(date +%s)

"$PATCHED" "$@" &
pid=$!
trap 'kill -TERM $pid 2>/dev/null' TERM INT HUP

# Start watchdog: the web API comes up once ES has loaded its systems and gamelists.
# Time while ES is stopped (battery saver) does not count.
(
	waited=0
	while [ "$waited" -lt "$START_TIMEOUT" ]; do
		kill -0 "$pid" 2>/dev/null || exit 0
		if curl -fs -m 2 -o /dev/null "$API"; then
			log "patched ES answered after ${waited}s ($(( $(date +%s) - started ))s with pauses)"
			[ "$(cat "$STATE/ok-version" 2>/dev/null)" = "$version" ] || echo "$version" > "$STATE/ok-version"
			exit 0
		fi
		[ "$(cut -d ' ' -f 3 "/proc/$pid/stat" 2>/dev/null)" = T ] || waited=$((waited + 1))
		sleep 1
	done
	log "patched ES did not answer within ${START_TIMEOUT}s; stopping it"
	: > "$STATE/start-timeout"
	kill -TERM "$pid" 2>/dev/null
	sleep 10
	kill -KILL "$pid" 2>/dev/null
) &
watchdog=$!

wait "$pid"
rc=$?
while kill -0 "$pid" 2>/dev/null; do
	wait "$pid"
	rc=$?
done
kill "$watchdog" 2>/dev/null
wait "$watchdog" 2>/dev/null

# Clean exit, or stopped from outside (HUP, INT, KILL, TERM: shutdown, S31 stop)
crash=1
case "$rc" in 0|129|130|137|143) crash=0 ;; esac
if [ -e "$STATE/start-timeout" ]; then
	rm -f "$STATE/start-timeout"
	crash=1
fi

if [ "$crash" = 0 ]; then
	rm -f "$STATE/failures"
	exit "$rc"
fi

failures=$(( $(cat "$STATE/failures" 2>/dev/null || echo 0) + 1 ))
# Cannot count (e.g. /userdata full): do not risk a crash loop
echo "$failures" > "$STATE/failures" 2>/dev/null || run_stock "$@"
log "patched ES ended with status $rc after $(( $(date +%s) - started ))s ($failures in a row)"

if [ "$failures" -ge "$CRASH_LIMIT" ]; then
	: > "$STATE/disabled"
	sync
	log "patched ES disabled after $failures failures in a row; running stock"
	notify_when_up "Patched EmulationStation failed $failures times in a row: running stock, fixes 07/14/15 are off. It is tried again at the next boot if it worked before on this firmware. Log: /userdata/system/logs/es-patched.log"
	run_stock "$@"
fi

exit "$rc"
