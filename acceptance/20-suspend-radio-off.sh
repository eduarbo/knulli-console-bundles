#!/bin/sh
# Readback of unit 20, run by fix_updater from the unit folder: the pm-utils hook is in
# /etc/pm/sleep.d (service status) and radio_sleep is enabled.
UNIT_NAME=radio_sleep
. ./unit.sh
sh "$SERVICES_DIR/radio_sleep" status > /dev/null || fail "hook not in /etc/pm/sleep.d"
case " $(conf_get system.services) " in *" radio_sleep "*) ;; *) fail "radio_sleep not in system.services" ;; esac
say "verified"
