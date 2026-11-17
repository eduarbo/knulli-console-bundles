#!/bin/sh
# Readback after install.sh, run by fix_updater from the unit folder (unit 01 VALIDATION,
# acceptance step 1): /usr/bin/knulli-suspend is the patched file and the service is enabled.
UNIT_NAME=suspend_poweroff
. ./unit.sh
sh "$R/userdata/system/services/suspend_poweroff" status || fail "/usr/bin/knulli-suspend is not the patched file"
case " $(conf_get system.services) " in *" suspend_poweroff "*) ;; *) fail "suspend_poweroff not in system.services" ;; esac
say "verified"
