#!/bin/sh
# Run this unit's shell tests on Linux (ubuntu:24.04: dash, bash, util-linux
# flock and setsid, procps) in a throwaway container without network.
# test_saver.sh needs python3 and runs on the host instead.
set -eu
UNIT=$(cd "$(dirname "$0")/.." && pwd)
exec docker run --rm --network none --cap-add SYS_NICE -v "$UNIT:/unit:ro" ubuntu:24.04 bash -c '
  cd /unit; status=0
  for t in tests/test_*.sh; do
    case "$t" in
      */test_saver.sh) continue ;;
      */test_install.sh)
        for sh in /bin/dash /bin/bash; do
          printf "%s %s: " "$t" "$sh"; SH=$sh bash "$t" > /tmp/out 2>&1 || status=1; grep -v "^PASS" /tmp/out
        done ;;
      *) printf "%s: " "$t"; bash "$t" > /tmp/out 2>&1 || status=1; grep -v "^PASS" /tmp/out ;;
    esac
  done
  exit $status'
