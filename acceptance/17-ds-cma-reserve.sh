#!/bin/sh
# Readback of unit 17, run by fix_updater from the unit folder: the guard with hand-over is
# 17's, a verified copy of unit 02's guard is kept for rollback, the holder answers and
# cma_reserve is enabled. --installed: installed state only.
UNIT_NAME=cma_reserve
. ./unit.sh
GUARD="$R/userdata/system/scripts/ds-ion-guard.sh"
DIR="$R/userdata/system/cma-reserve"
[ -x "$GUARD" ] || fail "guard hook missing"
[ "${1:-}" = --installed ] || [ "$(sha "$GUARD")" = "$(sha files/ds-ion-guard.sh)" ] || fail "guard is not unit 17's"
[ -f "$DIR/ds-ion-guard.sh.unit02" ] || fail "no copy of unit 02's guard"
sh "$SERVICES_DIR/cma_reserve" status > /dev/null || fail "holder status"
case " $(conf_get system.services) " in *" cma_reserve "*) ;; *) fail "cma_reserve not in system.services" ;; esac
say "verified"
