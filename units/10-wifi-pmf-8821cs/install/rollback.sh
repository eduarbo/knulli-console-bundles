#!/bin/bash
# Undo connman_pmf v3. Run on the console as root from this directory.
#   bash rollback.sh           back to the state before install.sh (v2 service file; connman_pmf
#                              leaves system.services only if install.sh added it)
#   bash rollback.sh --stock   stock ConnMan now and at every boot (only connman_pmf leaves system.services)
# Like install.sh it restarts ConnMan detached; read the outcome with  bash rollback.sh --result
# Files under /userdata/system/patches/connman_pmf are kept.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
R="${KNULLI_TEST_ROOT:-}"
DIR="$R/userdata/system/patches/connman_pmf"
SVC="$R/userdata/system/services/connman_pmf"
RESULT="$DIR/rollback-v3.result"

set_services() {
    knulli-settings-set system.services "$1" && [ "$(knulli-settings-get system.services)" = "$1" ]
}
# Remove only connman_pmf; every other service (also ones installed after us) stays.
drop_own_service() {
    local s wanted=""
    for s in $(knulli-settings-get system.services); do [ "$s" = connman_pmf ] || wanted="$wanted $s"; done
    set_services "$(echo $wanted)"
}
enabled() { case " $(knulli-settings-get system.services) " in *" connman_pmf "*) return 0 ;; esac; return 1; }

run() { # mode
    local mode=$1 added=0 rc
    grep -q '^added_service=1$' "$DIR/v3-install.state" 2>/dev/null && added=1
    echo "state=rolling_back mode=$mode" >"$RESULT"
    # 1. Stock binary back first: the v2 manager refuses any binary it does not know.
    if [ -f "$SVC" ] && grep -q "Knulli user service (v3)" "$SVC"; then
        bash "$SVC" restore || { echo "state=failed reason=restore_stock" >"$RESULT"; return 1; }
    fi
    if [ "$mode" = previous ] && [ -f "$DIR/v2-service.bak" ]; then
        cp -p "$DIR/v2-service.bak" "$SVC.tmp.$$" && mv -f "$SVC.tmp.$$" "$SVC" || { echo "state=failed reason=service_copy" >"$RESULT"; return 1; }
        if [ $added = 1 ]; then drop_own_service || { echo "state=failed reason=services" >"$RESULT"; return 1; }; fi
        rc=skipped
        if enabled; then bash "$SVC" start >/dev/null 2>&1; rc=$?; fi
        rm -f "$DIR/v3-install.state"
        echo "state=rolled_back mode=previous start_rc=$rc" >"$RESULT"
        return 0
    fi
    # Stock: keep stock ConnMan, stop running the service at boot.
    drop_own_service || { echo "state=failed reason=services" >"$RESULT"; return 1; }
    rm -f "$DIR/v3-install.state"
    echo "state=rolled_back mode=stock" >"$RESULT"
}

case "${1:-}" in
    --result) cat "$RESULT" 2>/dev/null || echo "no result yet"; exit 0 ;;
    --after-failed-install) run previous; cat "$RESULT"; exit 0 ;;   # already detached
    --detached-previous) run previous; exit $? ;;
    --detached-stock) run stock; exit $? ;;
    --stock) phase=--detached-stock ;;
    "") phase=--detached-previous ;;
    *) echo "usage: $0 [--stock|--result]" >&2; exit 1 ;;
esac
[ -n "$R" ] || [ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
rm -f "$RESULT"
setsid bash "$HERE/rollback.sh" "$phase" </dev/null >/dev/null 2>&1 &
for _ in $(seq 1 90); do
    grep -q '^state=\(rolled_back\|failed\)' "$RESULT" 2>/dev/null && break
    sleep 1
done
cat "$RESULT" 2>/dev/null || echo "state=pending (check later with: bash rollback.sh --result)"
grep -q '^state=rolled_back' "$RESULT" 2>/dev/null
