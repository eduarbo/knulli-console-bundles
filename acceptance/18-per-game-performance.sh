#!/bin/sh
# Readback of unit 18, run by fix_updater from the unit folder: the gameStart/gameStop hook
# and the profile table are this unit's. --installed: installed state only.
UNIT_NAME=game_performance
. ./unit.sh
HOOK="$R/userdata/system/scripts/game-performance.sh"
DIR="$R/userdata/system/game-performance"
[ -x "$HOOK" ] || fail "hook missing or not executable"
[ -f "$DIR/profiles.tsv" ] || fail "profile table missing"
if [ "${1:-}" != --installed ]; then
  [ "$(sha "$HOOK")" = "$(sha files/game-performance.sh)" ] || fail "hook differs"
  [ "$(sha "$DIR/profiles.tsv")" = "$(sha files/profiles.tsv)" ] || fail "profile table differs"
fi
say "verified"
