#!/bin/bash
# Readback after install.sh, run by fix_updater from the unit folder (unit 10 acceptance
# step 1): install.sh recorded success (it also checked the default route when there was
# one) and the generic build is the running connmand. --installed: running state only.
R="${KNULLI_TEST_ROOT:-}"
SVC="$R/userdata/system/services/connman_pmf"
if [ "${1:-}" != --installed ]; then
	for i in $(seq 60); do
		bash install.sh --result | grep -q '^state=\(installed\|failed\)' && break
		sleep 2
	done
	bash install.sh --result | grep -q '^state=installed' || { echo "10: install did not finish (state: $(bash install.sh --result | head -2 | tr '\n' ' '))"; exit 1; }
fi
status=$(bash "$SVC" status)
echo "$status" | grep -qx 'binary=candidate' || { echo "10: /usr/sbin/connmand is not the candidate"; exit 1; }
echo "$status" | grep -qx 'active=candidate' || { echo "10: the running connmand is not the candidate"; exit 1; }
echo "$status" | grep -qx 'stock_backup=ok' || { echo "10: no verified stock backup"; exit 1; }
case " $(knulli-settings-get system.services) " in *" connman_pmf "*) ;; *) echo "10: connman_pmf not in system.services"; exit 1 ;; esac
echo "10: verified"
