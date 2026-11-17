#!/bin/bash
# Go back to the stock EmulationStation (run as root). Disables the es_patched service
# (knulli.conf backed up first), removes the launcher mount and restarts ES on the stock
# binary unless a game is running. Keeps /userdata/system/es-patched unless --purge.
set -eu

ROOT=${ES_PATCHED_ROOT:-/userdata/system/es-patched}
TARGET=${ES_PATCHED_TARGET:-/usr/bin/emulationstation}
RUN=${ES_PATCHED_RUN:-/var/run/es-patched}
SERVICE=${ES_PATCHED_SERVICE:-/userdata/system/services/es_patched}
CONF=${ES_PATCHED_CONF:-/userdata/system/knulli.conf}
ES_API=${ES_PATCHED_ES_API:-http://127.0.0.1:1234}
LOOP_FLAG=${ES_PATCHED_LOOP_FLAG:-/var/run/emulationstation-standalone}
PURGE=no
[ "${1:-}" = --purge ] && PURGE=yes

die() { echo "rollback: $*" >&2; exit 1; }
manifest() { sed -n "s/^$1=//p" "$ROOT/manifest" 2>/dev/null; }
sha() { sha256sum "$1" | cut -d ' ' -f 1; }
mounted() { grep -q " $1 " "${ES_PATCHED_MOUNTS:-/proc/mounts}"; }

[ "$(id -u)" = 0 ] || die "run as root"

# 1. Service off (next boots stay on stock)
services=$(knulli-settings-get system.services || true)
case " $services " in
	*" es_patched "*)
		cp -p "$CONF" "$CONF.bak-$(date +%Y%m%d-%H%M%S)-es_patched-rollback"
		knulli-settings-set system.services "$(for s in $services; do [ "$s" = es_patched ] || printf '%s ' "$s"; done | sed 's/ $//')"
		;;
esac
case " $(knulli-settings-get system.services) " in
	*" es_patched "*) die "system.services still lists es_patched" ;;
esac
if [ -e "$SERVICE" ]; then
	mkdir -p "$ROOT"
	mv -f "$SERVICE" "$ROOT/service.removed"
fi
sync

# 2. Stock binary back on /usr/bin/emulationstation
mounted "$TARGET" && umount -l "$TARGET"
[ "$(sha "$TARGET")" = "$(manifest STOCK_SHA256)" ] || [ -z "$(manifest STOCK_SHA256)" ] || die "$TARGET is not the stock binary after umount"

# 3. Restart ES if it runs the patched build and no game is running
restarted=no
for pid in $(pidof emulationstation); do
	case "$(readlink "/proc/$pid/exe")" in
		"$ROOT"/*)
			if ! { [ -e "$LOOP_FLAG" ] && pgrep -f emulationstation-standalone > /dev/null; }; then
				echo "rollback: ES is not under emulationstation-standalone; restart ES yourself to get the stock one"
			elif ! curl -fs -m 2 -o /dev/null "$ES_API/caps"; then
				# No web API (hung or still loading): stop it; the loop starts the stock binary
				"${ES_PATCHED_KILL:-kill}" -TERM "$pid" && restarted=yes
			elif [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$ES_API/runningGame")" = 201 ]; then
				curl -fs -m 5 -o /dev/null "$ES_API/quit" && restarted=yes
			else
				echo "rollback: a game is running; ES switches to stock at its next start"
			fi
			;;
	esac
done
if [ "$restarted" = yes ]; then
	for i in $(seq 180); do
		sleep 1
		curl -fs -m 2 -o /dev/null "$ES_API/caps" && break
	done
fi
for pid in $(pidof emulationstation); do echo "ES running: $(readlink "/proc/$pid/exe")"; done

# 4. Stock copy mount is only used by the launcher
mounted "$RUN/emulationstation.stock" && umount -l "$RUN/emulationstation.stock"

if [ "$PURGE" = yes ]; then
	rm -rf "$ROOT"
	echo "removed $ROOT"
fi
echo "stock EmulationStation restored"
