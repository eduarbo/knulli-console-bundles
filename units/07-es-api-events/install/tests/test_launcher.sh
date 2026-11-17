#!/bin/bash
# Off-device tests of files/launcher.sh with fake ES binaries (Linux, bash, curl).
# usage: tests/test_launcher.sh   (from the install folder or anywhere)
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
LAUNCHER=$HERE/files/launcher.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# curl: real for file:// (the fake web API), recorded for /notify
REAL_CURL=$(command -v curl)
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<X
#!/bin/bash
case "\${!#}" in
	*notify.invalid*) while [ \$# -gt 1 ]; do [ "\$1" = --data-binary ] && echo "\$2" >> "$T/out/notify"; shift; done ;;
	*) exec "$REAL_CURL" "\$@" ;;
esac
X
chmod 755 "$T/bin/curl"
export PATH="$T/bin:$PATH"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
ko() { fail=$((fail + 1)); echo "FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else ko "$1"; fi; }

setup() {
	rm -rf "$T/root" "$T/run" "$T/out"
	mkdir -p "$T/root/bin" "$T/run" "$T/out"
	echo 'scarab 2026/05/11 00:09' > "$T/version"
	printf 'MODEL=Anbernic RG35XX-H\nVERSION=scarab 2026/05/11 00:09\n' > "$T/root/manifest"
	cat > "$T/run/emulationstation.stock" <<X
#!/bin/bash
echo "stock \$*" >> "\$OUT/runs"
: > "$T/api-up"
exit 0
X
	chmod 755 "$T/run/emulationstation.stock"
	rm -f "$T/api-up"
}

# fake patched ES: $1 = behaviour (ok, segv, abrt, exit1, exit127, term, hang, up-then-ok)
patched() {
	cat > "$T/root/bin/emulationstation" <<X
#!/bin/bash
echo "patched \$*" >> "\$OUT/runs"
cat /proc/\$PPID/comm > "\$OUT/launcher-comm"
case "$1" in
	ok) : > "$T/api-up"; exit 0 ;;
	up) : > "$T/api-up"; sleep 2; exit 0 ;;
	segv) kill -SEGV \$\$ ;;
	abrt) kill -ABRT \$\$ ;;
	exit1) exit 1 ;;
	exit127) exit 127 ;;
	term) : > "$T/api-up"; kill -TERM \$\$ ;;
	hang) sleep 60 ;;
esac
X
	chmod 755 "$T/root/bin/emulationstation"
}

launch() {
	OUT=$T/out ES_PATCHED_ROOT=$T/root ES_PATCHED_STOCK=$T/run/emulationstation.stock \
	ES_PATCHED_VERSION_FILE=$T/version ES_PATCHED_LOG=$T/out/log ES_PATCHED_API=file://$T/api-up 	ES_PATCHED_NOTIFY=http://notify.invalid/notify \
	ES_PATCHED_START_TIMEOUT=${TIMEOUT:-30} bash "$LAUNCHER" "$@"
}
runs() { cat "$T/out/runs" 2>/dev/null | tr '\n' '|'; }
failures() { cat "$T/root/state/failures" 2>/dev/null || echo 0; }
export OUT=$T/out

setup; patched ok
launch --no-startup-game --exit-on-reboot-required; rc=$?
check "clean run uses the patched build with the same arguments" '[ "$(runs)" = "patched --no-startup-game --exit-on-reboot-required|" ] && [ $rc = 0 ]'
check "launcher does not call itself emulationstation" '[ "$(cat $T/out/launcher-comm)" = es-launcher ]'

setup; patched segv
launch; rc1=$?
check "first crash: status returned, one failure, still enabled" '[ $rc1 = 139 ] && [ "$(failures)" = 1 ] && [ ! -e $T/root/state/disabled ] && [ "$(runs)" = "patched |" ]'
launch -x; rc2=$?
check "second crash in a row: disabled and stock started at once" '[ -e $T/root/state/disabled ] && [ "$(runs)" = "patched |patched -x|stock -x|" ] && [ $rc2 = 0 ]'
patched ok
launch -y
check "once disabled, stock runs without trying the patched build" '[ "$(runs)" = "patched |patched -x|stock -x|stock -y|" ]'

setup; patched abrt; launch; patched ok; launch; patched exit1; launch
check "a clean run in between resets the count" '[ "$(failures)" = 1 ] && [ ! -e $T/root/state/disabled ]'

setup; patched term; launch; rc=$?; patched segv; launch
check "stopped from outside (TERM) is not a crash" '[ $rc = 143 ] && [ "$(failures)" = 1 ]'

setup; patched exit127; launch; launch
check "failing to start (status 127) twice falls back to stock" '[ -e $T/root/state/disabled ] && [ "$(runs)" = "patched |patched |stock |" ]'

setup; patched hang; start=$(date +%s); TIMEOUT=2 launch; rc=$?; took=$(( $(date +%s) - start ))
check "no API answer within the start timeout counts as a failure" '[ "$(failures)" = 1 ] && [ $took -lt 30 ] && grep -q "did not answer" $T/out/log'

setup; patched ok; echo 'scarab 2026/06/01 00:00' > "$T/version"; launch
check "other firmware version: stock, patched build untouched" '[ "$(runs)" = "stock |" ] && [ "$(failures)" = 0 ]'

setup; rm -f "$T/root/bin/emulationstation"; launch
check "missing patched binary: stock" '[ "$(runs)" = "stock |" ]'

setup; patched segv; rm -f "$T/run/emulationstation.stock"; launch; launch; rc=$?
check "stock missing too: exits 127 and logs it" '[ $rc = 127 ] && grep -q "stock binary missing" $T/out/log'

setup; patched ok; mkdir -p "$T/root/pre-start.d"
printf '#!/bin/bash
echo hook >> "$OUT/runs"
' > "$T/root/pre-start.d/fix"; chmod 755 "$T/root/pre-start.d/fix"
launch
check "pre-start hooks run before the patched build" '[ "$(runs)" = "hook|patched |" ]'
: > "$T/root/state/disabled"; launch
check "pre-start hooks run before the stock binary too" '[ "$(runs)" = "hook|patched |hook|stock |" ]'
setup; patched ok; mkdir -p "$T/root/pre-start.d"
printf '#!/bin/bash
sleep 30
' > "$T/root/pre-start.d/slow"; chmod 755 "$T/root/pre-start.d/slow"
start=$(date +%s); ES_PATCHED_HOOK_TIMEOUT=1 launch; took=$(( $(date +%s) - start ))
check "a hanging hook is cut off and ES still starts" '[ $took -lt 10 ] && [ "$(runs)" = "patched |" ] && grep -q "pre-start hook" $T/out/log'

setup; patched segv; mkdir -p "$T/root/state"; mkdir "$T/root/state/failures"; launch -z
check "failure count cannot be written: stock right after the crash" '[ "$(runs)" = "patched -z|stock -z|" ]'

setup; patched up; launch
check "a start that answers logs the time to API and records the firmware it worked on" 'grep -q "patched ES answered after" $T/out/log && [ "$(cat $T/root/state/ok-version)" = "scarab 2026/05/11 00:09" ]'

setup; patched segv; launch; launch; sleep 2
check "disabling itself tells ES (notify) that the fixes are off" 'grep -q "fixes 07/14/15 are off" "$T/out/notify"'

setup; patched ok; mkdir -p "$T/root/state"; : > "$T/root/state/use-stock"; launch -u
check "use-stock (owner): stock, no notify" '[ "$(runs)" = "stock -u|" ] && [ ! -e "$T/out/notify" ]'
check "default start timeout is 300 s" 'grep -q "START_TIMEOUT:-300" "$LAUNCHER"'

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
