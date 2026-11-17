#!/bin/sh
# Install the DS CMA reservation (unit 17) on the RG35XX-H (Knulli scarab
# 2026/05/11): the cma_reserve service holds DraStic's ION buffers from boot,
# and unit 02's guard gets the hand-over (release at gameStart, take back at
# gameStop). Needs unit 02 installed. Run as root on the device from this
# folder: sh install.sh   Idempotent; rollback.sh undoes it.
set -u
UNIT_NAME=cma_reserve
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/unit.sh"

DIR="$R/userdata/system/cma-reserve"
GUARD="$R/userdata/system/scripts/ds-ion-guard.sh"
UNIT02_SHA=67bcb903d2ebc9d6d580567675c0ae80dd59ae5a14f258de0034caae635d3d20
GUARD_SHA=$(sha "$HERE/files/ds-ion-guard.sh")

(cd "$HERE" && sha256sum --status -c SHA256SUMS) || fail "unit files do not match SHA256SUMS"
check_device
[ -c "$R/dev/ion" ] || [ -n "$R" ] || fail "no /dev/ion"
for f in files/ds-ion-guard.sh files/cma_reserve; do
  sh -n "$HERE/$f" || fail "syntax of $f"
done
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$HERE/files/cma-reserve.py" || fail "syntax of cma-reserve.py"
current=$(sha "$GUARD")
[ "$current" = "$UNIT02_SHA" ] || [ "$current" = "$GUARD_SHA" ] || fail "$GUARD is not unit 02's guard (install unit 02 first)"

mkdir -p "$DIR" "$SERVICES_DIR" || fail "folders"
if [ "$current" = "$UNIT02_SHA" ]; then
  # kept outside scripts/: every executable there runs as a game hook
  cp -p "$GUARD" "$DIR/ds-ion-guard.sh.unit02" && chmod a-x "$DIR/ds-ion-guard.sh.unit02" || fail "backup of the guard"
fi
[ "$(sha "$DIR/ds-ion-guard.sh.unit02")" = "$UNIT02_SHA" ] || fail "no verified copy of unit 02's guard"
install_file "$HERE/files/cma-reserve.py" "$DIR/cma-reserve.py" 644 "$(sha "$HERE/files/cma-reserve.py")"
install_file "$HERE/files/cma_reserve" "$SERVICES_DIR/cma_reserve" 755 "$(sha "$HERE/files/cma_reserve")"
backup_conf
services_add cma_reserve
sync

# Hold first, then switch the guard: a DS launch in between still works
sh "$SERVICES_DIR/cma_reserve" start > "$DIR/install-hold.json" 2>&1 || fail "holder did not take the buffers: $(cat "$DIR/install-hold.json")"
install_file "$HERE/files/ds-ion-guard.sh" "$GUARD" 755 "$GUARD_SHA"
sync
sh "$SERVICES_DIR/cma_reserve" status > /dev/null || fail "holder status"
say "installed: holder $(cat "$DIR/install-hold.json"); guard with hand-over; service enabled"
