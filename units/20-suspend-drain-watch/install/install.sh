#!/bin/sh
# Install unit 20 (battery log at every suspend/resume + Wi-Fi watchdog after resume)
# on the RG35XX-H (Knulli scarab 2026/05/11). Run as root on the device from this
# folder: sh install.sh   Idempotent; rollback.sh undoes it. knulli.conf: only
# system.services gains suspend_log.
set -u
UNIT_NAME=suspend_log
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/unit.sh"

DIR="$R/userdata/system/suspend-log"
HOOK="$R/etc/pm/sleep.d/05suspend-log"

(cd "$HERE" && sha256sum --status -c SHA256SUMS) || fail "unit files do not match SHA256SUMS"
check_device
for f in files/suspend-log.sh files/05suspend-log files/suspend_log files/drain-test.sh; do
  sh -n "$HERE/$f" || fail "syntax of $f"
done
[ -d "$R/etc/pm/sleep.d" ] || fail "no /etc/pm/sleep.d"
if [ -e "$HOOK" ] && [ "$(sha "$HOOK")" != "$(sha "$HERE/files/05suspend-log")" ]; then
  fail "$HOOK exists and is not this unit's"
fi

mkdir -p "$DIR" "$SERVICES_DIR" "$R/userdata/system/logs" || fail "folders"
for f in suspend-log.sh 05suspend-log drain-test.sh drain_report.py; do
  install_file "$HERE/files/$f" "$DIR/$f" 755 "$(sha "$HERE/files/$f")"
done
install_file "$HERE/files/suspend_log" "$SERVICES_DIR/suspend_log" 755 "$(sha "$HERE/files/suspend_log")"
backup_conf
services_add suspend_log
sync
sh "$SERVICES_DIR/suspend_log" start || fail "service start"
sh "$SERVICES_DIR/suspend_log" status > /dev/null || fail "hook not in place after start"
say "installed: hook $HOOK, log /userdata/system/logs/suspend-drain.jsonl, watchdog on"
