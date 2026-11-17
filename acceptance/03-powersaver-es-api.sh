#!/bin/sh
# Readback after install.sh, run by fix_updater from the unit folder (unit 03 acceptance
# step 1): both idle/active hooks are the patched ones and es_api_hold is enabled.
UNIT_NAME=es_api_hold
. ./unit.sh
sh "$SERVICES_DIR/es_api_hold" status || fail "idle/active hooks are not the patched ones"
case " $(conf_get system.services) " in *" es_api_hold "*) ;; *) fail "es_api_hold not in system.services" ;; esac
say "verified"
