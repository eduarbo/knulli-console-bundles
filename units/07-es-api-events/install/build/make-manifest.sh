#!/bin/bash
# Regenerate payload/manifest from the files in this folder (macOS or Linux).
set -eu
cd "$(dirname "$0")/.."
sum() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | cut -d ' ' -f 1; }
: "${ES_COMMIT:?set ES_COMMIT to the fork commit the payload was built from}"
cat > payload/manifest <<X
MODEL=Anbernic RG35XX-H
VERSION=scarab 2026/05/11 00:09
STOCK_SHA256=d02c1f349952151ba5cd5b67125e848e95279483230d1582203efd44cf37af64
PATCHED_SHA256=$(sum payload/emulationstation)
LAUNCHER_SHA256=$(sum files/launcher.sh)
SERVICE_SHA256=$(sum files/service.sh)
ES_BASE=4041b56a714265de81de8165b34fbd10f313a891
ES_COMMIT=$ES_COMMIT
X
cat payload/manifest
