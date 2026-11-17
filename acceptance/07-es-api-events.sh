#!/bin/bash
# Readback after install.sh, run by fix_updater from the unit folder (unit 07 acceptance
# step 2): the launcher is on /usr/bin/emulationstation, ES runs the patched build and its
# web API answers. install.sh itself already required the same plus a non-black frame.
# --installed: installed state only (no comparison with this folder's payload).
ROOT=${ES_PATCHED_ROOT:-/userdata/system/es-patched}
TARGET=${ES_PATCHED_TARGET:-/usr/bin/emulationstation}
ES_API=${ES_PATCHED_ES_API:-http://127.0.0.1:1234}
manifest() { sed -n "s/^$1=//p" "$ROOT/manifest"; }
sha() { sha256sum "$1" | cut -d ' ' -f 1; }
[ "${1:-}" = --installed ] || [ "$(sha "$ROOT/manifest")" = "$(sha payload/manifest)" ] || { echo "07: installed manifest differs"; exit 1; }
[ "$(sha "$TARGET")" = "$(manifest LAUNCHER_SHA256)" ] || { echo "07: launcher not on $TARGET"; exit 1; }
for i in $(seq 60); do
	curl -fs -m 2 -o /dev/null "$ES_API/caps" && break
	sleep 2
done
running=no
for pid in $(pidof emulationstation); do
	[ "$(readlink "/proc/$pid/exe")" = "$ROOT/bin/emulationstation" ] && running=yes
done
[ "$running" = yes ] || { echo "07: ES does not run $ROOT/bin/emulationstation"; exit 1; }
curl -fs -m 2 -o /dev/null "$ES_API/caps" || { echo "07: web API does not answer"; exit 1; }
case " $(knulli-settings-get system.services) " in *" es_patched "*) ;; *) echo "07: es_patched not in system.services"; exit 1 ;; esac
echo "07: verified"
