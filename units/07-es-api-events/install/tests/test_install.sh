#!/bin/bash
# Off-device dry run of install.sh, files/service.sh and rollback.sh (Linux, bash, root).
# mount/umount, pidof, pgrep, readlink, kill, curl, fbgrab and knulli-settings-get/set are
# stubs; a bind mount is simulated by copying the source over the target, restored on umount.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi; }
sha() { sha256sum "$1" | cut -d ' ' -f 1; }
manifest() { sed -n "s/^$1=//p" "$HERE/payload/manifest"; }

mkdir -p "$T/bin"
cat > "$T/bin/mount" <<'X'
#!/bin/bash
[ "$1" = --bind ] || exit 1
cp -p "$3" "$3.under" 2>/dev/null || : > "$3.under"
cp "$2" "$3" && echo "bind $3 " >> "$ES_PATCHED_MOUNTS"
X
cat > "$T/bin/umount" <<'X'
#!/bin/bash
[ "$1" = -l ] && shift
grep -q " $1 " "$ES_PATCHED_MOUNTS" || exit 1
mv -f "$1.under" "$1" && grep -v " $1 " "$ES_PATCHED_MOUNTS" > "$ES_PATCHED_MOUNTS.new"; mv "$ES_PATCHED_MOUNTS.new" "$ES_PATCHED_MOUNTS"
X
cat > "$T/bin/pidof" <<'X'
#!/bin/bash
cat "$FAKE/pids" 2>/dev/null
X
cat > "$T/bin/pgrep" <<'X'
#!/bin/bash
[ -e "$FAKE/standalone" ]
X
cat > "$T/bin/readlink" <<'X'
#!/bin/bash
case "$1" in /proc/*/exe) p=${1#/proc/}; cat "$FAKE/exe-${p%/exe}" ;; *) /bin/readlink "$@" ;; esac
X
# kill -SIG 100: ES 100 exits and the loop starts it again as $FAKE/next-exe, API up
cat > "$T/bin/fakekill" <<'X'
#!/bin/bash
echo "$1 $2" >> "$FAKE/kills"; cat "$FAKE/next-exe" > "$FAKE/exe-$2"; : > "$FAKE/api-up"
X
cat > "$T/bin/curl" <<'X'
#!/bin/bash
url=${!#}; data=
while [ $# -gt 1 ]; do [ "$1" = --data-binary ] && data=$2; shift; done
case "$url" in
	*/caps) [ -e "$FAKE/api-up" ] ;;
	*/runningGame) printf '%s' "$(cat "$FAKE/running-code")" ;;
	*/quit) : > "$FAKE/quit-called"; cat "$FAKE/next-exe" > "$FAKE/exe-100" ;;
	*/notify) echo "$data" >> "$FAKE/notify" ;;
esac
X
cat > "$T/bin/fbgrab" <<'X'
#!/bin/bash
cp "$FAKE/frame.png" "${!#}"
X
cat > "$T/bin/knulli-settings-get" <<'X'
#!/bin/bash
sed -n "s/^$1=//p" "$ES_PATCHED_CONF"
X
cat > "$T/bin/knulli-settings-set" <<'X'
#!/bin/bash
grep -v "^$1=" "$ES_PATCHED_CONF" > "$ES_PATCHED_CONF.new"; echo "$1=$2" >> "$ES_PATCHED_CONF.new"; mv "$ES_PATCHED_CONF.new" "$ES_PATCHED_CONF"
X
chmod 755 "$T"/bin/*

# Screen frames: an ES-like frame (dark with some white) and a black one
python3 - "$T" <<'PY'
import struct, sys, zlib
def png(path, rows):
    raw = b''.join(b'\x00' + bytes(r) for r in rows)
    chunk = lambda k, d: struct.pack('>I', len(d)) + k + d + struct.pack('>I', zlib.crc32(k + d))
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 64, 48, 8, 2, 0, 0, 0))
                           + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))
black = [[0] * 64 * 3 for _ in range(48)]
menu = [list(r) for r in black]; menu[20][30:60] = [255] * 30
png(sys.argv[1] + '/menu.png', menu); png(sys.argv[1] + '/black.png', black)
PY

reset() {
	rm -rf "$T/dev" "$T/fake" && mkdir -p "$T/dev/usr/bin" "$T/dev/userdata/system/services" "$T/dev/run" "$T/fake"
	# a stand-in for the stock binary; the bundle manifest is pointed at it
	echo '#!/bin/sh' > "$T/dev/usr/bin/emulationstation"
	printf 'Anbernic RG35XX-H\0' > "$T/dev/model"
	echo 'scarab 2026/05/11 00:09' > "$T/dev/version"
	printf 'system.services=romm_autosync btaudio\nother=1\n' > "$T/dev/userdata/system/knulli.conf"
	: > "$T/dev/mounts"; : > "$T/dev/loop-flag"; : > "$T/fake/standalone"
	echo 201 > "$T/fake/running-code"
	: > "$T/fake/api-up"
	cp "$T/menu.png" "$T/fake/frame.png"
	echo 100 > "$T/fake/pids"; echo "$ES_PATCHED_TARGET" > "$T/fake/exe-100"
	echo "$ES_PATCHED_ROOT/bin/emulationstation" > "$T/fake/next-exe"
	rm -rf "$T/bundle" && cp -r "$HERE" "$T/bundle"
	sed -i "s/^STOCK_SHA256=.*/STOCK_SHA256=$(sha "$T/dev/usr/bin/emulationstation")/" "$T/bundle/payload/manifest"
}
stock_sha() { sed -n "s/^STOCK_SHA256=//p" "$T/bundle/payload/manifest"; }
rolled_back() { [ "$(sha $ES_PATCHED_TARGET)" = "$(stock_sha)" ] && [ ! -s $T/dev/mounts ] && [ "$(knulli-settings-get system.services)" = "romm_autosync btaudio" ]; }

export PATH="$T/bin:$PATH" FAKE="$T/fake"
export ES_PATCHED_ROOT="$T/dev/userdata/system/es-patched" ES_PATCHED_TARGET="$T/dev/usr/bin/emulationstation" \
	ES_PATCHED_RUN="$T/dev/run" ES_PATCHED_SERVICE="$T/dev/userdata/system/services/es_patched" \
	ES_PATCHED_CONF="$T/dev/userdata/system/knulli.conf" ES_PATCHED_MODEL_FILE="$T/dev/model" \
	ES_PATCHED_VERSION_FILE="$T/dev/version" ES_PATCHED_LOG="$T/dev/es-patched.log" \
	ES_PATCHED_MOUNTS="$T/dev/mounts" ES_PATCHED_LOOP_FLAG="$T/dev/loop-flag" ES_PATCHED_KILL="$T/bin/fakekill" \
	ES_PATCHED_API_WAIT=2 ES_PATCHED_READY_WAIT=3

# Install while the stock ES (pid 100) runs, loaded, no game running
reset
out=$(bash "$T/bundle/install.sh" 2>&1); rc=$?
check "install succeeds and asks the owner to look at the screen" '[ $rc = 0 ] && echo "$out" | grep -q "LOOK AT THE CONSOLE NOW"'
check "launcher is mounted on the ES path, stock copy kept" '[ "$(sha $ES_PATCHED_TARGET)" = "$(manifest LAUNCHER_SHA256)" ] && [ "$(sha "$T/dev/run/emulationstation.stock")" = "$(stock_sha)" ]'
check "loaded stock ES was asked to quit, not killed" '[ -e "$T/fake/quit-called" ] && [ ! -e "$T/fake/kills" ]'
check "readback found the patched build with its API up" 'echo "$out" | grep -q "ES running: $ES_PATCHED_ROOT/bin/emulationstation, web API answers"'
check "service enabled, other services kept, knulli.conf backed up" '[ "$(knulli-settings-get system.services)" = "romm_autosync btaudio es_patched" ] && ls "$T"/dev/userdata/system/knulli.conf.bak-*-es_patched >/dev/null'
check "patched binary and launcher installed with the manifest" '[ "$(sha $ES_PATCHED_ROOT/bin/emulationstation)" = "$(manifest PATCHED_SHA256)" ] && [ -x $ES_PATCHED_ROOT/launcher.sh ]'
out=$(bash "$ES_PATCHED_SERVICE" start 2>&1)
check "service start again: already active, no second mount" '[ "$out" = "already active" ] && [ "$(grep -c . $T/dev/mounts)" = 2 ]'
out=$(bash "$T/bundle/install.sh" 2>&1); rc=$?
check "install while active refuses" '[ $rc != 0 ] && echo "$out" | grep -q "already active"'

# Rollback while the patched ES runs with its API up
echo "$ES_PATCHED_ROOT/bin/emulationstation" > "$T/fake/exe-100"; echo "$ES_PATCHED_TARGET" > "$T/fake/next-exe"; rm -f "$T/fake/quit-called"
out=$(bash "$T/bundle/rollback.sh" 2>&1); rc=$?
check "rollback: stock back, no mounts, service off" '[ $rc = 0 ] && rolled_back && [ ! -e $ES_PATCHED_SERVICE ]'
check "rollback: patched ES asked to quit, now stock" '[ -e "$T/fake/quit-called" ] && echo "$out" | grep -q "ES running: $ES_PATCHED_TARGET"'

# Black screen with a live API: install rolls back by itself
reset; cp "$T/black.png" "$T/fake/frame.png"
out=$(bash "$T/bundle/install.sh" 2>&1); rc=$?
check "black frame: install exits 1 and is rolled back to stock" '[ $rc = 1 ] && rolled_back && echo "$out" | grep -q "screen is black"'

# Stock ES still loading (no API yet) when the service starts: stopped at once
reset; rm -f "$T/fake/api-up"
out=$(bash "$T/bundle/install.sh" 2>&1); rc=$?
check "stock ES still loading: killed right away, no /quit, install succeeds" '[ $rc = 0 ] && [ "$(cat $T/fake/kills)" = "-KILL 100" ] && [ ! -e "$T/fake/quit-called" ]'

# Game running at install: ES stays stock, so install rolls back
reset; echo 200 > "$T/fake/running-code"
out=$(bash "$T/bundle/install.sh" 2>&1); rc=$?
check "game running: no restart, install exits 1 and rolls back" '[ $rc = 1 ] && [ ! -e "$T/fake/quit-called" ] && rolled_back'

# Not under emulationstation-standalone: refuse before changing anything
reset; rm -f "$T/fake/standalone"
out=$(bash "$T/bundle/install.sh" 2>&1); rc=$?
check "no standalone loop: install refuses, nothing installed" '[ $rc = 1 ] && [ ! -e $ES_PATCHED_ROOT ] && [ "$(knulli-settings-get system.services)" = "romm_autosync btaudio" ]'

# Rollback of a patched ES without web API: stopped, the loop starts stock
reset; bash "$T/bundle/install.sh" >/dev/null 2>&1
echo "$ES_PATCHED_ROOT/bin/emulationstation" > "$T/fake/exe-100"; echo "$ES_PATCHED_TARGET" > "$T/fake/next-exe"; rm -f "$T/fake/api-up" "$T/fake/kills"
bash "$T/bundle/rollback.sh" >/dev/null 2>&1; rc=$?
check "rollback of a hung patched ES: TERM, stock back" '[ $rc = 0 ] && [ "$(cat $T/fake/kills)" = "-TERM 100" ] && rolled_back'

# Service on its own: fails closed and tells ES; automatic disable expiry; manual use-stock
reset; bash "$T/bundle/install.sh" >/dev/null 2>&1; bash "$T/bundle/rollback.sh" >/dev/null 2>&1
cp "$T/bundle/files/service.sh" "$T/svc.sh"; cp "$T/bundle/payload/manifest" "$ES_PATCHED_ROOT/manifest"; rm -f "$T/fake/notify"
echo 'scarab 2026/06/01 00:00' > "$T/dev/version"
bash "$T/svc.sh" start >/dev/null 2>&1; rc=$?
check "other firmware: exits 1, mounts nothing, ES notified" '[ $rc = 1 ] && [ ! -s $T/dev/mounts ] && grep -q "other firmware" "$T/fake/notify"'
echo 'scarab 2026/05/11 00:09' > "$T/dev/version"; printf 'Other\0' > "$T/dev/model"
bash "$T/svc.sh" start >/dev/null 2>&1; rc=$?
check "other model: exits 1 and mounts nothing" '[ $rc = 1 ] && [ ! -s $T/dev/mounts ]'
printf 'Anbernic RG35XX-H\0' > "$T/dev/model"; echo corrupt >> "$ES_PATCHED_ROOT/bin/emulationstation"; rm -f "$T/fake/notify"
bash "$T/svc.sh" start >/dev/null 2>&1; rc=$?
check "damaged patched binary: exits 1, mounts nothing, ES notified" '[ $rc = 1 ] && [ ! -s $T/dev/mounts ] && grep -q "checksum" "$T/fake/notify"'
cp "$T/bundle/payload/emulationstation" "$ES_PATCHED_ROOT/bin/emulationstation"; echo '#!/bin/sh # other' > "$ES_PATCHED_TARGET"
bash "$T/svc.sh" start >/dev/null 2>&1; rc=$?
check "unexpected /usr/bin/emulationstation: exits 1 and mounts nothing" '[ $rc = 1 ] && [ ! -s $T/dev/mounts ]'
echo '#!/bin/sh' > "$ES_PATCHED_TARGET"; mkdir -p "$ES_PATCHED_ROOT/state"
: > "$ES_PATCHED_ROOT/state/use-stock"
bash "$T/svc.sh" start >/dev/null 2>&1; rc=$?
check "use-stock set by the owner: exits 0, mounts nothing" '[ $rc = 0 ] && [ ! -s $T/dev/mounts ]'
rm -f "$ES_PATCHED_ROOT/state/use-stock" "$T/fake/notify"; : > "$ES_PATCHED_ROOT/state/disabled"; rm -f "$ES_PATCHED_ROOT/state/ok-version"
bash "$T/svc.sh" start >/dev/null 2>&1; rc=$?
check "disabled, never started fine here: stays on stock, ES notified" '[ $rc = 0 ] && [ ! -s $T/dev/mounts ] && [ -e "$ES_PATCHED_ROOT/state/disabled" ] && grep -q "stays disabled" "$T/fake/notify"'
echo 'scarab 2026/05/11 00:09' > "$ES_PATCHED_ROOT/state/ok-version"; echo 2 > "$ES_PATCHED_ROOT/state/failures"
echo 300 > "$T/fake/pids"
bash "$T/svc.sh" start >/dev/null 2>&1; rc=$?
check "disabled after it started fine on this firmware: expires at boot, launcher mounted" '[ $rc = 0 ] && [ ! -e "$ES_PATCHED_ROOT/state/disabled" ] && [ ! -e "$ES_PATCHED_ROOT/state/failures" ] && [ "$(sha $ES_PATCHED_TARGET)" = "$(sha $ES_PATCHED_ROOT/launcher.sh)" ]'

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
