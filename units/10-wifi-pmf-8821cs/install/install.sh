#!/bin/bash
# Install the generic Wi-Fi PMF fix (connman_pmf v3) on Knulli 20260511. Idempotent.
# Run on the console as root from this directory:  bash install.sh
# Restarting ConnMan drops Wi-Fi for a few seconds; the apply phase runs detached, so an SSH
# session over Wi-Fi may drop and the work still finishes. Read the outcome afterwards with
#   bash install.sh --result
# What it does:
#   - copies the candidate to /userdata/system/patches/connman_pmf/connmand-generic
#   - replaces /userdata/system/services/connman_pmf (the v2 wrapper is kept as v2-service.bak)
#   - system.services: adds connman_pmf if missing; nothing else changes (connman_bluetooth stays:
#     it only acts when the v2 build runs, e.g. after a fallback)
#   - starts the service and checks that the candidate runs and the default route comes back;
#     if the route was up before and does not come back in 60 s, it rolls back by itself.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
R="${KNULLI_TEST_ROOT:-}"
DIR="$R/userdata/system/patches/connman_pmf"
SVC="$R/userdata/system/services/connman_pmf"
BIN="$R/usr/sbin/connmand"
RESULT="$DIR/install-v3.result"
CANDIDATE=a43f5ff1e9140fde0eab2db47ea3bea8d8d0962209256a19ea026e921d0f9928
STOCK=e83607dc10d2fa7638ca475bec973b36cb9b46b3a61ca0e0bc7f202dcf2375ef
PINNED="7ba87d3fdc0e879973b834f4b93add692150a5a193f5f3ceb6768bc813b886aa cda54485fe1de38838791b59589fa30d33b954c8e64b7800b28c14b6b3812697"

sha() { sha256sum "$1" 2>/dev/null | cut -d ' ' -f 1; }
die() { echo "install: $*" >&2; exit 1; }
copy_atomic() { # src dst mode
    cp "$1" "$2.tmp.$$" && chmod "$3" "$2.tmp.$$" && mv -f "$2.tmp.$$" "$2" || { rm -f "$2.tmp.$$"; return 1; }
}
has_route() { [ -n "$(ip route show default 2>/dev/null)" ]; }

if [ "${1:-}" = "--result" ]; then
    cat "$RESULT" 2>/dev/null || echo "no result yet"
    exit 0
fi

if [ "${1:-}" = "--apply" ]; then
    # Detached phase: start the service, wait for the candidate and the route.
    had_route=$2
    echo "state=applying" >"$RESULT"
    bash "$SVC" start
    rc=$?
    status=$(bash "$SVC" status)
    if [ $rc -ne 0 ] || ! echo "$status" | grep -q '^active=candidate$'; then
        printf 'state=failed\nreason=candidate_not_active\n%s\n' "$status" >"$RESULT"
        bash "$HERE/rollback.sh" --after-failed-install >>"$RESULT" 2>&1
        exit 1
    fi
    if [ "$had_route" = 1 ]; then
        for _ in $(seq 1 "${CONNMAN_PMF_ROUTE_WAIT:-60}"); do has_route && break; sleep 1; done
        if ! has_route; then
            printf 'state=failed\nreason=no_default_route_after_60s\n%s\n' "$status" >"$RESULT"
            bash "$HERE/rollback.sh" --after-failed-install >>"$RESULT" 2>&1
            exit 1
        fi
    fi
    printf 'state=installed\nroute_checked=%s\n%s\n' "$had_route" "$status" >"$RESULT"
    exit 0
fi

# --- preflight (no changes yet) ---
[ -n "$R" ] || [ "$(id -u)" = 0 ] || die "run as root"
command -v knulli-settings-get >/dev/null || die "knulli-settings-get missing (not Knulli 2026?)"
[ "$(sha "$HERE/files/connmand")" = "$CANDIDATE" ] || die "files/connmand does not match the reviewed build"
current=$(sha "$BIN")
case " $STOCK $PINNED $CANDIDATE " in
    *" $current "*) ;;
    *) die "unknown /usr/sbin/connmand ($current): firmware changed, rebuild the candidate first" ;;
esac

# --- files ---
mkdir -p "$DIR" "$(dirname "$SVC")" || die "cannot create directories"
if [ "$(sha "$DIR/connmand-generic")" != "$CANDIDATE" ]; then
    copy_atomic "$HERE/files/connmand" "$DIR/connmand-generic" 0755 || die "copy candidate failed"
fi
[ "$("$DIR/connmand-generic" --version 2>/dev/null)" = "1.42" ] || die "candidate does not run here"
if [ -f "$SVC" ] && ! cmp -s "$SVC" "$HERE/files/connman_pmf" && [ ! -f "$DIR/v2-service.bak" ]; then
    cp -p "$SVC" "$DIR/v2-service.bak" || die "cannot keep the previous service"
fi
copy_atomic "$HERE/files/connman_pmf" "$SVC" 0755 || die "service copy failed"

# --- system.services: only our own name; rollback removes it only if we added it ---
services=$(knulli-settings-get system.services)
case " $services " in
    *" connman_pmf "*) [ -f "$DIR/v3-install.state" ] || echo "added_service=0" >"$DIR/v3-install.state" ;;
    *)
        echo "added_service=1" >"$DIR/v3-install.state"
        wanted=$(echo $services connman_pmf)
        knulli-settings-set system.services "$wanted" || die "cannot update system.services"
        [ "$(knulli-settings-get system.services)" = "$wanted" ] || die "system.services readback differs"
        ;;
esac

# --- apply, detached ---
has_route && had_route=1 || had_route=0
rm -f "$RESULT"
setsid bash "$HERE/install.sh" --apply "$had_route" </dev/null >/dev/null 2>&1 &
for _ in $(seq 1 120); do
    grep -q '^state=\(installed\|failed\)' "$RESULT" 2>/dev/null && break
    sleep 1
done
cat "$RESULT" 2>/dev/null || echo "state=pending (check later with: bash install.sh --result)"
grep -q '^state=installed' "$RESULT" 2>/dev/null
