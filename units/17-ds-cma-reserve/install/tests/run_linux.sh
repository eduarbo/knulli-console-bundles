#!/bin/sh
# Run this unit's shell tests, and unit 02's guard tests against the new guard,
# on Linux (ubuntu:24.04: dash, bash, util-linux flock/setsid).
set -eu
UNIT=$(cd "$(dirname "$0")/.." && pwd)
U02=$(cd "$UNIT/../../02-ds-cma-after-suspend/install" && pwd)
exec docker run --rm --network none -v "$UNIT:/unit:ro" -v "$U02:/u02:ro" ubuntu:24.04 bash -c '
  status=0
  cd /unit
  for t in tests/test_handover.sh; do printf "%s: " "$t"; bash "$t" > /tmp/out 2>&1 || status=1; grep -v "^PASS" /tmp/out; done
  for sh in /bin/dash /bin/bash; do printf "tests/test_install.sh %s: " "$sh"; SH=$sh bash tests/test_install.sh > /tmp/out 2>&1 || status=1; grep -v "^PASS" /tmp/out; done
  mkdir -p /tmp/u02/tests /tmp/u02/files && cp -r /u02/tests/. /tmp/u02/tests/ && cp /unit/files/ds-ion-guard.sh /tmp/u02/files/
  printf "unit 02 test_guard.sh on the new guard: "; bash /tmp/u02/tests/test_guard.sh > /tmp/out 2>&1 || status=1; grep -v "^PASS" /tmp/out
  exit $status'
