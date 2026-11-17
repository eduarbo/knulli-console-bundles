#!/bin/sh
# Undo install.sh: unit 02's guard back, holder stopped (its buffers freed),
# service removed. Run as root on the device from this folder: sh rollback.sh
# Idempotent. Roll this unit back before unit 02.
set -u
UNIT_NAME=cma_reserve
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/unit.sh"

DIR="$R/userdata/system/cma-reserve"
GUARD="$R/userdata/system/scripts/ds-ion-guard.sh"
UNIT02_SHA=67bcb903d2ebc9d6d580567675c0ae80dd59ae5a14f258de0034caae635d3d20
GUARD_SHA=$(sha "$HERE/files/ds-ion-guard.sh")

check_device
if [ "$(sha "$GUARD")" = "$GUARD_SHA" ]; then
  [ "$(sha "$DIR/ds-ion-guard.sh.unit02")" = "$UNIT02_SHA" ] || fail "no verified copy of unit 02's guard; left as is"
  cp "$DIR/ds-ion-guard.sh.unit02" "$GUARD.tmp" && chmod 755 "$GUARD.tmp" && mv -f "$GUARD.tmp" "$GUARD" || fail "restoring unit 02's guard"
  [ "$(sha "$GUARD")" = "$UNIT02_SHA" ] || fail "readback of unit 02's guard"
fi
if [ -f "$DIR/cma-reserve.py" ]; then
  python3 "$DIR/cma-reserve.py" release > /dev/null 2>&1 || fail "release of the buffers"
fi
services_remove cma_reserve
rm -f "$SERVICES_DIR/cma_reserve"
rm -rf "$DIR"
sync
say "rolled back: unit 02 guard restored, buffers released, service removed"
