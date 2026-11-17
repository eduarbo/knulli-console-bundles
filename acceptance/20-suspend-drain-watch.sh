#!/bin/sh
# Readback of unit 20, run by fix_updater from the unit folder: the pm-utils hook is in
# /etc/pm/sleep.d and the suspend log answers (service status), and suspend_log is enabled.
# --installed: the same (nothing to compare with this folder).
UNIT_NAME=suspend_log
. ./unit.sh
sh "$SERVICES_DIR/suspend_log" status > /dev/null || fail "hook not in /etc/pm/sleep.d or the log does not answer"
[ "${1:-}" = --installed ] || [ "$(sha "$R/userdata/system/suspend-log/suspend-log.sh")" = "$(sha files/suspend-log.sh)" ] || fail "suspend-log.sh differs"
case " $(conf_get system.services) " in *" suspend_log "*) ;; *) fail "suspend_log not in system.services" ;; esac
say "verified"
