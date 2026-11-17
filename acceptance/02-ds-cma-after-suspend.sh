#!/bin/sh
# Readback of unit 02, run by fix_updater from the unit folder: the boot service and the
# ION check are this unit's, ds_guard is enabled, and the gameStart guard is 02's, or 17's
# when unit 17 (which takes the guard over) is installed.
# --installed: check the installed state only (adoption of a unit installed by hand).
UNIT_NAME=ds_guard
. ./unit.sh
GUARD="$R/userdata/system/scripts/ds-ion-guard.sh"
U17="$R/userdata/system/upstream-install/17/files/ds-ion-guard.sh"
[ -x "$GUARD" ] || fail "guard hook missing or not executable"
if [ -f "$SERVICES_DIR/cma_reserve" ] && [ -f "$U17" ] && [ "$(sha "$GUARD")" = "$(sha "$U17")" ]; then
  say "guard taken over by unit 17"
elif [ "${1:-}" != --installed ]; then
  [ "$(sha "$GUARD")" = "$(sha files/ds-ion-guard.sh)" ] || fail "guard hook differs"
fi
[ -f "$SERVICES_DIR/ds_guard" ] || fail "ds_guard service missing"
[ "${1:-}" = --installed ] || [ "$(sha "$SERVICES_DIR/ds_guard")" = "$(sha files/ds_guard)" ] || fail "ds_guard service differs"
[ "${1:-}" = --installed ] || [ "$(sha "$R/userdata/system/ds-guard/ion_check.py")" = "$(sha files/ion_check.py)" ] || fail "ion_check.py differs"
case " $(conf_get system.services) " in *" ds_guard "*) ;; *) fail "ds_guard not in system.services" ;; esac
say "verified"
